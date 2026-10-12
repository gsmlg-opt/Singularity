defmodule Singularity.Runtime.Knowledge.ExportRead.AssetScope do
  @moduledoc false

  alias Singularity.Core.Error
  alias Singularity.Runtime.OperationScope
  alias Singularity.Storage.KnowledgeExport.Repository

  # This is a fixed internal wrapper, not a caller-selectable scope adapter.
  # The original Download callback, its audit and commit remain in one scope.
  def with_read_request(%{binding: binding, mode: mode}, runtime, session, requirement, callback) do
    repository = Map.get(runtime, :knowledge_export_repository, Repository)

    OperationScope.with_read_request(runtime, session, requirement, fn repo ->
      with :ok <- call(repository, :lock_asset_source, [repo, binding, mode]),
           {:ok, _} = result <- callback.(repo),
           :ok <- call(repository, :lock_asset_source, [repo, binding, mode]) do
        result
      else
        {:reauthorize, _} = result -> result
        {:error, %Error{}} = error -> error
        _ -> {:error, Error.new(:integrity_failure)}
      end
    end)
  end

  defp call(module, function, args) when is_atom(module), do: apply(module, function, args)
  defp call({module, context}, function, args), do: apply(module, function, [context | args])
end

defmodule Singularity.Runtime.Knowledge.ExportRead do
  @moduledoc "Internal exact-source, authenticated portable export reads."

  alias Singularity.Core.Error
  alias Singularity.Runtime.{DownloadLease, KeyCustodian, OperationScope, SessionContext}
  alias Singularity.Runtime.Assets.Download
  alias Singularity.Runtime.Knowledge.ExportRead.AssetScope
  alias Singularity.Storage.KnowledgeExport.{Repository, Spool}

  @piece_bytes 65_536
  @native_bytes 4_194_304
  @document_bytes 67_108_864
  @asset_keys ~w(kind resource_id version_id asset_id object_id owner_scope_id classification key_domain_id domain_key_version_id domain_key_generation object_generation lookup_digest ciphertext_hash plaintext_byte_size ciphertext_byte_size storage_ref format_version plaintext_sha256)
  @version_keys ~w(resource_id version_id revision kind inserted_at availability body_path original_path extracted_path body_digest original_digest original_byte_size extracted_digest media_type state extraction_adapter extraction_format parent_version_id merge_parent_version_id title)
  @fragment_keys ~w(id resource_id version_id ordinal digest locator extracted_path start_byte byte_size)

  def asset(runtime, session, binding) do
    safely(fn ->
      validate_request!(runtime, session)
      validate_asset!(binding)
      pass = fn acc, consumer -> asset_pass(runtime, session, binding, acc, consumer) end
      descriptor(pass, binding["plaintext_byte_size"], nil)
    end)
  end

  def document(runtime, session, binding) do
    safely(fn ->
      validate_request!(runtime, session)
      exact_keys!(binding, [:version, :source])
      version = binding.version
      map_keys!(version, @version_keys)
      validate_asset!(binding.source)
      ids!(version, ~w(resource_id version_id))
      digest!(version["original_digest"])

      unless version["kind"] == "document" and is_integer(version["original_byte_size"]) and
               version["original_byte_size"] in 0..@document_bytes and
               version["original_byte_size"] == binding.source["plaintext_byte_size"],
             do: fail(:integrity_failure)

      pass = fn acc, consumer -> document_pass(runtime, session, binding, acc, consumer) end
      descriptor(pass, version["original_byte_size"], version["original_digest"])
    end)
  end

  def note(runtime, session, binding), do: text(runtime, session, binding, :note)
  def fragment(runtime, session, binding), do: text(runtime, session, binding, :fragment)

  defp text(runtime, session, binding, kind) do
    safely(fn ->
      validate_request!(runtime, session)
      record_key = if kind == :note, do: :version, else: :fragment
      exact_keys!(binding, [:capture, :text_ref, record_key])
      record = Map.fetch!(binding, record_key)
      map_keys!(record, if(kind == :note, do: @version_keys, else: @fragment_keys))
      ids!(record, ~w(resource_id version_id))
      ref = binding.text_ref
      unless is_map(ref) and not is_struct(ref), do: fail(:invalid)
      digest = record[if(kind == :note, do: "body_digest", else: "digest")]
      digest!(digest)

      selector =
        if kind == :note do
          unless record["kind"] == "note" and record["availability"] == "included",
            do: fail(:integrity_failure)

          {:note_markdown, record["resource_id"], record["version_id"]}
        else
          unless is_integer(record["ordinal"]) and record["ordinal"] >= 0 and
                   record["byte_size"] == ref[:byte_size],
                 do: fail(:integrity_failure)

          {:fragment_text, record["resource_id"], record["version_id"], record["ordinal"],
           record["id"]}
        end

      unless ref[:selector] == selector and ref[:sha256] == digest and
               is_integer(ref[:byte_size]) and ref[:byte_size] >= 0 and
               is_map(binding.capture) and
               get_in(binding.capture, [:text_refs, selector]) === ref,
             do: fail(:integrity_failure)

      pass = fn acc, consumer -> text_pass(runtime, session, binding, kind, acc, consumer) end
      descriptor(pass, ref.byte_size, digest)
    end)
  end

  defp descriptor(pass, size, expected) do
    {_acc, hash, actual_size} = pass.(nil, fn _, _ -> {:ok, nil} end)
    sha = finish!(hash, actual_size, size, expected)

    {:ok,
     %{
       byte_size: size,
       sha256: sha,
       reduce: fn acc, consumer ->
         safely(fn ->
           unless is_function(consumer, 2), do: fail(:invalid)
           {acc, hash, actual_size} = pass.(acc, consumer)
           finish!(hash, actual_size, size, sha)
           {:ok, acc}
         end)
       end
     }}
  end

  defp asset_pass(runtime, session, binding, acc, consumer) do
    validate_request!(runtime, session)
    size = binding["plaintext_byte_size"]
    initial = {acc, :crypto.hash_init(:sha256), 0}

    state =
      if size == 0 do
        bytes = asset_read!(runtime, session, binding, :zero)
        unless bytes == "", do: fail(:integrity_failure)
        initial
      else
        Enum.reduce(0..div(size - 1, @piece_bytes), initial, fn index, state ->
          first = index * @piece_bytes
          range = first..min(first + @piece_bytes - 1, size - 1)
          bytes = asset_read!(runtime, session, binding, range)

          unless is_binary(bytes) and byte_size(bytes) == range.last - range.first + 1,
            do: fail(:integrity_failure)

          consume!(bytes, state, consumer)
        end)
      end

    asset_guard!(runtime, session, binding, if(size == 0, do: :zero, else: 0..0))
    state
  end

  defp asset_read!(runtime, session, binding, mode) do
    guarded = Map.put(runtime, :operation_scope, {AssetScope, %{binding: binding, mode: mode}})

    unwrap!(
      Download.run(guarded, session, binding["asset_id"], if(mode == :zero, do: :all, else: mode))
    )
  end

  defp asset_guard!(runtime, session, binding, mode) do
    scoped!(runtime, session, "asset.read", fn repo ->
      call(repository(runtime), :lock_asset_source, [repo, binding, mode])
    end)
  end

  defp document_pass(runtime, session, captured, acc, consumer) do
    validate_request!(runtime, session)
    binding = document_guard!(runtime, session, captured)

    request = %{
      purpose: :document_source,
      access: :request,
      session_id: session.session_id,
      principal_id: session.principal_id,
      vault_id: session.vault_id,
      principal_authorization_epoch: session.principal_authorization_epoch,
      vault_authorization_epoch: session.vault_authorization_epoch,
      required_capability: "asset.read",
      resource_version_id: binding.resource_version_id,
      object_id: binding.object_id,
      object_generation: binding.object_generation
    }

    reader = Map.get(runtime, :authenticated_reader, DownloadLease)
    # Do not create a lease inside a transaction whose COMMIT can still fail
    # and discard the returned handle. Custody independently authenticates this
    # exact immutable request; every subsequent read has another live scope.
    lease =
      unwrap!(call(Map.get(runtime, :custodian, {KeyCustodian, KeyCustodian}), :lease, [request]))

    try do
      initial = {acc, :crypto.hash_init(:sha256), 0}
      size = binding.source_byte_size

      result =
        if size == 0 do
          scoped!(runtime, session, "asset.read", fn repo ->
            with {:ok, ^binding} <- call(repository(runtime), :document_source, [repo, captured]) do
              call(reader, :authenticate_empty_document_original, [lease])
            else
              {:error, %Error{}} = error -> error
              _ -> {:error, Error.new(:integrity_failure)}
            end
          end)

          initial
        else
          Enum.reduce(0..div(size - 1, @native_bytes), initial, fn index, state ->
            bytes =
              unwrap!(
                scoped_result(runtime, session, "asset.read", fn repo ->
                  with {:ok, ^binding} <-
                         call(repository(runtime), :document_source, [repo, captured]) do
                    call(reader, :read_document_chunk, [lease, index])
                  else
                    {:error, %Error{}} = error -> error
                    _ -> {:error, Error.new(:integrity_failure)}
                  end
                end)
              )

            expected_size = min(@native_bytes, size - index * @native_bytes)

            unless is_binary(bytes) and byte_size(bytes) == expected_size,
              do: fail(:integrity_failure)

            split_document!(bytes, state, consumer, fn ->
              unless document_guard!(runtime, session, captured) == binding,
                do: fail(:integrity_failure)
            end)
          end)
        end

      unless document_guard!(runtime, session, captured) == binding, do: fail(:integrity_failure)
      result
    after
      revoke(reader, lease)
    end
  end

  defp document_guard!(runtime, session, captured) do
    binding =
      unwrap!(
        scoped_result(runtime, session, "asset.read", fn repo ->
          call(repository(runtime), :document_source, [repo, captured])
        end)
      )

    unless binding.resource_id == captured.version["resource_id"] and
             binding.resource_version_id == captured.version["version_id"] and
             binding.object_id == captured.source["object_id"] and
             binding.object_generation == captured.source["object_generation"] and
             binding.source_byte_size == captured.version["original_byte_size"] and
             hex(binding.source_digest) == captured.version["original_digest"],
           do: fail(:integrity_failure)

    binding
  end

  defp split_document!("", state, _consumer, _guard), do: state

  defp split_document!(bytes, state, consumer, guard) do
    count = min(byte_size(bytes), @piece_bytes)
    <<piece::binary-size(count), rest::binary>> = bytes
    guard.()
    state = consume!(piece, state, consumer)
    split_document!(rest, state, consumer, guard)
  end

  defp text_pass(runtime, session, binding, kind, acc, consumer) do
    validate_request!(runtime, session)
    guard = fn -> text_guard!(runtime, session, binding, kind) end
    guard.()
    size = binding.text_ref.byte_size

    state =
      Enum.reduce(
        0..div(max(size - 1, 0), @piece_bytes),
        {acc, :crypto.hash_init(:sha256), 0},
        fn index, state ->
          bytes = unwrap!(Spool.read_chunk(binding.capture, binding.text_ref, index))

          unless is_binary(bytes) and
                   byte_size(bytes) == min(@piece_bytes, size - index * @piece_bytes),
                 do: fail(:integrity_failure)

          guard.()
          if bytes == "", do: state, else: consume!(bytes, state, consumer)
        end
      )

    guard.()

    # Observe the sealed capture's deadline/phase and journal identity after
    # the final eligibility guard, including an empty text source.
    unwrap!(
      Spool.read_chunk(binding.capture, binding.text_ref, div(max(size - 1, 0), @piece_bytes))
    )

    state
  end

  defp text_guard!(runtime, session, binding, kind) do
    function = if kind == :note, do: :revalidate_note, else: :revalidate_fragment

    scoped!(runtime, session, if(kind == :note, do: "note.read", else: "asset.read"), fn repo ->
      call(repository(runtime), function, [repo, binding])
    end)
  end

  defp consume!(bytes, {acc, hash, size}, consumer) do
    case consumer.(bytes, acc) do
      {:ok, next} -> {next, :crypto.hash_update(hash, bytes), size + byte_size(bytes)}
      {:error, %Error{} = error} -> throw({__MODULE__, error})
      _ -> fail(:invalid)
    end
  end

  defp finish!(hash, actual_size, size, expected) do
    digest = hash |> :crypto.hash_final() |> hex()

    unless actual_size == size and (is_nil(expected) or digest == expected),
      do: fail(:integrity_failure)

    digest
  end

  defp scoped!(runtime, session, capability, callback) do
    case scoped_result(runtime, session, capability, callback) do
      :ok -> :ok
      {:error, reason} -> raise_error!(reason)
      _ -> fail(:integrity_failure)
    end
  end

  defp scoped_result(runtime, session, capability, callback) do
    OperationScope.with_read_request(
      runtime,
      session,
      %{
        vault_id: session.vault_id,
        required_capability: capability,
        classification: :private,
        requires_unlocked?: true,
        principal_authorization_epoch: session.principal_authorization_epoch,
        vault_authorization_epoch: session.vault_authorization_epoch
      },
      callback
    )
  end

  defp validate_request!(runtime, %SessionContext{unlocked?: true} = session)
       when is_map(runtime) do
    unless Enum.all?([session.session_id, session.principal_id, session.vault_id], &uuid?/1) and
             is_integer(session.principal_authorization_epoch) and
             session.principal_authorization_epoch >= 0 and
             is_integer(session.vault_authorization_epoch) and
             session.vault_authorization_epoch >= 0,
           do: fail(:invalid)

    repo = Map.get(runtime, :request_repo, Singularity.Storage.RequestRepo)
    if call(repo, :in_transaction?, []), do: fail(:invalid)
  end

  defp validate_request!(_, _), do: fail(:invalid)

  defp validate_asset!(binding) do
    exact_keys!(binding, @asset_keys)

    ids!(
      binding,
      ~w(resource_id version_id asset_id object_id owner_scope_id key_domain_id domain_key_version_id)
    )

    digest!(binding["lookup_digest"])
    digest!(binding["ciphertext_hash"])
    size = binding["plaintext_byte_size"]

    unless binding["kind"] == "asset" and binding["classification"] == "private" and
             binding["format_version"] == 1 and binding["plaintext_sha256"] == nil and
             is_integer(binding["object_generation"]) and binding["object_generation"] > 0 and
             is_integer(binding["domain_key_generation"]) and binding["domain_key_generation"] > 0 and
             is_binary(binding["storage_ref"]) and is_integer(size) and size >= 0 and
             binding["ciphertext_byte_size"] ==
               134 + size + div(size + @native_bytes - 1, @native_bytes) * 24,
           do: fail(:integrity_failure)
  end

  defp exact_keys!(map, keys) do
    unless is_map(map) and not is_struct(map) and MapSet.new(Map.keys(map)) == MapSet.new(keys),
      do: fail(:invalid)
  end

  defp map_keys!(map, keys) do
    unless is_map(map) and not is_struct(map) and Enum.all?(Map.keys(map), &(&1 in keys)),
      do: fail(:invalid)
  end

  defp ids!(map, keys) do
    unless Enum.all?(keys, &uuid?(map[&1])), do: fail(:invalid)
  end

  defp uuid?(id) when is_binary(id), do: match?({:ok, ^id}, Ecto.UUID.cast(id))
  defp uuid?(_), do: false

  defp digest!(value) do
    unless is_binary(value) and byte_size(value) == 64 and
             match?({:ok, <<_::binary-size(32)>>}, Base.decode16(value, case: :lower)),
           do: fail(:integrity_failure)
  end

  defp repository(runtime), do: Map.get(runtime, :knowledge_export_repository, Repository)
  defp call(module, function, args) when is_atom(module), do: apply(module, function, args)
  defp call({module, context}, function, args), do: apply(module, function, [context | args])
  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: raise_error!(reason)
  defp unwrap!(_), do: fail(:integrity_failure)
  defp raise_error!(%Error{} = error), do: throw({__MODULE__, error})
  defp raise_error!(:waiting_for_unlock), do: fail(:vault_locked)
  defp raise_error!(_), do: fail(:storage_unavailable)
  defp fail(code), do: throw({__MODULE__, Error.new(code)})

  defp revoke(reader, lease) do
    result =
      try do
        call(reader, :revoke, [lease])
      rescue
        _ -> :unavailable
      catch
        _, _ -> :unavailable
      end

    unless result == :ok or (is_pid(lease) and not Process.alive?(lease)),
      do: fail(:storage_unavailable)

    :ok
  end

  defp safely(callback) do
    callback.()
  rescue
    _ -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    :throw, {__MODULE__, %Error{} = error} ->
      {:error, Error.new(error.code, retryable?: error.retryable?)}

    _, _ ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end
end
