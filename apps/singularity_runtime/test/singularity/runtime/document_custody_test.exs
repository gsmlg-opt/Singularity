defmodule Singularity.Runtime.DocumentCustodyTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.{DownloadLease, KeyCustodian, KeyLease, KeyLeaseSupervisor}

  @now ~U[2026-09-22 08:00:00Z]

  defmodule IdleLock do
    def idle_lock(_owner, _session), do: :ok
  end

  defmodule Reader do
    def load_object_key(context, binding, _hierarchy) do
      send(context.owner, {:load_document_key, binding})
      {:ok, %{object_dek: :binary.copy(<<1>>, 32), reader_binding: binding}}
    end

    def load_checkpoint(_context, binding) do
      {:ok, Singularity.Runtime.KeyLease.document_checkpoint(binding, 0)}
    end

    def read_chunk(context, binding, index) do
      send(context.owner, {:read_document_chunk, binding, index})
      {:ok, "source"}
    end

    def persist_checkpoint(_context, _binding, _expected, _next) do
      :ok
    end

    def read_range(context, binding, range) do
      send(context.owner, {:read_document_range, binding, range})
      {:ok, "source"}
    end
  end

  defmodule Authorization do
    def revalidate(context, binding) do
      send(context.owner, {:revalidate_document, binding})
      :ok
    end
  end

  defmodule Clock do
    def utc_now(%{now: now}), do: now
  end

  test "worker source lease requires unlock and pins version in checkpoint" do
    {custodian, request} = setup_custodian()

    assert {:error, %Error{code: :invalid}} =
             KeyCustodian.lease(custodian, Map.put(request, :session_id, "session-1"))

    assert {:error, :waiting_for_unlock} = KeyCustodian.lease(custodian, request)
    assert :ok = unlock(custodian)
    assert {:ok, lease} = KeyCustodian.lease(custodian, request)
    assert {:ok, "source"} = KeyLease.read_chunk(lease, 0)
    assert_receive {:revalidate_document, revalidated}
    assert revalidated.resource_version_id == request.resource_version_id
    assert_receive {:read_document_chunk, binding, 0}
    assert binding.resource_version_id == request.resource_version_id
    assert binding.session_id == "session-1"
    expected = KeyLease.document_checkpoint(request, 0)
    next = KeyLease.document_checkpoint(request, 1)
    assert expected["protocol"] == "document_source_v1"
    assert expected["resource_version_id"] == request.resource_version_id
    assert next["next_chunk_index"] == 1
  end

  test "request source lease is session-bound and does not accept worker fields" do
    {custodian, worker_request} = setup_custodian()
    assert :ok = unlock(custodian)

    request =
      worker_request
      |> Map.delete(:job_id)
      |> Map.merge(%{access: :request, session_id: "session-1"})

    assert {:error, %Error{code: :invalid}} =
             KeyCustodian.lease(custodian, Map.put(request, :job_id, "job-1"))

    assert {:ok, lease} = KeyCustodian.lease(custodian, request)
    assert {:ok, "source"} = DownloadLease.read_document_chunk(lease, 0)
    assert_receive {:revalidate_document, revalidated}
    assert revalidated.resource_version_id == request.resource_version_id
    assert_receive {:read_document_chunk, binding, 0}
    assert binding.resource_version_id == request.resource_version_id
    assert {:ok, token} = KeyCustodian.begin_revoke(custodian, %{session_id: "session-1"})
    assert :ok = KeyCustodian.finish_revoke(custodian, token)
    assert {:error, :waiting_for_unlock} = DownloadLease.read_document_chunk(lease, 1)
  end

  defp setup_custodian do
    context = %{owner: self(), now: @now}
    supervisor = start_supervised!({KeyLeaseSupervisor, name: nil}, id: make_ref())

    custodian =
      start_supervised!(
        {KeyCustodian,
         %{
           authorization: Authorization,
           clock: Clock,
           context: context,
           idle_lock: {IdleLock, self()},
           key_reader: Reader,
           lease_supervisor: supervisor,
           object_key_loader: Reader
         }},
        id: make_ref()
      )

    request = %{
      purpose: :document_source,
      access: :worker,
      job_id: "job-1",
      resource_version_id: "version-1",
      vault_id: "vault-1",
      principal_id: "principal-1",
      required_capability: "asset.read",
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 23,
      object_id: "object-1",
      object_generation: 3
    }

    {custodian, request}
  end

  defp unlock(custodian) do
    session = %{
      session_id: "session-1",
      expires_at: DateTime.add(@now, 300, :second),
      principal_id: "principal-1",
      vault_id: "vault-1",
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 23,
      vault_key: :binary.copy(<<1>>, 32),
      domain_key: :binary.copy(<<2>>, 32),
      domain_dedup_key: :binary.copy(<<3>>, 32),
      key_domain_id: "domain-1",
      domain_key_version_id: "domain-version-1",
      domain_key_generation: 5,
      domain_classification: :private,
      object_keys: %{{"object-1", 3} => :binary.copy(<<4>>, 32)}
    }

    with {:ok, pending} <- KeyCustodian.prepare_unlock(custodian, session) do
      KeyCustodian.activate_unlock(custodian, pending)
    end
  end
end

defmodule Singularity.Runtime.DocumentCustodyPermissionTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Singularity.Storage.WorkerRepo

  test "worker role cannot directly read the pinned Document table" do
    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             Ecto.Adapters.SQL.query(
               WorkerRepo,
               "SELECT resource_version_id FROM content.document_versions LIMIT 0",
               [],
               log: false
             )
  end
end
