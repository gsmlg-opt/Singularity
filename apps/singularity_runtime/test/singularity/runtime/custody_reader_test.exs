defmodule Singularity.Runtime.CustodyReaderTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Core.ObjectRef
  alias Singularity.Runtime.CustodyReader
  alias Singularity.Runtime.DownloadLease
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.KeyLease
  alias Singularity.Runtime.KeyLeaseSupervisor
  alias Singularity.Storage.Crypto.ChunkedAEAD
  alias Singularity.Storage.Crypto.Format
  alias Singularity.Storage.Crypto.KeyWrapper
  alias Singularity.Storage.Local.PathGuard
  alias Singularity.Storage.LocalFilesystemAdapter

  @moduletag :tmp_dir

  @vault_id "00000000-0000-0000-0000-000000000001"
  @other_vault_id "00000000-0000-0000-0000-000000000009"
  @domain_id "00000000-0000-0000-0000-000000000002"
  @other_domain_id "00000000-0000-0000-0000-000000000008"
  @domain_key_version_id "00000000-0000-0000-0000-000000000003"
  @object_id "00000000-0000-0000-0000-000000000004"
  @session_id "00000000-0000-0000-0000-000000000005"
  @principal_id "00000000-0000-0000-0000-000000000006"
  @job_id "00000000-0000-0000-0000-000000000007"
  @object_generation 3

  defmodule ImmediateScope do
    def transact(repo, _binding, callback), do: callback.(repo)
  end

  defmodule CheckpointScope do
    def transact(owner, repo, binding, callback) do
      send(owner, {:checkpoint_scope_binding, binding})
      callback.(repo)
    end
  end

  defmodule ReaderScope do
    def transact(owner, repo, binding, callback) do
      send(owner, {:reader_scope_binding, binding})
      callback.(repo)
    end
  end

  defmodule Repository do
    use Agent

    alias Singularity.Core.Error

    def start_link(options) do
      Agent.start_link(fn ->
        %{
          cas_miss: Keyword.get(options, :cas_miss, {:error, Error.new(:conflict)}),
          checkpoint: Keyword.fetch!(options, :checkpoint),
          material: Keyword.fetch!(options, :material)
        }
      end)
    end

    def load_reader_material(repository, binding) do
      Agent.get(repository, fn %{material: material} ->
        if material.object_id == binding.object_id and
             material.vault_id == binding.vault_id and
             material.object_generation == binding.object_generation do
          {:ok, material}
        else
          {:error, Error.new(:forbidden)}
        end
      end)
    end

    def revalidate_reader(repository, binding, reader_binding) do
      with {:ok, material} <- load_reader_material(repository, binding),
           true <- material.object_id == reader_binding.object_id,
           true <- material.vault_id == reader_binding.vault_id,
           true <- material.key_domain_id == reader_binding.key_domain_id,
           true <- material.classification == reader_binding.classification do
        :ok
      else
        {:error, %Error{}} = error -> error
        false -> {:error, Error.new(:conflict)}
      end
    end

    def load_checkpoint(repository, _binding, _classification) do
      Agent.get(repository, &{:ok, &1.checkpoint})
    end

    def persist_checkpoint(repository, _binding, _classification, expected, next) do
      Agent.get_and_update(repository, fn state ->
        if state.checkpoint == expected do
          {:ok, %{state | checkpoint: next}}
        else
          {state.cas_miss, state}
        end
      end)
    end

    def replace_material(repository, callback) do
      Agent.update(repository, &update_in(&1.material, callback))
    end
  end

  defmodule Authorization do
    def revalidate(context, binding) do
      context.repository_adapter.revalidate_reader(
        context.repo,
        binding,
        context.object_binding
      )
    end
  end

  setup %{tmp_dir: tmp_dir} do
    plaintext = "authenticated custody plaintext"
    object_dek = :crypto.strong_rand_bytes(32)
    domain_key = :crypto.strong_rand_bytes(32)
    lookup_digest = :crypto.strong_rand_bytes(32)

    {:ok, wrapper} =
      KeyWrapper.wrap(domain_key, object_dek, %{
        purpose: :object_dek,
        generation: @object_generation,
        aad: "object:" <> @object_id
      })

    published =
      publish!(tmp_dir, plaintext, object_dek, lookup_digest)

    material = %{
      object_id: @object_id,
      object_generation: @object_generation,
      vault_id: @vault_id,
      key_domain_id: @domain_id,
      domain_key_version_id: @domain_key_version_id,
      domain_key_generation: 5,
      domain_classification: :private,
      classification: :private,
      envelope_classification: :private,
      lifecycle: :available,
      wrapper_algorithm: "aes_256_gcm",
      wrapped_dek: wrapper.encoded,
      lookup_digest: lookup_digest,
      ciphertext_hash: published.ciphertext_hash,
      plaintext_byte_size: byte_size(plaintext),
      ciphertext_byte_size: published.ciphertext_byte_size,
      format_version: Format.format_version()
    }

    request = lease_request()
    checkpoint = KeyLease.checkpoint(request, 0)

    repository =
      start_supervised!(
        {Repository, material: material, checkpoint: checkpoint},
        id: make_ref()
      )

    context = %{
      key_wrapper: KeyWrapper,
      repo: repository,
      repository_adapter: Repository,
      scope: ImmediateScope,
      storage: %{
        adapter: LocalFilesystemAdapter,
        context: %{root: tmp_dir}
      }
    }

    lease_supervisor =
      start_supervised!(
        {KeyLeaseSupervisor, name: nil},
        id: make_ref()
      )

    custodian =
      start_supervised!(
        {KeyCustodian,
         %{
           authorization: Authorization,
           clock: CustodyReader,
           context: context,
           idle_lock: fn _session -> :ok end,
           key_reader: CustodyReader,
           lease_supervisor: lease_supervisor,
           object_key_loader: CustodyReader
         }},
        id: make_ref()
      )

    {:ok,
     context: context,
     custodian: custodian,
     domain_key: domain_key,
     object_dek: object_dek,
     path: published.path,
     plaintext: plaintext,
     repository: repository,
     request: request}
  end

  test "unwraps the exact envelope and exposes only an opaque lease and authenticated chunks",
       context do
    assert :ok = activate(context.custodian, unlocked_session(context.domain_key))
    assert {:ok, lease} = KeyCustodian.lease(context.custodian, context.request)
    assert is_pid(lease)
    assert {:ok, context.plaintext} == KeyLease.read_chunk(lease, 0)

    returned = [lease, context.plaintext]
    refute context.domain_key in returned
    refute context.object_dek in returned
    refute unlocked_session(context.domain_key).vault_key in returned
  end

  test "preserves the internal checkpoint-advanced outcome", context do
    Agent.update(context.repository, &Map.put(&1, :cas_miss, {:error, :checkpoint_advanced}))

    metadata_binding =
      context.request
      |> Map.delete(:session_id)
      |> Map.put(:processing_revision, 4)
      |> Map.put(:declared_media_type, "application/octet-stream")
      |> Map.put(:plaintext_byte_size, byte_size(context.plaintext))

    checkpoint_context =
      context.context
      |> Map.take([:repo, :repository_adapter, :scope])
      |> Map.put(:checkpoint_classification, :private)
      |> Map.put(:scope, {CheckpointScope, self()})

    stale = KeyLease.checkpoint(context.request, 1)
    next = KeyLease.checkpoint(context.request, 2)

    assert {:error, :checkpoint_advanced} =
             CustodyReader.persist_checkpoint(
               checkpoint_context,
               metadata_binding,
               stale,
               next
             )

    assert_receive {:checkpoint_scope_binding, ^metadata_binding}
  end

  test "preserves the v2 session binding at checkpoint repository boundaries", context do
    binding = Map.put(context.request, :processing_revision, 1)

    checkpoint_context =
      context.context
      |> Map.take([:repo, :repository_adapter, :scope])
      |> Map.put(:checkpoint_classification, :private)
      |> Map.put(:scope, {CheckpointScope, self()})

    expected = KeyLease.checkpoint(context.request, 0)
    next = KeyLease.checkpoint(context.request, 1)

    assert :ok =
             CustodyReader.persist_checkpoint(
               checkpoint_context,
               binding,
               expected,
               next
             )

    assert_receive {:checkpoint_scope_binding, ^binding}
  end

  test "preserves the v2 session binding at reader repository boundaries", context do
    binding = Map.put(context.request, :processing_revision, 1)
    reader_context = Map.put(context.context, :scope, {ReaderScope, self()})
    session = unlocked_session(context.domain_key)

    hierarchy = %{
      domain_key: session.domain_key,
      cached_object_keys: %{},
      key_domain_id: session.key_domain_id,
      domain_key_version_id: session.domain_key_version_id,
      domain_key_generation: session.domain_key_generation,
      domain_classification: session.domain_classification
    }

    assert {:ok, %{reader_binding: _reader_binding}} =
             CustodyReader.load_object_key(reader_context, binding, hierarchy)

    assert_receive {:reader_scope_binding, ^binding}
  end

  test "keeps sessionless metadata bindings unchanged at reader repository boundaries", context do
    checkpoint_binding =
      context.request
      |> Map.delete(:session_id)
      |> Map.put(:processing_revision, 4)
      |> Map.put(:declared_media_type, "application/octet-stream")
      |> Map.put(:plaintext_byte_size, byte_size(context.plaintext))

    reader_context =
      context.context
      |> Map.put(:scope, {ReaderScope, self()})

    session = unlocked_session(context.domain_key)

    hierarchy = %{
      domain_key: session.domain_key,
      cached_object_keys: %{},
      key_domain_id: session.key_domain_id,
      domain_key_version_id: session.domain_key_version_id,
      domain_key_generation: session.domain_key_generation,
      domain_classification: session.domain_classification
    }

    assert {:ok, %{reader_binding: object_binding}} =
             CustodyReader.load_object_key(reader_context, checkpoint_binding, hierarchy)

    assert_receive {:reader_scope_binding, ^checkpoint_binding}

    assert :ok =
             CustodyReader.revalidate(
               Map.put(reader_context, :object_binding, object_binding),
               checkpoint_binding
             )

    assert_receive {:reader_scope_binding, ^checkpoint_binding}
  end

  test "one-use download leases authenticate full and internally aligned range reads",
       context do
    assert :ok = activate(context.custodian, unlocked_session(context.domain_key))
    request = Map.put(context.request, :purpose, :download)

    assert {:ok, full_lease} =
             KeyCustodian.lease(context.custodian, request)

    plaintext = context.plaintext

    assert {:ok, ^plaintext} =
             DownloadLease.read(full_lease, :all)

    assert {:ok, range_lease} =
             KeyCustodian.lease(context.custodian, request)

    expected_range = binary_part(context.plaintext, 2, 7)

    assert {:ok, ^expected_range} =
             DownloadLease.read(range_lease, 2..8)
  end

  test "denies wrong object, generation, and vault bindings before issuing a lease", context do
    assert :ok = activate(context.custodian, unlocked_session(context.domain_key))

    for request <- [
          %{context.request | object_id: Ecto.UUID.generate()},
          %{context.request | object_generation: @object_generation + 1},
          %{context.request | vault_id: @other_vault_id}
        ] do
      assert {:error, _denial} = KeyCustodian.lease(context.custodian, request)
    end
  end

  test "denies a hierarchy for the wrong domain", context do
    assert :ok =
             activate(
               context.custodian,
               unlocked_session(context.domain_key,
                 key_domain_id: @other_domain_id
               )
             )

    assert {:error, %Error{code: :integrity_failure}} =
             KeyCustodian.lease(context.custodian, context.request)
  end

  test "a corrupt wrapper fails with a typed integrity error", context do
    Repository.replace_material(context.repository, fn material ->
      %{material | wrapped_dek: flip_last_byte(material.wrapped_dek)}
    end)

    assert :ok = activate(context.custodian, unlocked_session(context.domain_key))

    assert {:error, %Error{code: :integrity_failure}} =
             KeyCustodian.lease(context.custodian, context.request)
  end

  test "ciphertext corruption is preserved as a typed integrity error", context do
    assert :ok = activate(context.custodian, unlocked_session(context.domain_key))
    assert {:ok, lease} = KeyCustodian.lease(context.custodian, context.request)
    corrupt_byte!(context.path, Format.header_size() + 8)

    assert {:error, %Error{code: :integrity_failure}} =
             KeyLease.read_chunk(lease, 0)
  end

  defp activate(custodian, session) do
    with {:ok, pending} <- KeyCustodian.prepare_unlock(custodian, session) do
      KeyCustodian.activate_unlock(custodian, pending)
    end
  end

  defp unlocked_session(domain_key, overrides \\ []) do
    %{
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      vault_key: :binary.copy(<<0xA1>>, 32),
      domain_key: domain_key,
      domain_dedup_key: :binary.copy(<<0xD1>>, 32),
      key_domain_id: @domain_id,
      domain_key_version_id: @domain_key_version_id,
      domain_key_generation: 5,
      domain_classification: :private
    }
    |> Map.merge(Map.new(overrides))
  end

  defp lease_request do
    %{
      job_id: @job_id,
      vault_id: @vault_id,
      principal_id: @principal_id,
      required_capability: "asset.read",
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      object_id: @object_id,
      object_generation: @object_generation,
      session_id: @session_id
    }
  end

  defp publish!(tmp_dir, plaintext, object_dek, lookup_digest) do
    object_ref = %ObjectRef{object_id: @object_id}

    {:ok, ciphertext} =
      ChunkedAEAD.encode(%{
        key: object_dek,
        plaintext: plaintext,
        format_version: Format.format_version(),
        algorithm: Format.algorithm(),
        chunk_size: Format.chunk_size(),
        vault_id: @vault_id,
        encryption_domain_id: @domain_id,
        object_id: @object_id,
        chunk_index: 0
      })

    lookup_digest_hex = Base.encode16(lookup_digest, case: :lower)

    storage_context = %{
      root: tmp_dir,
      vault_namespace: @vault_id,
      domain_namespace: @domain_id,
      lookup_digest: lookup_digest_hex
    }

    assert {:ok, stage_ref} =
             LocalFilesystemAdapter.stage(storage_context, %{})

    assert :ok =
             LocalFilesystemAdapter.append_encrypted_chunk(
               storage_context,
               stage_ref,
               ciphertext
             )

    assert {:ok, %{sealed?: true}} =
             LocalFilesystemAdapter.seal_stage(
               storage_context,
               stage_ref,
               %{}
             )

    assert {:ok, ^object_ref} =
             LocalFilesystemAdapter.finalize(
               storage_context,
               stage_ref,
               object_ref
             )

    assert {:ok, path} =
             PathGuard.object_path(
               tmp_dir,
               @vault_id,
               @domain_id,
               lookup_digest_hex
             )

    %{
      path: path,
      ciphertext_hash: :crypto.hash(:sha256, ciphertext),
      ciphertext_byte_size: byte_size(ciphertext)
    }
  end

  defp flip_last_byte(binary) do
    size = byte_size(binary)
    <<prefix::binary-size(size - 1), last>> = binary
    prefix <> <<Bitwise.bxor(last, 1)>>
  end

  defp corrupt_byte!(path, offset) do
    File.chmod!(path, 0o600)
    {:ok, io} = :file.open(path, [:read, :write, :binary])

    try do
      {:ok, <<byte>>} = :file.pread(io, offset, 1)
      :ok = :file.pwrite(io, offset, <<Bitwise.bxor(byte, 1)>>)
      :ok = :file.sync(io)
    after
      :ok = :file.close(io)
    end
  end
end
