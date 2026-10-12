defmodule Singularity.Runtime.KnowledgeExportReadTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{DocumentFragment, Error}
  alias Singularity.Runtime.{AuthorizationDependencies, Authorize, OperationScope, SessionContext}
  alias Singularity.Storage.KnowledgeExport.Spool

  @moduletag :tmp_dir
  @read Singularity.Runtime.Knowledge.ExportRead
  @owner "00000000-0000-4000-8000-000000014001"
  @principal "00000000-0000-4000-8000-000000014002"
  @session "00000000-0000-4000-8000-000000014003"
  @asset "00000000-0000-4000-8000-000000014004"
  @resource "00000000-0000-4000-8000-000000014005"
  @version "00000000-0000-4000-8000-000000014006"
  @object "00000000-0000-4000-8000-000000014007"

  # SYNTHETIC composition only. These adapters exercise the real fixed caller,
  # OperationScope and Authorize, not SQL authorization, row locks or custody.
  defmodule Repo do
    def checkout(callback), do: callback.()
    def in_transaction?(), do: Process.get(:export_read_transaction, false)
  end

  defmodule Lock do
    def with_shared(repo, _principal, _owner, callback) do
      try do
        callback.(repo)
      after
        send(self(), {:wire, :authorization_unlock})
      end
    end

    def with_shared(repo, _owner, callback), do: callback.(repo)
  end

  defmodule Scoped do
    def transact(repo, scope, callback) do
      send(self(), {:wire, :scope, scope})
      Process.put(:export_read_transaction, true)

      try do
        result = callback.(repo)

        case Process.get(:export_read_commit_error) do
          nil ->
            send(self(), {:wire, :commit})
            result

          error ->
            {:error, error}
        end
      after
        Process.put(:export_read_transaction, false)
        send(self(), {:wire, :closed})
      end
    end
  end

  defmodule Identity do
    def load_live_session(_repo, session) do
      send(self(), {:wire, :authorize, session})
      {:ok, Process.get(:export_read_live)}
    end
  end

  defmodule Custodian do
    def assert_unlocked(_, _, _, _, _), do: Process.get(:export_read_unlock, :ok)

    def lease(request) do
      send(self(), {:wire, :lease, request})
      token = make_ref()
      Process.put({:export_read_lease, token}, true)
      {:ok, token}
    end
  end

  defmodule Reader do
    def read(lease, range) do
      send(self(), {:wire, :range, range})
      bytes = Process.get(:export_read_bytes)

      result =
        case Process.get(:export_read_reader_error) do
          nil ->
            {:ok,
             if(range == :all,
               do: bytes,
               else: binary_part(bytes, range.first, Range.size(range))
             )}

          error ->
            {:error, error}
        end

      revoke(lease)
      result
    end

    def read_document_chunk(lease, index) do
      send(self(), {:wire, :document_chunk, lease, index})

      case Process.get(:export_read_reader_error) do
        nil ->
          bytes = Process.get(:export_read_bytes)
          offset = index * 4_194_304
          {:ok, binary_part(bytes, offset, min(4_194_304, byte_size(bytes) - offset))}

        error ->
          {:error, error}
      end
    end

    def authenticate_empty_document_original(lease) do
      send(self(), {:wire, :empty_document, lease})
      Process.get(:export_read_empty_error, :ok)
    end

    def revoke(lease) do
      Process.delete({:export_read_lease, lease})
      send(self(), {:wire, :revoke, lease})
      :ok
    end
  end

  defmodule Assets do
    def authorized_object(_repo, asset) do
      send(self(), {:wire, :asset_selection, asset})
      binding = Process.get(:export_read_asset)

      {:ok,
       %{
         asset_id: asset,
         vault_id: binding["owner_scope_id"],
         classification: :private,
         object_id: binding["object_id"],
         object_generation: binding["object_generation"]
       }}
    end
  end

  defmodule Repository do
    def lock_asset_source(repo, binding, mode) do
      send(self(), {:wire, :asset_guard, repo, binding, mode})
      Process.get(:export_read_guard, :ok)
    end

    def document_source(repo, captured) do
      send(self(), {:wire, :document_guard, repo, captured})

      case Process.get(:export_read_guard, :ok) do
        :ok ->
          {:ok,
           %{
             resource_id: captured.version["resource_id"],
             resource_version_id: captured.version["version_id"],
             object_id: captured.source["object_id"],
             object_generation: captured.source["object_generation"],
             source_digest: Base.decode16!(captured.version["original_digest"], case: :lower),
             source_byte_size: captured.version["original_byte_size"]
           }}

        error ->
          error
      end
    end

    def revalidate_note(repo, binding), do: revalidate(:note, repo, binding)
    def revalidate_fragment(repo, binding), do: revalidate(:fragment, repo, binding)

    defp revalidate(kind, repo, binding) do
      send(self(), {:wire, :text_guard, kind, repo, binding})
      Process.get(:export_read_text_hook, fn _, _, _ -> :ok end).(kind, repo, binding)
      Process.get(:export_read_guard, :ok)
    end
  end

  defmodule Audit do
    def append(_repo, event) do
      send(self(), {:wire, :audit, event})
      Process.get(:export_read_audit, :ok)
    end
  end

  setup %{tmp_dir: tmp_dir} do
    session = %SessionContext{
      session_id: @session,
      principal_id: @principal,
      vault_id: @owner,
      authorization_epoch: 7,
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 23,
      expires_at: DateTime.add(DateTime.utc_now(), 300),
      unlocked?: true
    }

    Process.put(:export_read_live, %{
      session_id: @session,
      principal_id: @principal,
      vault_id: @owner,
      session_expires_at: session.expires_at,
      session_revoked_at: nil,
      principal_revoked_at: nil,
      membership_revoked_at: nil,
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 23,
      principal_kind: :owner,
      clearance: :private,
      vault_locked: false,
      capabilities: ["asset.read", "note.read"]
    })

    assert {:ok, authorization} =
             AuthorizationDependencies.new(%{store: Identity, custodian: Custodian})

    runtime = %{
      request_repo: Repo,
      authorization_lock: Lock,
      vault_lock: Lock,
      scoped_repo: Scoped,
      operation_scope: OperationScope,
      authorizer: Authorize,
      authorization: authorization,
      audit: Audit,
      assets: Assets,
      custodian: Custodian,
      authenticated_reader: Reader,
      knowledge_export_repository: Repository
    }

    Process.put(:export_read_bytes, "original")
    asset = asset_binding("original")
    Process.put(:export_read_asset, asset)

    %{
      runtime: runtime,
      session: session,
      asset: asset,
      document: document_binding(asset, "original"),
      tmp_dir: tmp_dir
    }
  end

  test "exact Document preflight precedes a fresh request lease and bounded delivery", c do
    assert {:ok, delivery} = call(:document, [c.runtime, c.session, c.document])
    assert delivery.byte_size == 8
    assert delivery.sha256 == sha("original")
    assert is_function(delivery.reduce, 2)
    preflight = events()
    assert Enum.any?(preflight, &match?({:wire, :document_chunk, _, 0}, &1))
    assert Enum.any?(preflight, &match?({:wire, :revoke, _}, &1))
    refute Repo.in_transaction?()
    assert {:ok, "original"} = delivery.reduce.("", fn chunk, acc -> {:ok, acc <> chunk} end)
    assert_request_leases(events(), c)
    assert_no_leases()
  end

  test "Document delivery splits existing aligned 4MiB records into at most 64KiB", c do
    bytes = :binary.copy("界", 1_398_101) <> "tail"
    Process.put(:export_read_bytes, bytes)
    binding = document_binding(c.asset, bytes)
    assert {:ok, delivery} = call(:document, [c.runtime, c.session, binding])

    assert {:ok, {digest, size, largest}} =
             delivery.reduce.({:crypto.hash_init(:sha256), 0, 0}, fn chunk,
                                                                     {hash, size, largest} ->
               assert byte_size(chunk) in 1..65_536

               {:ok,
                {:crypto.hash_update(hash, chunk), size + byte_size(chunk),
                 max(largest, byte_size(chunk))}}
             end)

    assert size == byte_size(bytes)
    assert Base.encode16(:crypto.hash_final(digest), case: :lower) == sha(bytes)
    assert largest == 65_536
    assert_request_leases(events(), %{c | document: binding})
    assert_no_leases()
  end

  test "empty Document uses its existing Document-only final authentication", c do
    Process.put(:export_read_bytes, "")
    binding = document_binding(c.asset, "")
    assert {:ok, delivery} = call(:document, [c.runtime, c.session, binding])
    assert delivery.byte_size == 0
    assert delivery.sha256 == sha("")

    assert {:ok, :empty} =
             delivery.reduce.(:empty, fn _, _ -> flunk("empty delivery emitted bytes") end)

    trace = events()
    assert Enum.any?(trace, &match?({:wire, :empty_document, _}, &1))
    refute Enum.any?(trace, &match?({:wire, :document_chunk, _, _}, &1))
    refute Enum.any?(trace, &match?({:wire, :range, :all}, &1))
    assert_no_leases()
  end

  for field <- ["original_digest", "original_byte_size"] do
    test "Document preflight rejects wrong captured #{field} before descriptor", c do
      wrong = wrong_original(unquote(field))
      binding = %{c.document | version: Map.put(c.document.version, unquote(field), wrong)}

      assert {:error, %Error{code: :integrity_failure}} =
               call(:document, [c.runtime, c.session, binding])

      assert_no_leases()
    end
  end

  test "Document original 64MiB ceiling rejects without a lease or a large allocation", c do
    binding = %{
      c.document
      | version: Map.put(c.document.version, "original_byte_size", 67_108_865)
    }

    assert {:error, %Error{code: :integrity_failure}} =
             call(:document, [c.runtime, c.session, binding])

    refute Enum.any?(events(), &match?({:wire, :lease, _}, &1))
  end

  test "nonempty Asset uses positive bounded Range for every preflight and delivery read", c do
    bytes = :binary.copy("a", 131_073)
    Process.put(:export_read_bytes, bytes)
    binding = asset_binding(bytes)
    Process.put(:export_read_asset, binding)
    assert {:ok, delivery} = call(:asset, [c.runtime, c.session, binding])
    assert delivery.sha256 == sha(bytes)

    assert {:ok, 131_073} =
             delivery.reduce.(0, fn chunk, size ->
               assert byte_size(chunk) in 1..65_536
               {:ok, size + byte_size(chunk)}
             end)

    trace = events()
    ranges = for {:wire, :range, range} <- trace, do: range
    assert length(ranges) >= 6

    for range <- ranges do
      assert %Range{step: 1} = range
      assert range.first >= 0 and range.last < 131_073
      assert Range.size(range) in 1..65_536
      assert Enum.any?(trace, &match?({:wire, :asset_guard, Repo, ^binding, ^range}, &1))
    end

    assert_no_leases()
  end

  test "only exact canonical zero Asset selects all through the fixed guard before original callback",
       c do
    binding = asset_binding("")
    Process.put(:export_read_bytes, "")
    Process.put(:export_read_asset, binding)
    before = c.runtime
    assert {:ok, delivery} = call(:asset, [c.runtime, c.session, binding])
    assert delivery.sha256 == sha("")
    assert delivery.byte_size == 0

    assert {:ok, :empty} =
             delivery.reduce.(:empty, fn _, _ -> flunk("empty Asset emitted bytes") end)

    trace = events()
    assert {:wire, :asset_guard, Repo, binding, :zero} in trace
    assert Enum.any?(trace, &match?({:wire, :range, :all}, &1))
    guard = Enum.find_index(trace, &match?({:wire, :asset_guard, _, _, _}, &1))
    selected = Enum.find_index(trace, &match?({:wire, :asset_selection, _}, &1))
    read = Enum.find_index(trace, &match?({:wire, :range, _}, &1))
    audit = Enum.find_index(trace, &match?({:wire, :audit, _}, &1))
    commit = Enum.find_index(trace, &match?({:wire, :commit}, &1))
    assert guard < selected and selected < read and read < audit and audit < commit
    assert c.runtime == before
    refute Repo.in_transaction?()
    assert_no_leases()
  end

  for {field, value} <- [{"format_version", 2}, {"ciphertext_byte_size", 135}] do
    test "noncanonical zero #{field} denies before the original bytes callback", c do
      binding = asset_binding("") |> Map.put(unquote(field), unquote(value))

      assert {:error, %Error{code: :integrity_failure}} =
               call(:asset, [c.runtime, c.session, binding])

      refute Enum.any?(events(), &match?({:wire, :range, _}, &1))
      assert_no_leases()
    end
  end

  test "a changed exact binding denies before leasing instead of following another object", c do
    Process.put(:export_read_guard, {:error, Error.new(:integrity_failure)})

    assert {:error, %Error{code: :integrity_failure}} =
             call(:asset, [c.runtime, c.session, c.asset])

    assert {:error, %Error{code: :integrity_failure}} =
             call(:document, [c.runtime, c.session, c.document])

    refute Enum.any?(events(), &match?({:wire, :lease, _}, &1))
    assert_no_leases()
  end

  test "request-selected owner adapters paths and quota fields are not accepted binding fields",
       c do
    for {field, value} <- [
          {"adapter", Reader},
          {"root", c.tmp_dir},
          {"limits", %{}},
          {"owner", @principal}
        ] do
      assert {:error, %Error{code: :invalid}} =
               call(:asset, [c.runtime, c.session, Map.put(c.asset, field, value)])
    end

    for session <- [nil, true, Map.from_struct(c.session)] do
      assert {:error, %Error{code: :invalid}} = call(:asset, [c.runtime, session, c.asset])
    end

    refute Enum.any?(events(), &match?({:wire, :lease, _}, &1))
  end

  test "nested caller transaction denies before selection or transfer", c do
    Process.put(:export_read_transaction, true)
    assert {:error, %Error{code: :invalid}} = call(:asset, [c.runtime, c.session, c.asset])
    assert {:error, %Error{code: :invalid}} = call(:document, [c.runtime, c.session, c.document])
    Process.put(:export_read_transaction, false)
    refute Enum.any?(events(), &match?({:wire, :lease, _}, &1))
  end

  for mode <- [:read_failure, :audit_failure, :commit_failure] do
    test "#{mode} yields no success descriptor and leaves no synthetic lease", c do
      error = Error.new(:storage_unavailable, retryable?: true)

      case unquote(mode) do
        :read_failure -> Process.put(:export_read_reader_error, error)
        :audit_failure -> Process.put(:export_read_audit, {:error, error})
        :commit_failure -> Process.put(:export_read_commit_error, error)
      end

      assert {:error, ^error} = call(:asset, [c.runtime, c.session, c.asset])
      refute Repo.in_transaction?()
      assert_no_leases()
    end
  end

  test "delivery repeats digest and binding checks and rejects source change at completion", c do
    assert {:ok, delivery} = call(:document, [c.runtime, c.session, c.document])

    assert {:error, %Error{code: :integrity_failure}} =
             delivery.reduce.(:initial, fn _chunk, acc ->
               Process.put(:export_read_guard, {:error, Error.new(:integrity_failure)})
               {:ok, acc}
             end)

    assert_no_leases()
    refute Repo.in_transaction?()
  end

  for mode <- [:revoked, :locked, :cancel, :raise] do
    test "#{mode} between delivered chunks never reports completion and revokes custody", c do
      bytes = :binary.copy("b", 65_537)
      Process.put(:export_read_bytes, bytes)
      binding = document_binding(c.asset, bytes)
      assert {:ok, delivery} = call(:document, [c.runtime, c.session, binding])

      result =
        delivery.reduce.(0, fn chunk, size ->
          assert byte_size(chunk) <= 65_536

          case unquote(mode) do
            :revoked ->
              Process.put(:export_read_live, %{Process.get(:export_read_live) | capabilities: []})
              {:ok, size + byte_size(chunk)}

            :locked ->
              Process.put(:export_read_unlock, {:error, :waiting_for_unlock})
              {:ok, size + byte_size(chunk)}

            :cancel ->
              {:error, Error.new(:conflict)}

            :raise ->
              raise "synthetic consumer failure"
          end
        end)

      assert {:error, %Error{}} = result
      assert_no_leases()
      refute Repo.in_transaction?()
    end
  end

  for kind <- [:note, :fragment] do
    test "sealed #{kind} text uses captured digest and repeats actual-kind liveness checks", c do
      {sealed, binding, bytes} = text_binding(c, unquote(kind))

      try do
        assert {:ok, delivery} = call(unquote(kind), [c.runtime, c.session, binding])
        assert delivery.sha256 == sha(bytes)

        assert {:ok, ^bytes} =
                 delivery.reduce.("", fn chunk, acc ->
                   assert byte_size(chunk) <= 65_536
                   {:ok, acc <> chunk}
                 end)

        assert Enum.count(events(), &match?({:wire, :text_guard, _, _, _}, &1)) >= 2
        assert_no_leases()
      after
        assert :ok = Spool.abort(sealed)
      end
    end

    test "sealed #{kind} text cannot retarget a reference or downgrade completion denial", c do
      {sealed, binding, _bytes} = text_binding(c, unquote(kind))

      try do
        wrong = put_in(binding.text_ref.capture_id, "different-capture")
        assert {:error, %Error{}} = call(unquote(kind), [c.runtime, c.session, wrong])
        assert {:ok, delivery} = call(unquote(kind), [c.runtime, c.session, binding])

        assert {:error, %Error{code: :not_found}} =
                 delivery.reduce.(:initial, fn _, acc ->
                   Process.put(:export_read_guard, {:error, Error.new(:not_found)})
                   {:ok, acc}
                 end)

        assert_no_leases()
      after
        assert :ok = Spool.abort(sealed)
      end
    end
  end

  # Native sealed-capture lifetime/cleanup witnesses; canonical eligibility is
  # still synthetic composition here, not evidence of live SQL authorization.
  for kind <- [:note, :fragment],
      content <- [:normal, :empty],
      invalidation <- [:expiry, :abort],
      phase <- [:descriptor, :reducer] do
    test "sealed #{kind} #{content} #{phase} denies #{invalidation} during its final guard", c do
      assert_final_text_guard(
        c,
        unquote(kind),
        unquote(content),
        unquote(invalidation),
        unquote(phase)
      )
    end
  end

  defp assert_final_text_guard(c, kind, content, invalidation, phase) do
    clock = :atomics.new(1, signed: true)
    c = Map.put(c, :text_clock, fn -> :atomics.get(clock, 1) end)
    bytes = if content == :empty, do: "", else: nil
    {sealed, binding, bytes} = text_binding(c, kind, bytes)
    last_index = div(max(byte_size(bytes) - 1, 0), 65_536)
    guard_count = last_index + 3
    witness = :atomics.new(2, signed: true)

    try do
      delivery =
        if phase == :reducer do
          assert {:ok, delivery} = call(kind, [c.runtime, c.session, binding])
          assert delivery.byte_size == byte_size(bytes)
          assert delivery.sha256 == sha(bytes)
          events()
          delivery
        end

      Process.put(:export_read_text_hook, fn actual_kind, repo, actual_binding ->
        assert actual_kind == kind
        assert repo == Repo
        assert actual_binding == binding
        assert Repo.in_transaction?()
        count = :atomics.add_get(witness, 1, 1)
        assert count <= guard_count
        assert {:ok, _} = Spool.read_chunk(sealed, binding.text_ref, last_index)

        if count == guard_count do
          assert :atomics.add_get(witness, 2, 1) == 1

          case invalidation do
            :expiry ->
              :atomics.put(clock, 1, sealed._deadline)

            :abort ->
              assert :ok = Spool.abort(sealed)
          end
        end

        :ok
      end)

      result =
        if phase == :descriptor do
          call(kind, [c.runtime, c.session, binding])
        else
          delivery.reduce.(0, fn chunk, size ->
            assert byte_size(chunk) in 1..65_536
            {:ok, size + byte_size(chunk)}
          end)
        end

      assert :atomics.get(witness, 1) == guard_count
      assert :atomics.get(witness, 2) == 1

      if invalidation == :expiry do
        assert :atomics.get(clock, 1) == sealed._deadline
      end

      refute Repo.in_transaction?()
      assert_no_leases()
      trace = events()
      assert Enum.count(trace, &match?({:wire, :text_guard, _, _, _}, &1)) == guard_count
      assert Enum.count(trace, &match?({:wire, :scope, _}, &1)) == guard_count
      assert Enum.count(trace, &match?({:wire, :commit}, &1)) == guard_count
      assert Enum.count(trace, &match?({:wire, :closed}, &1)) == guard_count

      # The first expired native read denies with integrity_failure and
      # aborts its owned capture. Explicit abort already denies with invalid.
      code = if invalidation == :expiry, do: :integrity_failure, else: :invalid
      assert {:error, %Error{code: ^code, retryable?: false, message: nil} = error} = result
      assert error.details == %{}

      assert {:error, %Error{code: :invalid, retryable?: false, message: nil} = native_error} =
               Spool.read_chunk(sealed, binding.text_ref, last_index)

      assert native_error.details == %{}
      assert [] = File.ls!(Path.join(c.tmp_dir, Atom.to_string(kind)))
    after
      Process.delete(:export_read_text_hook)
      assert :ok = Spool.abort(sealed)
      assert [] = File.ls!(Path.join(c.tmp_dir, Atom.to_string(kind)))
      refute Repo.in_transaction?()
      assert_no_leases()
    end
  end

  defp call(function, args) do
    assert Code.ensure_loaded?(@read), "missing concrete knowledge ExportRead"
    assert function_exported?(@read, function, length(args))
    apply(@read, function, args)
  end

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp asset_binding(bytes) do
    %{
      "kind" => "asset",
      "resource_id" => @resource,
      "version_id" => @version,
      "asset_id" => @asset,
      "object_id" => @object,
      "owner_scope_id" => @owner,
      "classification" => "private",
      "key_domain_id" => uuid(8),
      "domain_key_version_id" => uuid(9),
      "domain_key_generation" => 1,
      "object_generation" => 1,
      "lookup_digest" => sha("lookup"),
      "ciphertext_hash" => sha("ciphertext"),
      "plaintext_byte_size" => byte_size(bytes),
      "ciphertext_byte_size" =>
        134 + byte_size(bytes) + div(byte_size(bytes) + 4_194_303, 4_194_304) * 24,
      "storage_ref" => @object,
      "format_version" => 1,
      "plaintext_sha256" => nil
    }
  end

  defp document_binding(asset, bytes) do
    %{
      version: %{
        "resource_id" => uuid(10),
        "version_id" => uuid(11),
        "kind" => "document",
        "original_digest" => sha(bytes),
        "original_byte_size" => byte_size(bytes)
      },
      source:
        Map.merge(
          asset,
          Map.take(asset_binding(bytes), ["plaintext_byte_size", "ciphertext_byte_size"])
        )
    }
  end

  defp wrong_original("original_digest"), do: sha("wrong")
  defp wrong_original("original_byte_size"), do: 9

  defp text_binding(c, kind, bytes \\ nil) do
    root = Path.join(c.tmp_dir, Atom.to_string(kind))
    File.mkdir!(root)
    File.chmod!(root, 0o700)

    context = %{
      root: root,
      storage_root: Path.join(c.tmp_dir, "cipher"),
      backup_root: Path.join(c.tmp_dir, "backup")
    }

    context =
      if Map.has_key?(c, :text_clock), do: Map.put(context, :clock, c.text_clock), else: context

    assert {:ok, spool} = Spool.open(context)

    bytes =
      bytes ||
        if(kind == :note, do: :binary.copy("界", 22_000), else: "captured fragment 界")

    locator = %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}
    fragment_id = DocumentFragment.id(@version, locator, 0, :crypto.hash(:sha256, bytes))

    selector =
      if kind == :note,
        do: {:note_markdown, @resource, @version},
        else: {:fragment_text, @resource, @version, 0, fragment_id}

    spool =
      if bytes == "" do
        assert {:ok, next} = Spool.append(spool, selector, "")
        next
      else
        append_text(spool, selector, bytes)
      end

    assert {:ok, sealed} = Spool.seal(spool)
    ref = Map.fetch!(sealed.text_refs, selector)

    record =
      if kind == :note do
        %{
          "resource_id" => @resource,
          "version_id" => @version,
          "kind" => "note",
          "availability" => "included",
          "body_digest" => sha(bytes),
          "title" => "Captured",
          "body_path" => "notes/" <> @resource <> "--" <> @version <> ".md"
        }
      else
        %{
          "resource_id" => @resource,
          "version_id" => @version,
          "id" => fragment_id,
          "ordinal" => 0,
          "digest" => sha(bytes),
          "locator" => locator,
          "extracted_path" => "documents/extracted/" <> @resource <> "--" <> @version <> ".txt",
          "start_byte" => 0,
          "byte_size" => byte_size(bytes)
        }
      end

    key = if kind == :note, do: :version, else: :fragment
    {sealed, Map.put(%{capture: sealed, text_ref: ref}, key, record), bytes}
  end

  defp uuid(n),
    do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(14_000 + n), 12, "0")

  defp append_text(spool, selector, <<chunk::binary-size(65_536), rest::binary>>) do
    assert {:ok, next} = Spool.append(spool, selector, chunk)
    append_text(next, selector, rest)
  end

  defp append_text(spool, _selector, ""), do: spool

  defp append_text(spool, selector, chunk) do
    assert {:ok, next} = Spool.append(spool, selector, chunk)
    next
  end

  defp assert_request_leases(trace, c) do
    requests = for {:wire, :lease, request} <- trace, do: request
    assert requests != []

    for request <- requests do
      assert request.purpose == :document_source
      assert request.access == :request
      assert request.session_id == c.session.session_id
      assert request.principal_id == c.session.principal_id
      assert request.vault_id == c.session.vault_id
      assert request.resource_version_id == c.document.version["version_id"]
      assert request.object_id == c.document.source["object_id"]
      assert request.object_generation == 1
      assert request.required_capability == "asset.read"
      assert request.principal_authorization_epoch == 7
      assert request.vault_authorization_epoch == 23
      refute Map.has_key?(request, :job_id)
      refute Map.has_key?(request, :key)
    end
  end

  defp assert_no_leases do
    refute Enum.any?(Process.get(), fn {key, _} -> match?({:export_read_lease, _}, key) end)
  end

  defp events(acc \\ []) do
    receive do
      event when elem(event, 0) == :wire -> events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
