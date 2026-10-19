defmodule Singularity.Runtime.KnowledgeExportCustodyLiveTest do
  use Singularity.Storage.DataCase, async: false

  alias Singularity.Core.{DocumentFragment, Error, ObjectRef}

  alias Singularity.Runtime.{
    AuthorizationDependencies,
    Authorize,
    DownloadLease,
    KeyCustodian,
    KeyLeaseSupervisor,
    OperationScope,
    ResolveSession
  }

  alias Singularity.Runtime.Assets.Download

  alias Singularity.Storage.{
    AuthorizationLock,
    Fixtures,
    KnowledgeFixtures,
    LocalFilesystemAdapter,
    MigrationRepo,
    ScopedRepo,
    VaultLock
  }

  alias Singularity.Storage.Crypto.{ChunkedAEAD, Format, KeyWrapper, ObjectIdentity}
  alias Singularity.Storage.KnowledgeExport.{Repository, Spool}
  alias Singularity.Storage.Local.PathGuard
  alias Singularity.Storage.Postgres.{AssetRepository, IdentityRepository, PreAuth}

  @moduletag :integration
  @moduletag :tmp_dir
  @read Singularity.Runtime.Knowledge.ExportRead
  @asset_scope Singularity.Runtime.Knowledge.ExportRead.AssetScope
  @snapshot Singularity.Runtime.Knowledge.ExportSnapshot

  # Every observer below delegates the actual result unchanged. Messages carry
  # only identities, bounds, native outcomes and opaque lease PIDs, never keys,
  # wrappers, plaintext, SQL parameters or exception messages/stacks.
  defmodule Identity do
    def load_live_session(context, repo, session_id) do
      result = Singularity.Storage.Postgres.IdentityRepository.load_live_session(repo, session_id)
      send(context.parent, {:live_read, :identity, self(), result_kind(result)})
      result
    end

    defp result_kind({:ok, nil}), do: :absent
    defp result_kind({:ok, _}), do: :present
    defp result_kind({:error, _}), do: :error
  end

  defmodule Assets do
    alias Singularity.Runtime.KnowledgeExportCustodyLiveTest, as: Owner

    def authorized_object(context, repo, asset_id) do
      send(
        context.parent,
        {:live_read, :selection_connection, self(), Owner.connection_witness(repo)}
      )

      Owner.barrier(context, :selection, repo)
      result = Singularity.Storage.Postgres.AssetRepository.authorized_object(repo, asset_id)
      send(context.parent, {:live_read, :selected, self(), result})
      result
    end

    def authorized_download_descriptor(_context, repo, asset_id),
      do:
        Singularity.Storage.Postgres.AssetRepository.authorized_download_descriptor(
          repo,
          asset_id
        )
  end

  defmodule Custodian do
    def lease(context, request) do
      result = Singularity.Runtime.KeyCustodian.lease(context.custodian, request)

      case result do
        {:ok, lease} -> send(context.parent, {:live_read, :lease, request, lease})
        _ -> :ok
      end

      result
    end
  end

  defmodule Reader do
    alias Singularity.Runtime.CustodyReader
    alias Singularity.Runtime.KnowledgeExportCustodyLiveTest, as: Owner

    def utc_now(%{export_observer: observer, object_binding: binding} = context) do
      if is_nil(Process.get({__MODULE__, :export_init, observer.token})) do
        Process.put({__MODULE__, :export_init, observer.token}, true)

        send(
          observer.parent,
          {:live_export, :init_observed, self(), observer.token, binding.object_id}
        )

        Owner.composition_init_observed(observer, self())
      end

      Owner.export_barrier(observer, :init, binding.object_id)
      CustodyReader.utc_now(context)
    end

    def utc_now(context), do: CustodyReader.utc_now(context)
    def revalidate(context, binding), do: CustodyReader.revalidate(context, binding)

    def load_object_key(%{export_observer: observer} = context, binding, hierarchy) do
      Owner.export_barrier(observer, :material, binding.object_id)
      load_object_key(Map.delete(context, :export_observer), binding, hierarchy)
    end

    def load_object_key(context, binding, hierarchy) do
      Owner.barrier(context, :material, nil)
      result = CustodyReader.load_object_key(context, binding, hierarchy)

      send(
        context.parent,
        {:live_read, :material, binding.object_id, binding.object_generation, result_kind(result)}
      )

      result
    end

    def read_range(context, binding, range) do
      send(context.parent, {:live_read, :plaintext_range, binding.object_id, range})
      CustodyReader.read_range(context, binding, range)
    end

    def read_chunk(context, binding, index) do
      send(context.parent, {:live_read, :document_chunk, binding.resource_version_id, index})
      CustodyReader.read_chunk(context, binding, index)
    end

    def load_checkpoint(context, binding), do: CustodyReader.load_checkpoint(context, binding)

    def persist_checkpoint(context, binding, expected, next),
      do: CustodyReader.persist_checkpoint(context, binding, expected, next)

    defp result_kind({:ok, _}), do: :ok
    defp result_kind({:error, _}), do: :error
  end

  defmodule Storage do
    alias Singularity.Storage.LocalFilesystemAdapter
    def stat(context, reference), do: LocalFilesystemAdapter.stat(context, reference)
    def verify(context, reference), do: LocalFilesystemAdapter.verify(context, reference)

    def open(context, reference) do
      result = LocalFilesystemAdapter.open(context, reference)
      send(context.parent, {:live_read, :object_open, reference.object_id, result_kind(result)})
      result
    end

    def read_range(%{export_observer: observer} = context, handle, range) do
      result = read_range(Map.delete(context, :export_observer), handle, range)
      Singularity.Runtime.KnowledgeExportCustodyLiveTest.export_barrier(observer, :storage, nil)
      result
    end

    def read_range(context, handle, range) do
      send(context.parent, {:live_read, :ciphertext_range, range})
      LocalFilesystemAdapter.read_range(context, handle, range)
    end

    defp result_kind({:ok, _}), do: :ok
    defp result_kind({:error, _}), do: :error
  end

  # Export acquisition alone uses this fixed adapter. AuthorizationDependencies
  # continues to hold the genuine KeyCustodian directly, as in every old case.
  defmodule ExportCustodian do
    alias Singularity.Runtime.KnowledgeExportCustodyLiveTest, as: Owner

    def lease(context, request) do
      Owner.composition_request_observed(context, request)

      result =
        apply(Singularity.Runtime.KeyCustodian, :export_lease, [context.custodian, request])

      Owner.composition_result_observed(context, request, result)

      case result do
        {:ok, lease} ->
          send(context.parent, {:live_export, :native_returned, self(), context.token, lease})
          Owner.export_barrier(context, :returned, lease)
          send(context.parent, {:live_read, :lease, request, lease})

        _ ->
          :ok
      end

      result
    end

    def export_lease(context, request), do: lease(context, request)
  end

  # Actual native reads/revokes, with only metadata observed at the trusted
  # adapter seam. In particular this is not a replacement materializer.
  defmodule CompositionReader do
    alias Singularity.Runtime.DownloadLease
    alias Singularity.Runtime.KnowledgeExportCustodyLiveTest, as: Owner

    def read(context, lease, range) do
      Owner.composition_read_observed(context, :asset, lease)
      DownloadLease.read(lease, range)
    end

    def read_document_chunk(context, lease, index) do
      Owner.composition_read_observed(context, :document, lease)
      DownloadLease.read_document_chunk(lease, index)
    end

    def authenticate_empty_document_original(context, lease) do
      Owner.composition_read_observed(context, :document, lease)
      DownloadLease.authenticate_empty_document_original(lease)
    end

    def revoke(context, lease) do
      result = DownloadLease.revoke(lease)
      send(context.parent, {:composition, context.token, :revoked, lease, result})
      result
    end
  end

  defmodule CompositionScoped do
    alias Singularity.Runtime.KnowledgeExportCustodyLiveTest, as: Owner

    def transact(context, repo, scope, callback),
      do: transact(context, repo, scope, [], callback)

    def transact(context, repo, scope, options, callback) do
      result =
        Singularity.Storage.ScopedRepo.transact(repo, scope, options, fn scoped ->
          result = callback.(scoped)

          case result do
            {:ok, %{capture_id: _}} ->
              send(
                context.parent,
                {:composition, context.token, :capture_before_commit, self(),
                 scoped.in_transaction?(), Owner.composition_writer_owners(self())}
              )

            _ ->
              :ok
          end

          result
        end)

      kind =
        case result do
          {:ok, %{capture_id: _}} -> :capture
          {:after_commit, fun} when is_function(fun, 0) -> :prepared
          _ -> :scope
        end

      if kind == :capture do
        caller = self()

        Agent.update(context.composition_control, fn state ->
          Map.update(state, :capture_owners, MapSet.new([caller]), &MapSet.put(&1, caller))
        end)
      end

      send(
        context.parent,
        {:composition, context.token, :committed, self(), kind, repo.in_transaction?()}
      )

      result
    end
  end

  defmodule Audit do
    def append(context, repo, event) do
      witness = Singularity.Runtime.KnowledgeExportCustodyLiveTest.connection_witness(repo)
      result = Singularity.Storage.Postgres.AuditSink.append(repo, event)
      send(context.parent, {:live_read, :audit, self(), witness, event, result})
      result
    end
  end

  # SYNTHETIC fault arrangement, actual native SQL outcome: the first append is
  # genuine, then repeating that same event yields the existing unique error.
  defmodule DuplicateAudit do
    def append(context, repo, event) do
      first = Singularity.Storage.Postgres.AuditSink.append(repo, event)
      second = Singularity.Storage.Postgres.AuditSink.append(repo, event)
      send(context.parent, {:live_read, :duplicate_audit, event.audit_event_id, first, second})
      second
    end
  end

  defmodule CommitFailure do
    def transact(context, repo, scope, callback) do
      Singularity.Storage.ScopedRepo.transact(repo, scope, fn scoped ->
        result = callback.(scoped)
        send(context.parent, {:live_read, :commit_callback_returned, self(), result})

        Singularity.Storage.SafeSQL.query!(
          scoped,
          "UPDATE content.resources SET current_version_id=$1 WHERE id=$2 AND vault_id=$3",
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            Ecto.UUID.dump!(context.document),
            Ecto.UUID.dump!(scope.vault_id)
          ]
        )

        result
      end)
    end
  end

  # BEGIN Task16 remaining native composition adapters
  # SYNTHETIC fault placement, genuine SQL COMMIT failure: poison the existing
  # deferred FK inside the real callback, then observe and re-raise Postgrex's
  # error outside ScopedRepo. No successful COMMIT is relabeled as a failure.
  defmodule CompositionCommitFailure do
    alias Singularity.Runtime.KnowledgeExportCustodyLiveTest, as: Owner
    alias Singularity.Runtime.KnowledgeExportCustodyLiveTest.CompositionScoped

    def transact(context, repo, scope, callback),
      do: transact(context, repo, scope, [], callback)

    def transact(context, repo, scope, options, callback) do
      CompositionScoped.transact(context, repo, scope, options, fn scoped ->
        result = callback.(scoped)

        point =
          case result do
            {:ok, %{capture_id: _}} -> :capture
            {:after_commit, fun} when is_function(fun, 0) -> :prepared
            _ -> :other
          end

        if point == context.fail_commit do
          Owner.composition_commit_failure_barrier(context, scoped, point)

          %{num_rows: 1} =
            Singularity.Storage.SafeSQL.query!(
              scoped,
              "UPDATE content.resources SET current_version_id=$1 WHERE id=$2 AND vault_id=$3",
              [
                Ecto.UUID.dump!(Ecto.UUID.generate()),
                Ecto.UUID.dump!(context.document),
                Ecto.UUID.dump!(scope.vault_id)
              ]
            )

          send(context.parent, {:composition, context.token, :deferred_fk_armed, self(), point})
        end

        result
      end)
    rescue
      error in Postgrex.Error ->
        send(
          context.parent,
          {:composition, context.token, :actual_commit_failure, self(), context.fail_commit,
           error.postgres.code, error.postgres.pg_code, repo.in_transaction?()}
        )

        reraise error, __STACKTRACE__
    end
  end

  # BEGIN Task16 outer COMMIT exception observer
  defmodule CompositionCommitLockObserver do
    def with_shared(context, repo, owner, callback) do
      Singularity.Storage.VaultLock.with_shared(repo, owner, callback)
    rescue
      error ->
        send(
          context.parent,
          {:composition, context.token, :outer_commit_exception, self(), context.fail_commit,
           error.__struct__}
        )

        reraise error, __STACKTRACE__
    end
  end

  # END Task16 outer COMMIT exception observer

  # Delegate every repository operation unchanged. The barrier is admitted only
  # after the genuine owner's Writer ledger records its completed location.
  defmodule CompositionSourceChange do
    alias Singularity.Runtime.KnowledgeExportCustodyLiveTest, as: Owner
    alias Singularity.Storage.KnowledgeExport.Repository

    def capture(_context, repo, authorize, options, spool),
      do: Repository.capture(repo, authorize, options, spool)

    def lock_asset_source(context, repo, binding, mode) do
      armed = Owner.composition_final_source_barrier(context, repo, :asset)
      result = Repository.lock_asset_source(repo, binding, mode)
      if armed, do: Owner.composition_source_result(context, :asset, result)
      result
    end

    def document_source(_context, repo, binding), do: Repository.document_source(repo, binding)

    def document_source_selector(_context, repo, version),
      do: Repository.document_source_selector(repo, version)

    def revalidate_note(context, repo, binding) do
      armed = Owner.composition_final_source_barrier(context, repo, :note)
      result = Repository.revalidate_note(repo, binding)
      if armed, do: Owner.composition_source_result(context, :note, result)
      result
    end

    def revalidate_fragment(_context, repo, binding),
      do: Repository.revalidate_fragment(repo, binding)
  end

  # END Task16 remaining native composition adapters

  # BEGIN Task16 committed transfer native adapters
  # Delegation surrounds the real transaction, not merely its callback. Error
  # returns and raised COMMIT errors never receive a successful COMMIT marker.
  defmodule TransferScoped do
    alias Singularity.Runtime.KnowledgeExportCustodyLiveTest, as: Owner

    def transact(context, repo, scope, callback),
      do: transact(context, repo, scope, [], callback)

    def transact(context, repo, scope, options, callback) do
      result =
        Singularity.Storage.ScopedRepo.transact(repo, scope, options, fn scoped ->
          result = callback.(scoped)
          Owner.transfer_arm_commit_failure(context, scoped, scope, result)
          result
        end)

      case result do
        {:after_commit_scoped, fun} when is_function(fun, 1) ->
          Owner.transfer_record(context, {:committed, :initial, self(), repo.in_transaction?()})
          leases = Agent.get(context.composition_control, &Map.keys(&1.issued))

          Owner.transfer_record(
            context,
            {:initial_leases, self(), leases, repo.in_transaction?()}
          )

          Owner.transfer_pause(context, :initial_commit)

        :ok ->
          Owner.transfer_checked_commit(context, repo)

        {:ok, _} ->
          Owner.transfer_checked_commit(context, repo)

        _ ->
          Owner.transfer_record(context, {:scope_failed, self(), repo.in_transaction?()})
      end

      result
    rescue
      error in Postgrex.Error ->
        Owner.transfer_record(
          context,
          {:commit_exception, self(), error.postgres.code, error.postgres.pg_code,
           repo.in_transaction?()}
        )

        reraise error, __STACKTRACE__
    end
  end

  defmodule TransferReader do
    alias Singularity.Runtime.KnowledgeExportCustodyLiveTest, as: Owner
    alias Singularity.Runtime.KnowledgeExportCustodyLiveTest.CompositionReader

    def read(context, lease, range) do
      Owner.transfer_record(
        context,
        {:native, :asset, self(), lease, range, Singularity.Storage.RequestRepo.in_transaction?()}
      )

      result = CompositionReader.read(context, lease, range)
      Owner.transfer_native_returned(context, result)
      result
    end

    def read_document_chunk(context, lease, ordinal) do
      Owner.transfer_record(
        context,
        {:native, :document, self(), lease, ordinal,
         Singularity.Storage.RequestRepo.in_transaction?()}
      )

      result = CompositionReader.read_document_chunk(context, lease, ordinal)
      Owner.transfer_native_returned(context, result)
      result
    end

    def authenticate_empty_document_original(context, lease) do
      Owner.transfer_record(
        context,
        {:native, :document, self(), lease, :empty,
         Singularity.Storage.RequestRepo.in_transaction?()}
      )

      result = CompositionReader.authenticate_empty_document_original(context, lease)
      Owner.transfer_native_returned(context, result)
      result
    end

    def revoke(context, lease), do: CompositionReader.revoke(context, lease)
  end

  defmodule TransferAudit do
    alias Singularity.Runtime.KnowledgeExportCustodyLiveTest, as: Owner
    alias Singularity.Runtime.KnowledgeExportCustodyLiveTest.Audit

    def append(context, repo, event) do
      Owner.transfer_assert_audit(context, event)
      first = Audit.append(context, repo, event)

      result =
        if first == :ok and Owner.transfer_fault?(context, :audit),
          do: Audit.append(context, repo, event),
          else: first

      Owner.transfer_record(
        context,
        {:audit, self(), event.audit_event_id, result == :ok, repo.in_transaction?()}
      )

      result
    end
  end

  # END Task16 committed transfer native adapters

  setup context do
    if Map.get(context, :export_ownership, false) do
      assert Code.ensure_loaded?(KeyCustodian)
      assert function_exported?(KeyCustodian, :export_lease, 2), "missing native export_lease/2"
    end

    %{}
  end

  setup context do
    control =
      if Map.get(context, :composition, false) do
        start_supervised!(
          {Agent,
           fn ->
             %{current_kind: nil, issued: %{}, clock_target: nil}
           end},
          id: make_ref()
        )
      end

    barrier_kind =
      if control,
        do: Map.put(Map.get(context, :barrier, %{}), :composition_control, control),
        else: Map.get(context, :barrier)

    fixture =
      fixture!(
        Singularity.Runtime.KnowledgeExportQualificationRoot.allocate!(context.tmp_dir),
        plaintext(Map.get(context, :plaintext, :zero)),
        barrier_kind
      )

    %{fixture: fixture, composition_control: control}
  end

  test "canonical zero Asset scope delegates original download through live custody audit and actual COMMIT",
       %{fixture: f} do
    assert f.binding["plaintext_byte_size"] == 0
    assert f.binding["format_version"] == 1
    assert f.binding["ciphertext_byte_size"] == 134
    assert File.stat!(f.path).size == 134
    assert f.binding["ciphertext_hash"] == sha(File.read!(f.path))
    assert {:ok, encoded_header} = File.read(f.path)
    assert {:ok, _header, _records, parsed} = Format.split_header(encoded_header)
    assert text(parsed.object_id) == f.source.object_id

    assert Code.ensure_loaded?(@asset_scope), "missing concrete knowledge ExportRead.AssetScope"
    assert function_exported?(@asset_scope, :with_read_request, 5)

    runtime =
      Map.put(f.runtime, :operation_scope, {@asset_scope, %{binding: f.binding, mode: :zero}})

    assert {:ok, ""} = Download.run(runtime, f.session, f.source.asset_id, :all)
    trace = events()
    assert_empty_reads(trace)
    assert Enum.any?(trace, &match?({:live_read, :identity, _, :present}, &1))
    assert Enum.any?(trace, &match?({:live_read, :material, _, 1, :ok}, &1))
    assert_completed_audit!(f, trace)
    assert_closed!(f, trace)
  end

  test "ExportRead authenticates pending zero Asset plaintext SHA rather than lookup or ciphertext hash",
       %{fixture: f} do
    assert f.binding["plaintext_sha256"] == nil
    assert {:ok, delivery} = call(:asset, f, f.binding)
    assert delivery.byte_size == 0
    assert delivery.sha256 == sha("")
    refute delivery.sha256 in [f.binding["lookup_digest"], f.binding["ciphertext_hash"]]

    assert {:ok, :no_bytes} =
             delivery.reduce.(:no_bytes, fn _, _ -> flunk("zero emitted plaintext") end)

    trace = events()
    assert_empty_reads(trace)
    assert_completed_audit!(f, trace)
    assert_closed!(f, trace)
  end

  @tag plaintext: :nonempty
  test "genuine nonempty Asset preflight and delivery use only positive bounded Ranges", %{
    fixture: f
  } do
    assert {:ok, delivery} = call(:asset, f, f.binding)
    assert delivery.sha256 == sha(f.plaintext)
    assert {:ok, {hash, size, largest}} = hash_delivery(delivery)
    assert sha_final(hash) == sha(f.plaintext)
    assert size == byte_size(f.plaintext)
    assert largest == 65_536
    trace = events()

    ranges =
      for {:live_read, :plaintext_range, object, range} <- trace,
          object == f.source.object_id,
          do: range

    assert length(ranges) >= 6

    for range <- ranges do
      assert %Range{step: 1} = range
      assert range.first >= 0 and range.last < byte_size(f.plaintext)
      assert Range.size(range) in 1..65_536
    end

    # These native positive Ranges authenticate aligned DATA records. They are
    # not a claim that Range reads authenticate the final AEAD record.
    assert Enum.any?(trace, &match?({:live_read, :object_open, _, :ok}, &1))
    assert f.binding["ciphertext_hash"] == sha(File.read!(f.path))
    assert_closed!(f, trace)
  end

  @tag plaintext: :aligned
  test "exact Document authenticates aligned records but emits at most 64KiB per reducer call", %{
    fixture: f
  } do
    captured = captured_document!(f)
    assert {:ok, delivery} = call(:document, f, captured)
    assert delivery.sha256 == sha(f.plaintext)
    assert {:ok, {hash, size, largest}} = hash_delivery(delivery)
    assert size == byte_size(f.plaintext)
    assert sha_final(hash) == sha(f.plaintext)
    assert largest == 65_536
    trace = events()
    assert Enum.any?(trace, &match?({:live_read, :document_chunk, _, 1}, &1))
    requests = for {:live_read, :lease, request, _} <- trace, do: request
    assert requests != []

    for request <- requests do
      assert request.purpose == :document_source and request.access == :request
      assert request.resource_version_id == text(f.document.resource_version_id)
      assert request.object_id == f.source.object_id and request.object_generation == 1
      assert request.session_id == f.session.session_id
      assert request.principal_authorization_epoch == f.session.principal_authorization_epoch
      assert request.vault_authorization_epoch == f.session.vault_authorization_epoch
      assert request.required_capability == "asset.read"
      refute Map.has_key?(request, :job_id)
    end

    assert_closed!(f, trace)
  end

  test "empty Document original uses actual Document-only empty authentication", %{fixture: f} do
    assert {:ok, delivery} = call(:document, f, captured_document!(f))
    assert delivery.sha256 == sha("") and delivery.byte_size == 0

    assert {:ok, :empty} =
             delivery.reduce.(:empty, fn _, _ -> flunk("empty Document emitted data") end)

    trace = events()
    assert_empty_reads(trace)
    requests = for {:live_read, :lease, request, _} <- trace, do: request
    assert requests != []
    assert Enum.all?(requests, &(&1.purpose == :document_source and &1.access == :request))
    assert_closed!(f, trace)
  end

  @tag plaintext: :nonempty
  test "exact old Document retains genuine bytes after head advance and ordinary source Asset cleanup",
       %{fixture: f} do
    captured = captured_document!(f)
    newer = advance_document!(f)
    release_source!(f)
    assert_retained_pin!(f)
    assert newer != captured.version["version_id"]
    assert {:ok, delivery} = call(:document, f, captured)
    assert {:ok, bytes} = delivery.reduce.("", fn chunk, acc -> {:ok, acc <> chunk} end)
    assert bytes == f.plaintext
    assert delivery.sha256 == sha(f.plaintext)
    trace = events()
    requests = for {:live_read, :lease, request, _} <- trace, do: request
    assert requests != []

    assert Enum.all?(
             requests,
             &(&1.resource_version_id == captured.version["version_id"] and
                 &1.object_id == f.source.object_id)
           )

    assert {:error, %Error{}} = call(:asset, f, f.binding)
    assert_closed!(f, trace ++ events())
  end

  test "deleted selected Document denies before byte delivery, never metadata-only downgrade", %{
    fixture: f
  } do
    captured = captured_document!(f)

    owner_sql("UPDATE content.resources SET deleted_at=clock_timestamp() WHERE id=$1", [
      f.document.resource_id
    ])

    assert {:error, %Error{}} = call(:document, f, captured)
    trace = events()
    refute Enum.any?(trace, &match?({:live_read, :lease, _, _}, &1))
    assert_closed!(f, trace)
  end

  for mutation <- [:association, :size, :hash, :format, :lookup, :reference, :generation] do
    test "committed #{mutation} change rejects captured Asset before original lease/read", %{
      fixture: f
    } do
      mutate_binding!(f, unquote(mutation))
      assert {:error, %Error{code: :integrity_failure}} = call(:asset, f, f.binding)
      trace = events()
      refute Enum.any?(trace, &match?({:live_read, :lease, _, _}, &1))
      refute Enum.any?(trace, &match?({:live_read, :plaintext_range, _, _}, &1))
      assert_closed!(f, trace)
    end
  end

  for field <- [:pin, :object, :size, :digest, :generation, :format] do
    test "captured Document #{field} mismatch denies its exact historical original", %{fixture: f} do
      captured = captured_document!(f) |> wrong_document(unquote(field))
      assert {:error, %Error{}} = call(:document, f, captured)
      assert_closed!(f, events())
    end
  end

  for field <- [
        "owner_scope_id",
        "classification",
        "key_domain_id",
        "domain_key_version_id",
        "domain_key_generation",
        "resource_id",
        "version_id",
        "asset_id"
      ] do
    test "captured Asset #{field} cannot replace the genuine authorized exact binding", %{
      fixture: f
    } do
      value = wrong_asset_field(unquote(field))
      assert {:error, %Error{}} = call(:asset, f, Map.put(f.binding, unquote(field), value))
      trace = events()
      refute Enum.any?(trace, &match?({:live_read, :lease, _, _}, &1))
      assert_closed!(f, trace)
    end
  end

  @tag barrier: :selection
  test "guard locks Asset association before ORIGINAL selection against a genuine nonempty replacement",
       %{fixture: f} do
    locked_zero!(f, :selection, fn writer ->
      error =
        blocked_update!(writer, f, "UPDATE content.assets SET asset_object_id=$1 WHERE id=$2", [
          dump(f.replacement.object_id),
          dump(f.source.asset_id)
        ])

      assert error.postgres.code == :lock_not_available and error.postgres.pg_code == "55P03"
    end)

    scoped_writer(f, fn repo ->
      assert %{num_rows: 1} =
               query!(repo, "UPDATE content.assets SET asset_object_id=$1 WHERE id=$2", [
                 dump(f.replacement.object_id),
                 dump(f.source.asset_id)
               ])
    end)

    assert [[replacement]] =
             owner_sql("SELECT asset_object_id::text FROM content.assets WHERE id=$1", [
               dump(f.source.asset_id)
             ]).rows

    assert replacement == f.replacement.object_id
  end

  for mutation <- [:object, :envelope, :domain_version] do
    @tag barrier: :material
    test "locks survive actual custody material loading and block native #{mutation} UPDATE", %{
      fixture: f
    } do
      {statement, parameters} = concurrent_update(f, unquote(mutation))

      locked_zero!(f, :material, fn writer ->
        error = blocked_update!(writer, f, statement, parameters)
        assert error.postgres.code == :lock_not_available and error.postgres.pg_code == "55P03"
      end)

      scoped_writer(f, fn repo -> assert %{num_rows: 1} = query!(repo, statement, parameters) end)
    end
  end

  test "a genuine second eligible active envelope denies before lease, never chooses newest", %{
    fixture: f
  } do
    add_eligible_envelope!(f)

    assert [[2]] =
             owner_sql(
               "SELECT count(*) FROM content.asset_key_envelopes e JOIN core.domain_key_versions d ON d.id=e.domain_key_version_id WHERE e.asset_object_id=$1 AND d.state='active'",
               [dump(f.source.object_id)]
             ).rows

    assert {:error, %Error{code: :integrity_failure}} = call(:asset, f, f.binding)
    trace = events()
    refute Enum.any?(trace, &match?({:live_read, :lease, _, _}, &1))
    assert_closed!(f, trace)
  end

  @tag barrier: :selection
  test "second eligible envelope INSERT is not gap-locked and native selection still rejects it",
       %{fixture: f} do
    task = Task.async(fn -> call(:asset, f, f.binding) end)

    try do
      assert_receive {:live_read, :barrier, :selection, caller, token, witness}, 5_000
      assert caller == task.pid and witness.owner == f.session.vault_id
      add_eligible_envelope!(f)
      send(caller, {:continue_export_read, token})
      assert {:error, %Error{code: :integrity_failure}} = Task.await(task, 10_000)
      trace = events()
      refute Enum.any?(trace, &match?({:live_read, :lease, _, _}, &1))
      assert_closed!(f, trace)
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  @tag plaintext: :nonempty
  test "eligible envelope inserted after preflight is rejected at delivery completion", %{
    fixture: f
  } do
    assert {:ok, delivery} = call(:asset, f, f.binding)

    result =
      delivery.reduce.(false, fn _chunk, inserted? ->
        unless inserted?, do: add_eligible_envelope!(f)
        {:ok, true}
      end)

    assert {:error, %Error{code: :integrity_failure}} = result
    assert_closed!(f, events())
  end

  test "zero Asset removed after authenticated preflight cannot complete an empty delivery", %{
    fixture: f
  } do
    assert {:ok, delivery} = call(:asset, f, f.binding)
    release_source!(f)
    assert_retained_pin!(f)

    assert {:error, %Error{}} =
             delivery.reduce.(:initial, fn _, _ -> flunk("deleted empty Asset emitted bytes") end)

    assert_closed!(f, events())
  end

  for corruption <- [:missing, :header, :final] do
    test "genuine zero #{corruption} object denies authentication and cleans leases", %{
      fixture: f
    } do
      case unquote(corruption) do
        :missing -> File.rename!(f.path, f.path <> ".missing")
        :header -> corrupt_byte!(f.path, 0)
        :final -> corrupt_byte!(f.path, 133)
      end

      assert {:error, %Error{}} = call(:asset, f, f.binding)
      assert_closed!(f, events())
    end
  end

  test "final AEAD corruption with updated real ciphertext hash still fails empty authentication",
       %{fixture: f} do
    corrupt_byte!(f.path, 133)
    ciphertext_hash = sha(File.read!(f.path))

    owner_sql("UPDATE content.asset_objects SET ciphertext_hash=$2 WHERE id=$1", [
      dump(f.source.object_id),
      Base.decode16!(ciphertext_hash, case: :lower)
    ])

    binding = Map.put(f.binding, "ciphertext_hash", ciphertext_hash)
    assert {:error, %Error{code: :integrity_failure}} = call(:asset, f, binding)
    trace = events()

    assert Enum.any?(
             trace,
             &match?({:live_read, :ciphertext_range, %Range{first: 66, last: 133, step: 1}}, &1)
           )

    assert_closed!(f, trace)
  end

  @tag plaintext: :nonempty
  test "consumer cancellation and exception revoke genuine Document delivery leases", %{
    fixture: f
  } do
    captured = captured_document!(f)

    for consumer <- [
          fn _, _ -> {:error, Error.new(:conflict)} end,
          fn _, _ -> raise "consumer cancelled" end
        ] do
      assert {:ok, delivery} = call(:document, f, captured)
      assert {:error, %Error{}} = delivery.reduce.(:initial, consumer)
      assert_closed!(f, events())
    end
  end

  @tag plaintext: :nonempty
  test "canonical Document digest disagreement with genuine authenticated original denies preflight",
       %{fixture: f} do
    # Legal source metadata is not itself proof of authenticated original bytes.
    wrong =
      KnowledgeFixtures.document!(%{
        f.source_binary
        | digest: :crypto.hash(:sha256, "not the original")
      })

    selected = %{f | document: wrong}
    captured = captured_document!(selected)
    assert captured.version["original_digest"] == sha("not the original")
    assert {:error, %Error{code: :integrity_failure}} = call(:document, selected, captured)
    trace = events()
    assert Enum.any?(trace, &match?({:live_read, :document_chunk, _, 0}, &1))
    assert_closed!(f, trace)
  end

  @tag plaintext: :nonempty
  test "nonempty authenticated record tampering fails even with the exact new ciphertext hash", %{
    fixture: f
  } do
    corrupt_byte!(f.path, 90)
    hash = sha(File.read!(f.path))

    owner_sql("UPDATE content.asset_objects SET ciphertext_hash=$2 WHERE id=$1", [
      dump(f.source.object_id),
      Base.decode16!(hash, case: :lower)
    ])

    assert {:error, %Error{code: :integrity_failure}} =
             call(:asset, f, Map.put(f.binding, "ciphertext_hash", hash))

    trace = events()
    assert Enum.any?(trace, &match?({:live_read, :plaintext_range, _, %Range{}}, &1))
    assert_closed!(f, trace)
  end

  for denial <- [:membership, :epoch, :unlock, :capability, :expiry] do
    @tag plaintext: :nonempty
    test "real #{denial} after preflight denies before the first delivered original chunk", %{
      fixture: f
    } do
      assert {:ok, delivery} = call(:document, f, captured_document!(f))
      deny!(f, unquote(denial))

      assert {:error, %Error{}} =
               delivery.reduce.(:initial, fn _, _ -> flunk("revoked original emitted bytes") end)

      assert_closed!(f, events())
    end
  end

  for denial <- [:membership, :epoch, :unlock, :capability, :expiry] do
    @tag plaintext: :nonempty
    test "real #{denial} after preflight or between delivery chunks prevents completion", %{
      fixture: f
    } do
      assert {:ok, delivery} = call(:document, f, captured_document!(f))

      assert {:error, %Error{}} =
               delivery.reduce.(0, fn chunk, size ->
                 assert byte_size(chunk) <= 65_536
                 if size == 0, do: deny!(f, unquote(denial))
                 {:ok, size + byte_size(chunk)}
               end)

      assert_closed!(f, events())
    end
  end

  test "real audit duplicate failure rolls back the successful first insert and advertises nothing",
       %{fixture: f} do
    runtime = Map.put(f.runtime, :audit, {DuplicateAudit, %{parent: self()}})

    assert {:error, %Error{code: :conflict}} =
             call(:asset, %{f | runtime: runtime}, f.binding)

    assert_receive {:live_read, :duplicate_audit, audit_id, :ok,
                    {:error, %Error{code: :conflict}}}

    assert [[0]] =
             owner_sql("SELECT count(*) FROM audit.events WHERE id=$1", [dump(audit_id)]).rows

    assert_closed!(f, events())
  end

  test "real deferred COMMIT failure follows normal original callback and rolls back its read audit",
       %{fixture: f} do
    runtime =
      Map.put(
        f.runtime,
        :scoped_repo,
        {CommitFailure, %{parent: self(), document: text(f.document.resource_id)}}
      )

    assert {:error, %Error{code: :storage_unavailable}} =
             call(:asset, %{f | runtime: runtime}, f.binding)

    assert_receive {:live_read, :commit_callback_returned, _, {:ok, ""}}
    trace = events()

    for {:live_read, :audit, _, _, event, :ok} <- trace do
      assert [[0]] =
               owner_sql("SELECT count(*) FROM audit.events WHERE id=$1", [
                 dump(event.audit_event_id)
               ]).rows
    end

    assert [[head]] =
             owner_sql("SELECT current_version_id FROM content.resources WHERE id=$1", [
               f.document.resource_id
             ]).rows

    assert head == f.document.resource_version_id
    assert_closed!(f, trace)
  end

  test "nested caller transaction cannot enter fixed zero scope or open a lease", %{fixture: f} do
    assert {:ok, :checked} =
             RequestRepo.transaction(fn ->
               assert {:error, %Error{code: :invalid}} = call(:asset, f, f.binding)
               :checked
             end)

    trace = events()
    refute Enum.any?(trace, &match?({:live_read, :lease, _, _}, &1))
    assert_closed!(f, trace)
  end

  test "captured Note and fragments do not follow newer heads tags or pending-to-ready transitions",
       %{fixture: f} do
    sealed = capture!(f)
    note = note_input(sealed, f.note)
    document = document_input(sealed, f)
    original_tags = records(sealed, :tags)
    advance_note!(f)
    complete_document!(f)
    tag!(f)
    assert records(sealed, :tags) == original_tags
    assert document.version["state"] == "pending"
    assert document.version["extracted_path"] == nil
    assert {:ok, delivery} = call(:note, f, note)
    assert {:ok, "CUT_NOTE_界"} = delivery.reduce.("", fn chunk, acc -> {:ok, acc <> chunk} end)
    assert {:ok, original} = call(:document, f, document)
    assert original.sha256 == sha(f.plaintext)

    assert {:ok, :empty} =
             original.reduce.(:empty, fn _, _ -> flunk("zero original emitted bytes") end)

    assert :ok = Spool.abort(sealed)
    assert_closed!(f, events())
  end

  for kind <- [:note, :fragment] do
    test "genuine selected #{kind} revalidates sealed text and deletion both before transfer and completion",
         %{fixture: f} do
      complete_document!(f)
      sealed = capture!(f)
      binding = text_input(sealed, f, unquote(kind))
      assert {:ok, delivery} = call(unquote(kind), f, binding)
      resource = selected_text_resource(f, unquote(kind))

      assert {:error, %Error{}} =
               delivery.reduce.(:initial, fn _, acc ->
                 owner_sql(
                   "UPDATE content.resources SET deleted_at=clock_timestamp() WHERE id=$1",
                   [resource]
                 )

                 {:ok, acc}
               end)

      assert {:error, %Error{}} = call(unquote(kind), f, binding)
      assert :ok = Spool.abort(sealed)
      assert_closed!(f, events())
    end
  end

  for kind <- [:note, :fragment] do
    test "captured #{kind} digest cannot substitute for its sealed canonical text", %{fixture: f} do
      complete_document!(f)
      sealed = capture!(f)
      binding = wrong_text_digest(text_input(sealed, f, unquote(kind)), unquote(kind))
      assert {:error, %Error{code: :integrity_failure}} = call(unquote(kind), f, binding)
      trace = events()
      refute Enum.any?(trace, &match?({:live_read, :lease, _, _}, &1))
      assert :ok = Spool.abort(sealed)
      assert_closed!(f, trace)
    end

    test "genuine #{kind} membership revocation after preflight denies text delivery without a byte lease",
         %{fixture: f} do
      complete_document!(f)
      sealed = capture!(f)
      binding = text_input(sealed, f, unquote(kind))
      assert {:ok, delivery} = call(unquote(kind), f, binding)
      deny!(f, :membership)

      assert {:error, %Error{}} =
               delivery.reduce.(:initial, fn _, _ -> flunk("revoked text emitted bytes") end)

      trace = events()
      refute Enum.any?(trace, &match?({:live_read, :lease, _, _}, &1))
      assert :ok = Spool.abort(sealed)
      assert_closed!(f, trace)
    end

    test "genuine #{kind} membership revocation during delivery denies completion", %{fixture: f} do
      complete_document!(f)
      sealed = capture!(f)
      assert {:ok, delivery} = call(unquote(kind), f, text_input(sealed, f, unquote(kind)))

      assert {:error, %Error{}} =
               delivery.reduce.(:initial, fn _, acc ->
                 deny!(f, :membership)
                 {:ok, acc}
               end)

      trace = events()
      refute Enum.any?(trace, &match?({:live_read, :lease, _, _}, &1))
      assert :ok = Spool.abort(sealed)
      assert_closed!(f, trace)
    end
  end

  test "sealed canonical text tampering fails before successful text completion with no invented lease",
       %{fixture: f} do
    sealed = capture!(f)
    note = note_input(sealed, f.note)
    # Exact owned journal only; no symlink, neighbor or ciphertext mutation.
    directory = Path.join(f.context.root, sealed.capture_id)
    journal = Path.join(directory, "payload")
    assert File.regular?(journal)
    corrupt_byte!(journal, note.text_ref.offset)
    assert {:error, %Error{code: :integrity_failure}} = call(:note, f, note)
    trace = events()
    refute Enum.any?(trace, &match?({:live_read, :lease, _, _}, &1))
    assert :ok = Spool.abort(sealed)
    assert_closed!(f, trace)
  end

  for kind <- [:asset, :document] do
    @tag export_ownership: true, plaintext: :nonempty, barrier: %{stage: :material}
    test "native export #{kind} loader returning after public five-second timeout leaves no late custody",
         %{fixture: f} do
      {f, binding} = export_source!(f, unquote(kind))
      started = System.monotonic_time(:millisecond)
      {owner, token} = export_pass!(f, unquote(kind), binding)
      assert_receive {:live_export, :barrier, :material, loader, barrier_token, object}, 5_000
      assert loader == f.custodian and object == f.source.object_id

      assert_receive {:live_export, :outcome, ^owner, ^token,
                      {:error, %Error{code: :storage_unavailable}}},
                     7_000

      assert Process.alive?(owner)
      assert System.monotonic_time(:millisecond) - started >= 5_000
      send(loader, {:continue_native_export, barrier_token})
      assert KeyCustodian.unlocked?(f.custodian, f.session.session_id)
      assert_late_export_init_closed!(f.observer.token)
      assert Process.alive?(owner)
      refute_receive {:live_export, :native_returned, ^owner, _, _}, 0
      assert_no_export_io!()
    end

    @tag export_ownership: true, plaintext: :nonempty, barrier: %{stage: :init}
    test "native export #{kind} init spanning public timeout autonomously terminates after clock release",
         %{fixture: f} do
      {f, binding} = export_source!(f, unquote(kind))
      started = System.monotonic_time(:millisecond)
      {owner, token} = export_pass!(f, unquote(kind), binding)
      assert_receive {:live_export, :barrier, :init, lease, barrier_token, object}, 5_000
      assert object == f.source.object_id
      monitor = Process.monitor(lease)

      assert_receive {:live_export, :outcome, ^owner, ^token,
                      {:error, %Error{code: :storage_unavailable}}},
                     7_000

      assert Process.alive?(owner)
      assert System.monotonic_time(:millisecond) - started >= 5_000
      send(lease, {:continue_native_export, barrier_token})
      assert_receive {:DOWN, ^monitor, :process, ^lease, _reason}, 5_000
      assert KeyCustodian.unlocked?(f.custodian, f.session.session_id)
      refute_receive {:live_export, :native_returned, ^owner, _, _}, 0
      assert_no_export_io!()
    end

    @tag export_ownership: true, plaintext: :nonempty, barrier: %{stage: :init}
    test "native export #{kind} owner death before usable init cannot leave custody after clock release",
         %{fixture: f} do
      {f, binding} = export_source!(f, unquote(kind))
      {owner, token} = export_pass!(f, unquote(kind), binding)
      assert_receive {:live_export, :barrier, :init, lease, barrier_token, object}, 5_000
      assert object == f.source.object_id
      lease_monitor = Process.monitor(lease)
      owner_monitor = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 5_000
      send(lease, {:continue_native_export, barrier_token})
      assert_receive {:DOWN, ^lease_monitor, :process, ^lease, _reason}, 5_000
      assert KeyCustodian.unlocked?(f.custodian, f.session.session_id)
      refute_receive {:live_export, :outcome, ^owner, ^token, :ok}, 0
      refute_receive {:live_export, :native_returned, ^owner, _, _}, 0
      assert_no_export_io!()
    end

    @tag export_ownership: true, plaintext: :nonempty
    test "native export #{kind} caller death after genuine API return precedes wrapper PID recording",
         %{fixture: f} do
      {f, binding} = export_source!(f, unquote(kind))
      {owner, token} = export_pass!(f, unquote(kind), binding, :returned)
      assert_receive {:live_export, :native_returned, ^owner, ^token, lease}, 5_000
      assert_receive {:live_export, :barrier, :returned, ^owner, ^token, ^lease}, 5_000
      lease_monitor = Process.monitor(lease)
      owner_monitor = Process.monitor(owner)
      trace = events()
      refute Enum.any?(trace, &match?({:live_read, :lease, _, ^lease}, &1))
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 5_000
      assert_receive {:DOWN, ^lease_monitor, :process, ^lease, _reason}, 5_000
      assert KeyCustodian.unlocked?(f.custodian, f.session.session_id)
      refute_receive {:live_export, :outcome, ^owner, ^token, :ok}, 0
      assert_no_export_io!(trace ++ events())
    end

    for cancellation <- [:owner_death, :revoke, :hard_lease_death] do
      @tag export_ownership: true, plaintext: :nonempty, barrier: %{stage: :storage}
      test "native export #{kind} #{cancellation} kills genuine blocked storage reader before successful plaintext",
           %{fixture: f} do
        {f, _binding} = export_source!(f, unquote(kind))
        {owner, token} = export_acquirer!(f, unquote(kind))
        assert_receive {:live_export, :acquired, ^owner, ^token, {:ok, lease}}, 5_000
        lease_monitor = Process.monitor(lease)
        parent = self()
        read_token = make_ref()

        reader_caller =
          spawn(fn ->
            result = export_read(lease, unquote(kind))

            send(
              parent,
              {:live_export, :read_outcome, self(), read_token, export_outcome(result)}
            )
          end)

        on_exit(fn -> stop_export_observer(reader_caller) end)
        assert_receive {:live_export, :barrier, :storage, reader, _barrier_token, nil}, 5_000
        reader_monitor = Process.monitor(reader)
        assert Process.alive?(reader)
        assert reader != reader_caller and reader != lease and reader != owner

        case unquote(cancellation) do
          :owner_death ->
            owner_monitor = Process.monitor(owner)
            Process.exit(owner, :kill)
            assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 5_000

          :revoke ->
            assert :ok = DownloadLease.revoke(lease)

          :hard_lease_death ->
            Process.exit(lease, :kill)
        end

        # The actual storage callback already read ciphertext before blocking.
        # Native cancellation must kill it; releasing it could deliver plaintext.
        assert_receive {:DOWN, ^reader_monitor, :process, ^reader, _reader_reason}, 5_000
        assert_receive {:DOWN, ^lease_monitor, :process, ^lease, _lease_reason}, 5_000

        assert_receive {:live_export, :read_outcome, ^reader_caller, ^read_token, {:error, _}},
                       5_000

        refute_receive {:live_export, :read_outcome, ^reader_caller, ^read_token, :ok}, 0
        assert KeyCustodian.unlocked?(f.custodian, f.session.session_id)
        assert {:error, %Error{code: :storage_unavailable}} = export_read(lease, unquote(kind))
      end
    end
  end

  @tag export_ownership: true, plaintext: :nonempty
  test "accepted retained Document keeps native TTL beyond acquisition deadline and independent same-session custody",
       %{fixture: f} do
    {f, _binding} = export_source!(f, :document)
    request = export_request(f, :document)
    assert {:ok, ordinary} = KeyCustodian.lease(f.custodian, request)
    ordinary_monitor = Process.monitor(ordinary)
    context = %{parent: self(), custodian: f.custodian, token: make_ref(), stage: nil}
    assert {:ok, independent} = ExportCustodian.lease(context, request)
    accepted_at = System.monotonic_time(:millisecond)
    independent_monitor = Process.monitor(independent)
    {owner, token} = export_acquirer!(f, :document)
    assert_receive {:live_export, :acquired, ^owner, ^token, {:ok, first}}, 5_000
    assert first != independent and first != ordinary and independent != ordinary
    first_monitor = Process.monitor(first)
    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 5_000
    assert_receive {:DOWN, ^first_monitor, :process, ^first, _reason}, 5_000

    boundary = make_ref()
    deadline = accepted_at + 5_001

    Process.send_after(
      self(),
      {:live_export, :acquisition_boundary, boundary},
      max(deadline - System.monotonic_time(:millisecond), 0)
    )

    assert_receive {:live_export, :acquisition_boundary, ^boundary}, 6_000
    assert System.monotonic_time(:millisecond) >= deadline
    assert KeyCustodian.unlocked?(f.custodian, f.session.session_id)
    refute_receive {:DOWN, ^ordinary_monitor, :process, ^ordinary, _}, 0
    refute_receive {:DOWN, ^independent_monitor, :process, ^independent, _}, 0
    assert {:ok, bytes} = DownloadLease.read_document_chunk(ordinary, 0)
    assert bytes == f.plaintext
    assert {:ok, bytes} = DownloadLease.read_document_chunk(independent, 0)
    assert bytes == f.plaintext
    assert :ok = DownloadLease.revoke(independent)
    assert_receive {:DOWN, ^independent_monitor, :process, ^independent, _}, 5_000
    # Ordinary revoke retains its historical inert PID; this explicit fixture
    # teardown is separate from every autonomous export-cleanup assertion above.
    assert :ok = DownloadLease.revoke(ordinary)
    assert :ok = DynamicSupervisor.terminate_child(f.supervisor, ordinary)
    assert_receive {:DOWN, ^ordinary_monitor, :process, ^ordinary, _}, 5_000
    assert File.read!(f.sentinel) == "neighbor unchanged"
  end

  # These tests enter the actual Export.run composition. The old cases above
  # remain native-primitive evidence only; they cannot satisfy these contracts.
  for kind <- [:asset, :document], point <- [:material, :init] do
    @tag composition: true,
         export_ownership: true,
         plaintext: :nonempty,
         barrier: %{stage: point, kind: kind}
    test "actual export #{kind} late #{point} issuance leaves ALL observed native custody inactive",
         %{fixture: f, composition_control: control} do
      late_composition_case!(f, control, unquote(kind), unquote(point))
    end
  end

  for kind <- [:asset, :document],
      point <- [:acquired_before_recording, :recorded_before_forwarding, :known_forwarded] do
    @tag composition: true, export_ownership: true, plaintext: :nonempty, barrier: %{kind: kind}
    test "actual export #{kind} companion hard death at #{point} closes ALL native custody and owned files",
         %{fixture: f, composition_control: control} do
      hard_death_composition_case!(f, control, unquote(kind), unquote(point))
    end
  end

  defp late_composition_case!(f, control, kind, point) do
    c = composition_fixture!(f, control)
    {requester, request_monitor} = composition_start!(c)
    token = c.token
    assert_receive {:composition, ^token, :acquiring, companion, ^kind}, 5_000
    assert_receive {:live_export, :barrier, ^point, blocked, ^token, _}, 5_000
    if point == :init, do: assert(Agent.get(control, &Map.fetch!(&1.issued, blocked)) == kind)
    owner = composition_owner!(c, companion)
    owner_monitor = Process.monitor(owner)
    companion_monitor = Process.monitor(companion)

    assert_receive {:composition, ^token, :native_error, ^companion, ^kind,
                    {:error, %Error{code: :storage_unavailable}}},
                   7_000

    assert Process.alive?(requester)
    send(blocked, {:continue_native_export, token})
    assert KeyCustodian.unlocked?(f.custodian, f.session.session_id)
    assert_receive {:composition, ^token, :result, ^requester, {:error, %Error{}}}, 7_000
    assert Process.alive?(requester)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _}, 7_000
    assert_receive {:DOWN, ^companion_monitor, :process, ^companion, _}, 7_000
    composition_assert_all_inactive!(c)
    composition_assert_roots!(c)
    refute_receive {:composition, ^token, :result, ^requester, {:ok, _}}, 0
    send(requester, :stop_native_export_observer)
    assert_receive {:DOWN, ^request_monitor, :process, ^requester, :normal}, 5_000
  end

  defp hard_death_composition_case!(f, control, kind, point) do
    c = composition_fixture!(f, control)
    stage = if point == :known_forwarded, do: nil, else: :returned

    runtime =
      Map.put(c.runtime, :custodian, {ExportCustodian, Map.put(c.observer, :stage, stage)})

    c = %{c | runtime: runtime}
    {requester, request_monitor} = composition_start!(c)
    token = c.token
    assert_receive {:composition, ^token, :acquiring, companion, ^kind}, 5_000
    owner = composition_owner!(c, companion)
    owner_monitor = Process.monitor(owner)
    companion_monitor = Process.monitor(companion)

    lease =
      case point do
        :known_forwarded ->
          assert_receive {:composition, ^token, :forwarded_read, ^owner, ^kind, lease, false},
                         5_000

          assert_receive {:composition, ^token, :read_barrier, ^owner, ^lease}, 5_000
          lease

        boundary ->
          assert_receive {:live_export, :barrier, :returned, ^companion, ^token, lease}, 5_000
          assert_receive {:live_export, :native_returned, ^companion, ^token, ^lease}, 5_000

          if boundary == :recorded_before_forwarding do
            Agent.update(control, &Map.put(&1, :clock_target, companion))
            send(companion, {:continue_native_export, token})
            # The source-order contract requires record_lease, then this real
            # deadline clock call, then admission and forwarding. No trace,
            # suspension, synthetic ACK, or native private state is used.
            assert_receive {:composition, ^token, :recorded_clock, ^companion}, 5_000
          end

          refute_receive {:composition, ^token, :forwarded_read, _, ^kind, ^lease, _}, 0
          lease
      end

    assert Process.alive?(lease)
    assert Agent.get(control, &Map.fetch!(&1.issued, lease)) == kind
    lease_monitor = Process.monitor(lease)
    Process.exit(companion, :kill)
    assert_receive {:DOWN, ^companion_monitor, :process, ^companion, :killed}, 5_000

    if point == :known_forwarded,
      do: send(owner, {:continue_composition_read, token})

    assert_receive {:DOWN, ^lease_monitor, :process, ^lease, _}, 5_000
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _}, 7_000
    # The recovery-only task must already be registered before owner exit.
    # Await it, rather than race its deletion against our owner DOWN message.
    for cleanup <- Task.Supervisor.children(c.supervisor) do
      cleanup_monitor = Process.monitor(cleanup)
      assert_receive {:DOWN, ^cleanup_monitor, :process, ^cleanup, _}, 7_000
    end

    assert_receive {:composition, ^token, :result, ^requester, {:error, %Error{}}}, 7_000
    assert KeyCustodian.unlocked?(f.custodian, f.session.session_id)
    composition_assert_all_inactive!(c)
    # No test scavenge or emergency fixture teardown counts as cleanup. The
    # survivor must arrange deletion only after the actual owner DOWN.
    composition_assert_roots!(c)
    refute_receive {:composition, ^token, :result, ^requester, {:ok, _}}, 0
    send(requester, :stop_native_export_observer)
    assert_receive {:DOWN, ^request_monitor, :process, ^requester, :normal}, 5_000
  end

  @tag composition: true, export_ownership: true, plaintext: :nonempty, barrier: %{}
  test "actual export keeps genuine Writer after requester death and real capture COMMIT precedes originals",
       %{fixture: f, composition_control: control} do
    c = composition_fixture!(f, control)
    {requester, request_monitor} = composition_start!(c)
    token = c.token
    assert_receive {:composition, ^token, :result, ^requester, {:ok, handle}}, 15_000
    owner = handle.owner
    send(requester, :stop_native_export_observer)
    assert_receive {:DOWN, ^request_monitor, :process, ^requester, :normal}, 5_000
    assert Process.alive?(owner)

    writer = Singularity.Storage.KnowledgeExport.Writer

    ledgers =
      for table <- :ets.all(),
          :ets.info(table, :owner) == owner,
          :ets.info(table, :name) == writer,
          do: table

    assert [_ledger] = ledgers
    assert_receive {:composition, ^token, :capture_before_commit, ^owner, true, []}, 0
    assert_receive {:composition, ^token, :committed, ^owner, :capture, false}, 0
    assert_receive {:composition, ^token, :committed, ^owner, :prepared, false}, 0
    assert_receive {:composition, ^token, :binary_order, ^owner, true, [^owner]}, 0
    reads = composition_read_events(token)
    assert Enum.any?(reads, &match?({:asset, _, false}, &1))
    assert Enum.any?(reads, &match?({:document, _, false}, &1))
    assert Enum.all?(reads, fn {_kind, _lease, transaction?} -> transaction? == false end)

    assert MapSet.new(Agent.get(control, &Map.values(&1.issued))) ==
             MapSet.new([:asset, :document])

    assert {:ok, page} =
             apply(Singularity.Runtime.Knowledge.Export, :entries, [
               c.runtime,
               f.session,
               handle,
               nil
             ])

    manifest = Enum.find(page.entries, &(&1["path"] == "manifest.json"))
    assert %{"byte_size" => size, "sha256" => digest} = manifest
    assert size > 0 and size <= 65_536

    assert {:ok, bytes} =
             apply(Singularity.Runtime.Knowledge.Export, :read_chunk, [
               c.runtime,
               f.session,
               handle,
               "manifest.json",
               0
             ])

    assert byte_size(bytes) == size and sha(bytes) == digest
    assert {:ok, %{"format" => "singularity.portable-knowledge"}} = JSON.decode(bytes)

    assert :ok =
             apply(Singularity.Runtime.Knowledge.Export, :close, [c.runtime, f.session, handle])

    composition_assert_all_inactive!(c)
    composition_assert_roots!(c)
  end

  # BEGIN Task16 remaining native composition tests
  for point <- [:capture, :prepared] do
    @tag composition: true, export_ownership: true, plaintext: :nonempty, barrier: %{}
    test "actual export #{point} SQL COMMIT failure advertises no handle and removes actual owned artifacts",
         %{fixture: f, composition_control: control} do
      remaining_commit_failure_case!(f, control, unquote(point))
    end
  end

  for mutation <- [:asset_binding, :note_deletion] do
    @tag composition: true, export_ownership: true, plaintext: :nonempty, barrier: %{}
    test "actual completed Writer #{mutation} at final source revalidation denies publication",
         %{fixture: f, composition_control: control} do
      remaining_source_change_case!(f, control, unquote(mutation))
    end
  end

  for victim <- [:requester, :owner] do
    @tag composition: true,
         export_ownership: true,
         plaintext: :nonempty,
         barrier: %{stage: :storage, kind: :document, ordered_resources: true}
    test "actual export #{victim} death stops an already inflight native Document storage reader",
         %{fixture: f, composition_control: control} do
      remaining_inflight_death_case!(f, control, unquote(victim))
    end
  end

  @tag composition: true, export_ownership: true, plaintext: :nonempty, barrier: %{}
  test "actual accepted companion death after requester exit cleans through replacement and preserves independent native custody",
       %{fixture: f, composition_control: control} do
    remaining_accepted_companion_loss_case!(f, control)
  end

  # END Task16 remaining native composition tests

  # BEGIN Task16 committed transfer native tests
  for kind <- [:asset, :document], plaintext <- [:zero, :nonempty, :aligned] do
    @tag composition: true, export_ownership: true, plaintext: plaintext, barrier: %{}
    if kind == :asset and plaintext == :aligned do
      @tag timeout: 180_000
    end

    test "committed transfer #{kind} #{plaintext} authenticates real originals outside SQL before bounded consumers",
         %{fixture: f, composition_control: control} do
      t = transfer_start!(f, control, unquote(kind))
      token = t.c.token
      owner = t.owner

      completion_wait =
        if unquote(kind) == :asset and unquote(plaintext) == :aligned, do: 120_000, else: 20_000

      assert_receive {:transfer_read_result, ^token, ^owner,
                      {:ok, %{byte_size: size, sha256: digest, largest: largest}}},
                     completion_wait

      assert size == byte_size(f.plaintext) and digest == sha(f.plaintext)
      assert largest == min(size, 65_536)
      transfer_finish!(t)
      transfer_assert_order!(t, unquote(kind))
      transfer_assert_audits!(t, unquote(kind), :persisted)

      trace = events()
      if size == 0, do: assert_empty_reads(trace)

      if unquote(kind) == :asset do
        for {:live_read, :plaintext_range, object, range} <- trace do
          assert object == f.source.object_id

          if size == 0,
            do: assert(range == :all),
            else: assert(match?(%Range{step: 1}, range) and Range.size(range) in 1..65_536)
        end
      end

      if unquote(kind) == :document and unquote(plaintext) == :aligned,
        do: assert(Enum.any?(trace, &match?({:live_read, :document_chunk, _, 1}, &1)))
    end
  end

  for kind <- [:asset, :document] do
    @tag composition: true, export_ownership: true, barrier: %{}
    test "committed transfer #{kind} first actual COMMIT failure retires its already issued native lease without a read",
         %{fixture: f, composition_control: control} do
      t = transfer_start!(f, control, unquote(kind), fault: :first_commit)
      transfer_expect_error!(t)
      transfer_finish!(t)
      trace = transfer_events(t.c)

      assert Enum.any?(
               trace,
               &match?({_, {:commit_armed, :initial, _, true, count}} when count > 0, &1)
             )

      assert Enum.any?(
               trace,
               &match?({_, {:commit_exception, _, :foreign_key_violation, "23503", false}}, &1)
             )

      refute Enum.any?(trace, &match?({_, {:committed, :initial, _, _}}, &1))
      refute Enum.any?(trace, &match?({_, {:native, _, _, _, _, _}}, &1))
      refute Enum.any?(trace, &match?({_, {:consumer, _, _, _}}, &1))
      assert Agent.get(control, &map_size(&1.issued)) > 0
      transfer_assert_audits!(t, unquote(kind), :absent)
    end
  end

  @tag composition: true, export_ownership: true, barrier: %{stage: :material, kind: :asset}
  test "committed zero transfer holds association object envelope and domain locks through actual native acquisition",
       %{fixture: f, composition_control: control} do
    t = transfer_start!(f, control, :asset)
    token = t.c.token
    assert_receive {:live_export, :barrier, :material, custodian, ^token, _}, 5_000
    assert custodian == f.custodian

    RequestRepo.checkout(fn ->
      for mutation <- [:association, :object, :envelope, :domain_version] do
        {statement, parameters} = transfer_update(f, mutation)
        error = blocked_update!(RequestRepo, f, statement, parameters)
        assert error.postgres.code == :lock_not_available and error.postgres.pg_code == "55P03"
      end
    end)

    send(custodian, {:continue_native_export, token})
    owner = t.owner
    assert_receive {:transfer_read_result, ^token, ^owner, {:ok, %{byte_size: 0}}}, 10_000
    transfer_finish!(t)

    # The same runtime-role writer genuinely progresses after source locks end.
    for mutation <- [:object, :envelope, :domain_version] do
      {statement, parameters} = transfer_update(f, mutation)
      assert %{num_rows: 1} = scoped_writer(f, fn repo -> query!(repo, statement, parameters) end)
    end
  end

  for mutation <- [:association, :object] do
    @tag composition: true, export_ownership: true, barrier: %{}
    test "committed zero transfer allows post-COMMIT #{mutation} mutation but never substitutes a nonempty original",
         %{fixture: f, composition_control: control} do
      t = transfer_start!(f, control, :asset, pause: :initial_commit)
      token = t.c.token
      owner = t.owner
      assert_receive {:transfer_native_barrier, ^token, :initial_commit, ^owner}, 5_000
      {statement, parameters} = transfer_update(f, unquote(mutation))
      assert %{num_rows: 1} = scoped_writer(f, fn repo -> query!(repo, statement, parameters) end)
      send(owner, {:continue_transfer_native, token})
      transfer_expect_error!(t)
      transfer_finish!(t)
      refute Enum.any?(transfer_events(t.c), &match?({_, {:consumer, _, _, _}}, &1))

      for {:live_read, :plaintext_range, object, range} <- events() do
        assert object == f.source.object_id and range == :all
      end
    end
  end

  for {kind, fault} <- [asset: :audit, asset: :post_commit, document: :post_commit] do
    @tag composition: true, export_ownership: true, plaintext: :nonempty, barrier: %{}
    test "committed transfer #{kind} #{fault} failure rolls back actual post-read audit and emits no consumer bytes",
         %{fixture: f, composition_control: control} do
      t = transfer_start!(f, control, unquote(kind), fault: unquote(fault))
      transfer_expect_error!(t)
      transfer_finish!(t)
      trace = transfer_events(t.c)
      assert Enum.any?(trace, &match?({:reduce, {:native, _, _, _, _, false}}, &1))
      refute Enum.any?(trace, &match?({:reduce, {:consumer, _, _, _}}, &1))

      if unquote(fault) == :post_commit do
        assert Enum.any?(
                 trace,
                 &match?(
                   {:reduce, {:commit_exception, _, :foreign_key_violation, "23503", false}},
                   &1
                 )
               )
      else
        assert Enum.any?(trace, &match?({:reduce, {:audit, _, _, false, true}}, &1))
      end

      transfer_assert_audits!(t, unquote(kind), :rolled_back)
    end
  end

  for kind <- [:asset, :document], mutation <- [:authority, :source] do
    @tag composition: true, export_ownership: true, plaintext: :nonempty, barrier: %{}
    test "committed transfer #{kind} fresh post-read #{mutation} denial prevents its first consumer",
         %{fixture: f, composition_control: control} do
      t = transfer_start!(f, control, unquote(kind), pause: :post_read)
      token = t.c.token
      owner = t.owner
      assert_receive {:transfer_native_barrier, ^token, :post_read, ^owner}, 15_000

      if unquote(mutation) == :authority,
        do: deny!(f, :capability),
        else: mutate_binding!(f, :hash)

      send(owner, {:continue_transfer_native, token})
      transfer_expect_error!(t)
      transfer_finish!(t)
      refute Enum.any?(transfer_events(t.c), &match?({:reduce, {:consumer, _, _, _}}, &1))
    end
  end

  @tag composition: true, export_ownership: true, plaintext: :aligned, barrier: %{}
  test "committed Document checks actual authority between native-chunk consumer pieces",
       %{fixture: f, composition_control: control} do
    t = transfer_start!(f, control, :document, fault: :piece_authority)
    transfer_expect_error!(t)
    transfer_finish!(t)

    assert [{:reduce, {:consumer, owner, 65_536, false}}] =
             Enum.filter(transfer_events(t.c), &match?({:reduce, {:consumer, _, _, _}}, &1))

    assert owner == t.owner
  end

  # END Task16 committed transfer native tests

  def composition_request_observed(%{composition_control: control} = context, request) do
    kind = if request.purpose == :download, do: :asset, else: :document
    Agent.update(control, &Map.put(&1, :current_kind, kind))
    send(context.parent, {:composition, context.token, :acquiring, self(), kind})
  end

  def composition_request_observed(_context, _request), do: :ok

  def composition_result_observed(%{composition_control: _} = context, request, result) do
    kind = if request.purpose == :download, do: :asset, else: :document

    case result do
      {:error, _} ->
        send(context.parent, {:composition, context.token, :native_error, self(), kind, result})

      _ ->
        :ok
    end
  end

  def composition_result_observed(_context, _request, _result), do: :ok

  def composition_init_observed(%{composition_control: control}, lease) do
    Agent.update(control, fn state ->
      put_in(state.issued[lease], state.current_kind)
    end)
  end

  def composition_init_observed(_context, _lease), do: :ok

  def composition_read_observed(context, kind, lease) do
    caller = self()

    committed? =
      Agent.get(context.composition_control, fn state ->
        MapSet.member?(Map.get(state, :capture_owners, MapSet.new()), caller)
      end)

    send(
      context.parent,
      {:composition, context.token, :binary_order, caller, committed?,
       composition_writer_owners(caller)}
    )

    send(
      context.parent,
      {:composition, context.token, :forwarded_read, self(), kind, lease,
       RequestRepo.in_transaction?()}
    )

    if context[:block_read_kind] == kind and
         is_nil(Process.get({__MODULE__, :composition_read, context.token})) do
      Process.put({__MODULE__, :composition_read, context.token}, true)
      send(context.parent, {:composition, context.token, :read_barrier, self(), lease})

      receive do
        {:continue_composition_read, token} when token == context.token -> :ok
      after
        15_000 -> raise "composition read barrier timed out"
      end
    end
  end

  def composition_writer_owners(owner) do
    writer = Singularity.Storage.KnowledgeExport.Writer

    for table <- :ets.all(),
        :ets.info(table, :owner) == owner,
        :ets.info(table, :name) == writer,
        do: :ets.info(table, :owner)
  end

  defp composition_fixture!(f, control) do
    complete_document!(f)
    observer = f.observer.export_observer
    supervisor = start_supervised!({Task.Supervisor, []}, id: make_ref())

    for {root, name, bytes} <- [
          {f.context.storage_root, "storage-sentinel", "storage unchanged"},
          {f.context.backup_root, "backup-sentinel", "backup unchanged"}
        ] do
      File.write!(Path.join(root, name), bytes)
    end

    context = Map.merge(observer, %{custodian: f.custodian, block_read_kind: observer[:kind]})

    clock = fn ->
      caller = self()

      armed =
        Agent.get_and_update(control, fn state ->
          if state.clock_target == caller,
            do: {true, %{state | clock_target: nil}},
            else: {false, state}
        end)

      if armed do
        send(observer.parent, {:composition, observer.token, :recorded_clock, caller})

        receive do
          {:continue_composition_clock, token} when token == observer.token -> :ok
        after
          15_000 -> raise "composition clock barrier timed out"
        end
      end

      System.monotonic_time(:millisecond)
    end

    runtime =
      f.runtime
      |> Map.put(:custodian, {ExportCustodian, context})
      |> Map.put(:authenticated_reader, {CompositionReader, context})
      |> Map.put(:scoped_repo, {CompositionScoped, context})
      |> Map.put(
        :knowledge_export,
        Map.merge(f.context, %{task_supervisor: supervisor, clock: clock})
      )

    %{
      fixture: f,
      runtime: runtime,
      supervisor: supervisor,
      observer: context,
      token: observer.token,
      control: control,
      storage_bytes: File.read!(f.path),
      backup_names: File.ls!(f.context.backup_root)
    }
  end

  defp composition_start!(c) do
    assert Code.ensure_loaded?(Singularity.Runtime.Knowledge.Export)

    assert function_exported?(Singularity.Runtime.Knowledge.Export, :run, 3),
           "missing Export.run/3"

    parent = self()

    {requester, monitor} =
      spawn_monitor(fn ->
        result =
          apply(Singularity.Runtime.Knowledge.Export, :run, [
            c.runtime,
            c.fixture.session,
            %{include_tombstones: false}
          ])

        send(parent, {:composition, c.token, :result, self(), result})
        export_observer_wait()
      end)

    on_exit(fn -> stop_export_observer(requester) end)
    {requester, monitor}
  end

  defp composition_owner!(c, companion) do
    assert [owner] = Task.Supervisor.children(c.supervisor) -- [companion]
    assert owner != companion
    owner
  end

  defp composition_assert_all_inactive!(c) do
    issued = Agent.get(c.control, & &1.issued)

    for {lease, kind} <- issued do
      monitor = Process.monitor(lease)
      assert {:error, %Error{code: :storage_unavailable}} = export_read(lease, kind)
      assert_receive {:DOWN, ^monitor, :process, ^lease, _}, 5_000
    end
  end

  defp composition_assert_roots!(c) do
    f = c.fixture
    assert Enum.sort(File.ls!(f.context.root)) == ["neighbor-sentinel"]
    assert File.read!(f.sentinel) == "neighbor unchanged"
    assert File.read!(f.path) == c.storage_bytes

    assert File.read!(Path.join(f.context.storage_root, "storage-sentinel")) ==
             "storage unchanged"

    assert Enum.sort(File.ls!(f.context.backup_root)) == Enum.sort(c.backup_names)
    assert File.read!(Path.join(f.context.backup_root, "backup-sentinel")) == "backup unchanged"
  end

  defp composition_read_events(token, acc \\ []) do
    receive do
      {:composition, ^token, :forwarded_read, _owner, kind, lease, transaction?} ->
        composition_read_events(token, [{kind, lease, transaction?} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # BEGIN Task16 remaining native composition helpers
  def composition_commit_failure_barrier(context, repo, point) do
    envelope = remaining_envelope!(context.root)
    ledgers = remaining_writer_ledgers(self())

    send(
      context.parent,
      {:composition, context.token, :commit_failure_barrier, self(), point,
       repo.in_transaction?(), ledgers, envelope}
    )

    receive do
      {:continue_commit_failure, token} when token == context.token -> :ok
    after
      15_000 -> raise "composition COMMIT barrier timed out"
    end
  end

  def composition_final_source_barrier(context, repo, point) do
    ledgers = remaining_writer_ledgers(self())

    completed =
      Enum.filter(ledgers, fn ledger ->
        :ets.lookup(ledger, :location) == [{:location, :complete}]
      end)

    if context.source_point == point and completed != [] and
         is_nil(Process.get({__MODULE__, :final_source, context.token})) do
      Process.put({__MODULE__, :final_source, context.token}, true)
      [ledger] = completed
      envelope = remaining_ledger_envelope!(ledger)

      send(
        context.parent,
        {:composition, context.token, :final_source_barrier, self(), point,
         repo.in_transaction?(), ledger, envelope}
      )

      receive do
        {:continue_final_source, token} when token == context.token -> :ok
      after
        15_000 -> raise "composition final source barrier timed out"
      end

      true
    else
      false
    end
  end

  def composition_source_result(context, point, result),
    do: send(context.parent, {:composition, context.token, :final_source_result, point, result})

  defp remaining_commit_failure_case!(f, control, point) do
    c = composition_fixture!(f, control)

    context =
      Map.merge(c.observer, %{
        root: f.context.root,
        document: text(f.document.resource_id),
        fail_commit: point
      })

    # BEGIN Task16 complete outer-lock exception boundary
    runtime =
      c.runtime
      |> Map.put(:scoped_repo, {CompositionCommitFailure, context})
      |> Map.put(:vault_lock, {CompositionCommitLockObserver, context})

    c = %{c | runtime: runtime}
    # END Task16 complete outer-lock exception boundary
    {requester, request_monitor} = composition_start!(c)
    token = c.token

    assert_receive {:composition, ^token, :commit_failure_barrier, owner, ^point, true, ledgers,
                    envelope},
                   15_000

    companion = remaining_companion!(c, owner)
    owner_monitor = Process.monitor(owner)
    companion_monitor = Process.monitor(companion)
    assert File.dir?(envelope)
    assert File.regular?(Path.join(envelope, ".ownership"))
    assert Process.alive?(owner) and Process.alive?(companion)

    case point do
      :capture ->
        assert ledgers == []
        assert Agent.get(control, & &1.issued) == %{}

      :prepared ->
        assert [ledger] = ledgers
        assert :ets.info(ledger, :owner) == owner
        assert :ets.lookup(ledger, :location) == [{:location, :complete}]
        assert remaining_ledger_envelope!(ledger) == envelope
        assert_receive {:composition, ^token, :committed, ^owner, :capture, false}, 0
        remaining_assert_both_native_kinds!(c)
    end

    send(owner, {:continue_commit_failure, token})
    assert_receive {:composition, ^token, :deferred_fk_armed, ^owner, ^point}, 5_000

    assert_receive {:composition, ^token, :actual_commit_failure, ^owner, ^point,
                    :foreign_key_violation, "23503", false},
                   5_000

    # BEGIN Task16 actual outer COMMIT module witness
    assert_receive {:composition, ^token, :outer_commit_exception, ^owner, ^point,
                    DBConnection.ConnectionError},
                   5_000

    # END Task16 actual outer COMMIT module witness

    assert_receive {:composition, ^token, :result, ^requester, result}, 7_000
    # Native063 observes the genuine FK COMMIT failure, then the outer lock
    # release's DBConnection.ConnectionError at both fault points.
    expected = :storage_unavailable
    remaining_assert_private_error!(result, expected, f)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _}, 7_000
    assert_receive {:DOWN, ^companion_monitor, :process, ^companion, _}, 7_000
    assert {:error, :enoent} = File.lstat(envelope)
    for ledger <- ledgers, do: assert(:ets.info(ledger) == :undefined)
    assert Task.Supervisor.children(c.supervisor) == []
    refute_receive {:composition, ^token, :committed, ^owner, ^point, _}, 0
    refute_receive {:composition, ^token, :result, ^requester, {:ok, _}}, 0

    if point == :capture do
      assert_receive {:composition, ^token, :capture_before_commit, ^owner, true, []}, 0
      assert composition_read_events(token) == []
      assert Agent.get(control, & &1.issued) == %{}
    end

    assert [[head]] =
             owner_sql("SELECT current_version_id FROM content.resources WHERE id=$1", [
               f.document.resource_id
             ]).rows

    assert head == f.document.resource_version_id
    composition_assert_all_inactive!(c)
    composition_assert_roots!(c)
    remaining_assert_scope_clean!()
    send(requester, :stop_native_export_observer)
    assert_receive {:DOWN, ^request_monitor, :process, ^requester, :normal}, 5_000
  end

  defp remaining_source_change_case!(f, control, mutation) do
    c = composition_fixture!(f, control)
    point = if mutation == :asset_binding, do: :asset, else: :note
    expected = if mutation == :asset_binding, do: :integrity_failure, else: :not_found
    context = Map.put(c.observer, :source_point, point)

    c = %{
      c
      | runtime:
          Map.put(c.runtime, :knowledge_export_repository, {CompositionSourceChange, context})
    }

    {requester, request_monitor} = composition_start!(c)
    token = c.token

    assert_receive {:composition, ^token, :final_source_barrier, owner, ^point, true, ledger,
                    envelope},
                   15_000

    companion = remaining_companion!(c, owner)
    owner_monitor = Process.monitor(owner)
    companion_monitor = Process.monitor(companion)
    assert :ets.info(ledger, :owner) == owner
    assert :ets.lookup(ledger, :location) == [{:location, :complete}]
    assert remaining_ledger_envelope!(ledger) == envelope
    assert Enum.any?(File.ls!(envelope), &String.ends_with?(&1, ".complete"))
    assert_receive {:composition, ^token, :committed, ^owner, :capture, false}, 0
    remaining_assert_both_native_kinds!(c)
    refute_receive {:composition, ^token, :result, ^requester, {:ok, _}}, 0

    case mutation do
      :asset_binding ->
        mutate_binding!(f, :association)

      :note_deletion ->
        assert %{num_rows: 1} =
                 owner_sql(
                   "UPDATE content.resources SET deleted_at=clock_timestamp() WHERE id=$1",
                   [
                     f.note.resource_id
                   ]
                 )
    end

    send(owner, {:continue_final_source, token})

    assert_receive {:composition, ^token, :final_source_result, ^point,
                    {:error, %Error{code: ^expected}}},
                   5_000

    assert_receive {:composition, ^token, :result, ^requester, result}, 7_000
    remaining_assert_private_error!(result, expected, f)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _}, 7_000
    assert_receive {:DOWN, ^companion_monitor, :process, ^companion, _}, 7_000
    assert :ets.info(ledger) == :undefined
    assert {:error, :enoent} = File.lstat(envelope)
    assert Task.Supervisor.children(c.supervisor) == []
    refute_receive {:composition, ^token, :committed, ^owner, :prepared, _}, 0
    refute_receive {:composition, ^token, :result, ^requester, {:ok, _}}, 0
    composition_assert_all_inactive!(c)
    composition_assert_roots!(c)
    remaining_assert_scope_clean!()
    send(requester, :stop_native_export_observer)
    assert_receive {:DOWN, ^request_monitor, :process, ^requester, :normal}, 5_000
  end

  defp remaining_inflight_death_case!(f, control, victim) do
    c = composition_fixture!(f, control)
    # Do not stop in CompositionReader's before-native-read wrapper. The
    # existing Storage.read_range barrier runs in the actual native reader,
    # after LocalFilesystemAdapter has already read the requested ciphertext.
    reader_context = Map.put(c.observer, :block_read_kind, nil)

    c = %{
      c
      | runtime: Map.put(c.runtime, :authenticated_reader, {CompositionReader, reader_context})
    }

    {requester, request_monitor} = composition_start!(c)
    token = c.token
    assert_receive {:composition, ^token, :acquiring, companion, :document}, 15_000
    owner = composition_owner!(c, companion)
    owner_monitor = Process.monitor(owner)
    companion_monitor = Process.monitor(companion)

    assert_receive {:composition, ^token, :forwarded_read, ^owner, :document, lease, false},
                   5_000

    assert_receive {:live_export, :barrier, :storage, reader, ^token, nil}, 5_000
    reader_monitor = Process.monitor(reader)
    lease_monitor = Process.monitor(lease)
    assert Process.alive?(reader) and Process.alive?(lease)
    assert reader not in [requester, owner, companion, lease, f.custodian]
    assert Agent.get(control, &Map.fetch!(&1.issued, lease)) == :document
    assert [ledger] = remaining_writer_ledgers(owner)
    assert :ets.info(ledger, :owner) == owner
    envelope = remaining_ledger_envelope!(ledger)
    assert File.dir?(envelope)
    remaining_assert_both_native_kinds!(c)
    refute_receive {:composition, ^token, :read_barrier, ^owner, _}, 0

    case victim do
      :requester ->
        Process.exit(requester, :kill)
        assert_receive {:DOWN, ^request_monitor, :process, ^requester, :killed}, 5_000

      :owner ->
        Process.exit(owner, :kill)
        assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 5_000
    end

    # Never release this actual reader: cancellation must terminate it before
    # its already-read ciphertext can produce a successful plaintext reply.
    assert_receive {:DOWN, ^reader_monitor, :process, ^reader, _}, 5_000
    assert_receive {:DOWN, ^lease_monitor, :process, ^lease, _}, 5_000

    if victim == :requester do
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _}, 7_000
    else
      assert_receive {:composition, ^token, :result, ^requester, result}, 7_000
      remaining_assert_private_error!(result, :storage_unavailable, f)
      send(requester, :stop_native_export_observer)
      assert_receive {:DOWN, ^request_monitor, :process, ^requester, :normal}, 5_000
    end

    assert_receive {:DOWN, ^companion_monitor, :process, ^companion, _}, 7_000
    assert KeyCustodian.unlocked?(f.custodian, f.session.session_id)
    composition_assert_all_inactive!(c)
    assert :ets.info(ledger) == :undefined
    assert {:error, :enoent} = File.lstat(envelope)
    assert Task.Supervisor.children(c.supervisor) == []
    refute_receive {:composition, ^token, :result, ^requester, {:ok, _}}, 0
    refute_receive {:composition, ^token, :committed, ^owner, :prepared, _}, 0
    composition_assert_roots!(c)
    remaining_assert_scope_clean!()
  end

  defp remaining_accepted_companion_loss_case!(f, control) do
    c = composition_fixture!(f, control)
    {requester, request_monitor} = composition_start!(c)
    token = c.token
    assert_receive {:composition, ^token, :result, ^requester, {:ok, handle}}, 15_000
    owner = handle.owner
    companion = remaining_companion!(c, owner)
    assert [ledger] = remaining_writer_ledgers(owner)
    envelope = remaining_ledger_envelope!(ledger)
    send(requester, :stop_native_export_observer)
    assert_receive {:DOWN, ^request_monitor, :process, ^requester, :normal}, 5_000

    {independent_requester, independent_monitor} = composition_start!(c)

    assert_receive {:composition, ^token, :result, ^independent_requester,
                    {:ok, independent_handle}},
                   15_000

    independent_owner = independent_handle.owner
    assert independent_owner != owner
    assert [independent_ledger] = remaining_writer_ledgers(independent_owner)
    independent_envelope = remaining_ledger_envelope!(independent_ledger)
    assert independent_envelope != envelope
    marker = Path.join(independent_envelope, ".ownership")
    marker_bytes = File.read!(marker)
    marker_stat = File.lstat!(marker)
    send(independent_requester, :stop_native_export_observer)
    assert_receive {:DOWN, ^independent_monitor, :process, ^independent_requester, :normal}, 5_000
    assert Process.alive?(owner) and Process.alive?(independent_owner)
    remaining_assert_both_native_kinds!(c)
    export_issued = Agent.get(control, & &1.issued)
    # Retain every observed PID. These two later ordinary requests are explicit
    # unaffected sentinels, separate from the complete export-issued inventory.
    assert {:ok, ordinary_asset} = KeyCustodian.lease(f.custodian, export_request(f, :asset))

    assert {:ok, ordinary_document} =
             KeyCustodian.lease(f.custodian, export_request(f, :document))

    ordinary_asset_monitor = Process.monitor(ordinary_asset)
    ordinary_document_monitor = Process.monitor(ordinary_document)
    remaining_trace_owner!(owner)
    owner_monitor = Process.monitor(owner)
    companion_monitor = Process.monitor(companion)
    Process.exit(companion, :kill)
    assert_receive {:DOWN, ^companion_monitor, :process, ^companion, :killed}, 5_000

    {replacement, replacement_monitor} =
      remaining_cleanup_witness!(owner, handle.operation_ref)

    assert replacement not in [owner, companion, independent_owner, requester]
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _}, 7_000
    assert_receive {:DOWN, ^replacement_monitor, :process, ^replacement, reason}, 7_000
    # :noproc means attachment followed termination; filesystem absence remains
    # mandatory and does not claim that the replacement's exit reason was seen.
    assert reason in [:normal, :noproc]
    assert :ets.info(ledger) == :undefined
    assert {:error, :enoent} = File.lstat(envelope)

    for {operation, arguments} <- [
          {:entries, [nil]},
          {:read_chunk, ["manifest.json", 0]}
        ] do
      result =
        apply(Singularity.Runtime.Knowledge.Export, operation, [
          c.runtime,
          f.session,
          handle | arguments
        ])

      remaining_assert_private_error!(result, :invalid, f)
    end

    assert Process.alive?(independent_owner)
    assert :ets.info(independent_ledger, :owner) == independent_owner
    assert File.read!(marker) == marker_bytes
    assert File.lstat!(marker).inode == marker_stat.inode

    assert Enum.sort(File.ls!(f.context.root)) ==
             Enum.sort(["neighbor-sentinel", Path.basename(independent_envelope)])

    assert {:ok, page} =
             apply(Singularity.Runtime.Knowledge.Export, :entries, [
               c.runtime,
               f.session,
               independent_handle,
               nil
             ])

    assert %{"byte_size" => size, "sha256" => digest} =
             Enum.find(page.entries, &(&1["path"] == "manifest.json"))

    assert {:ok, bytes} =
             apply(Singularity.Runtime.Knowledge.Export, :read_chunk, [
               c.runtime,
               f.session,
               independent_handle,
               "manifest.json",
               0
             ])

    assert byte_size(bytes) == size and sha(bytes) == digest
    assert {:ok, %{"format" => "singularity.portable-knowledge"}} = JSON.decode(bytes)
    assert KeyCustodian.unlocked?(f.custodian, f.session.session_id)
    refute_receive {:DOWN, ^ordinary_asset_monitor, :process, ^ordinary_asset, _}, 0
    refute_receive {:DOWN, ^ordinary_document_monitor, :process, ^ordinary_document, _}, 0
    assert {:ok, asset_bytes} = DownloadLease.read(ordinary_asset, :all)
    assert asset_bytes == f.plaintext
    assert {:ok, document_bytes} = DownloadLease.read_document_chunk(ordinary_document, 0)
    assert document_bytes == f.plaintext
    assert_receive {:DOWN, ^ordinary_asset_monitor, :process, ^ordinary_asset, _}, 5_000

    assert MapSet.new(Agent.get(control, &Map.keys(&1.issued))) ==
             MapSet.new(Map.keys(export_issued) ++ [ordinary_asset, ordinary_document])

    remaining_assert_issued_inactive!(export_issued)

    assert :ok =
             apply(Singularity.Runtime.Knowledge.Export, :close, [
               c.runtime,
               f.session,
               independent_handle
             ])

    composition_assert_roots!(c)
    # Ordinary request revoke's inert PID is historical behavior. This explicit
    # isolated-fixture teardown follows usability proof; it is never credited
    # as export cleanup, replacement cleanup, or autonomous native termination.
    assert :ok = DownloadLease.revoke(ordinary_document)
    assert {:error, :waiting_for_unlock} = DownloadLease.read_document_chunk(ordinary_document, 0)
    assert :ok = DynamicSupervisor.terminate_child(f.supervisor, ordinary_document)
    assert_receive {:DOWN, ^ordinary_document_monitor, :process, ^ordinary_document, _}, 5_000
    remaining_assert_scope_clean!()
  end

  defp remaining_writer_ledgers(owner) do
    for ledger <- :ets.all(),
        :ets.info(ledger, :owner) == owner,
        :ets.info(ledger, :name) == Singularity.Storage.KnowledgeExport.Writer,
        do: ledger
  end

  defp remaining_ledger_envelope!(ledger) do
    assert [{:binding, %{identity: %{root: envelope}}}] = :ets.lookup(ledger, :binding)
    assert File.regular?(Path.join(envelope, ".ownership"))
    envelope
  end

  defp remaining_envelope!(root) do
    assert [name] =
             Enum.filter(File.ls!(root), &String.starts_with?(&1, "knowledge-export-"))

    "knowledge-export-" <> id = name
    assert Ecto.UUID.cast(id) == {:ok, id}
    envelope = Path.join(root, name)
    assert File.regular?(Path.join(envelope, ".ownership"))
    envelope
  end

  defp remaining_companion!(c, owner) do
    assert [companion] = Task.Supervisor.children(c.supervisor) -- [owner]
    assert owner != companion
    companion
  end

  defp remaining_assert_both_native_kinds!(c) do
    issued = Agent.get(c.control, & &1.issued)
    assert map_size(issued) >= 2
    assert MapSet.new(Map.values(issued)) == MapSet.new([:asset, :document])
  end

  defp remaining_assert_issued_inactive!(issued) do
    for {lease, kind} <- issued do
      monitor = Process.monitor(lease)
      assert {:error, %Error{code: :storage_unavailable}} = export_read(lease, kind)
      assert_receive {:DOWN, ^monitor, :process, ^lease, _}, 5_000
    end
  end

  defp remaining_assert_private_error!(result, code, f) do
    assert {:error, %Error{code: ^code, message: nil, details: %{}} = error} = result
    assert error.details == %{}

    for private <- [
          f.context.root,
          f.source.object_id,
          text(f.document.resource_id),
          "CUT_NOTE_界",
          "CUT_FRAGMENT_界",
          "UPDATE content.resources",
          "23503"
        ] do
      refute String.contains?(inspect(result), private)
    end
  end

  defp remaining_assert_scope_clean! do
    for repo <- [RequestRepo, WorkerRepo] do
      repo.checkout(fn ->
        refute repo.in_transaction?()

        assert [[principal, owner]] =
                 query!(
                   repo,
                   "SELECT current_setting('singularity.principal_id',true),current_setting('singularity.vault_id',true)"
                 ).rows

        assert principal in [nil, ""] and owner in [nil, ""]
      end)
    end
  end

  defp remaining_trace_owner!(owner) do
    assert :erlang.trace(owner, true, [:receive, {:tracer, self()}]) == 1

    on_exit(fn ->
      if Process.alive?(owner), do: :erlang.trace(owner, false, [:receive])
    end)
  end

  defp remaining_cleanup_witness!(owner, operation_ref) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    remaining_collect_cleanup!(owner, operation_ref, deadline, nil, nil)
  end

  defp remaining_collect_cleanup!(owner, operation_ref, deadline, started, ready) do
    case {started, ready} do
      {{replacement, monitor}, {^operation_ref, recovery_ref, replacement}}
      when is_reference(recovery_ref) ->
        {replacement, monitor}

      _ ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {:trace, ^owner, :receive, {reply_ref, {:ok, replacement}}}
          when is_reference(reply_ref) and is_pid(replacement) ->
            monitor = Process.monitor(replacement)

            remaining_collect_cleanup!(
              owner,
              operation_ref,
              deadline,
              {replacement, monitor},
              ready
            )

          {:trace, ^owner, :receive,
           {:export_cleanup_ready, ^operation_ref, recovery_ref, replacement}}
          when is_reference(recovery_ref) and is_pid(replacement) ->
            candidate = {operation_ref, recovery_ref, replacement}
            remaining_collect_cleanup!(owner, operation_ref, deadline, started, candidate)

          {:trace, ^owner, :receive, _discarded_payload} ->
            remaining_collect_cleanup!(owner, operation_ref, deadline, started, ready)
        after
          remaining -> flunk("actual native owner cleanup start-result/ready witness missing")
        end
    end
  end

  # END Task16 remaining native composition helpers

  # BEGIN Task16 committed transfer native helpers
  def transfer_record(context, event) do
    Agent.update(context.composition_control, fn state ->
      transfer = state.transfer
      put_in(state.transfer.events, [{transfer.phase, event} | transfer.events])
    end)
  end

  def transfer_checked_commit(context, repo) do
    transfer_record(context, {:committed, :checked, self(), repo.in_transaction?()})
    Agent.update(context.composition_control, &put_in(&1.transfer.pending_native, false))
  end

  def transfer_native_returned(context, result) do
    size =
      case result do
        {:ok, bytes} when is_binary(bytes) -> byte_size(bytes)
        :ok -> 0
        _ -> :denied
      end

    transfer_record(context, {:native_returned, self(), size, RequestRepo.in_transaction?()})
    Agent.update(context.composition_control, &put_in(&1.transfer.pending_native, true))
    transfer_pause(context, :post_read)
  end

  def transfer_fault?(context, fault),
    do:
      Agent.get(
        context.composition_control,
        &(&1.transfer.phase == :reduce and &1.transfer.fault == fault)
      )

  def transfer_pause(context, point) do
    pause? =
      Agent.get_and_update(context.composition_control, fn state ->
        expected_phase = if point == :initial_commit, do: :preflight, else: :reduce
        pause? = state.transfer.pause == point and state.transfer.phase == expected_phase
        {pause?, if(pause?, do: put_in(state.transfer.pause, nil), else: state)}
      end)

    if pause? do
      send(context.parent, {:transfer_native_barrier, context.token, point, self()})

      receive do
        {:continue_transfer_native, token} when token == context.token -> :ok
      after
        15_000 -> raise "native transfer barrier timed out"
      end
    end
  end

  def transfer_arm_commit_failure(context, repo, scope, result) do
    kind =
      case result do
        {:after_commit_scoped, fun} when is_function(fun, 1) -> :initial
        :ok -> :checked
        {:ok, _} -> :checked
        _ -> :failed
      end

    armed? =
      Agent.get_and_update(context.composition_control, fn state ->
        transfer = state.transfer

        armed? =
          (transfer.fault == :first_commit and kind == :initial) or
            (transfer.phase == :reduce and transfer.fault == :post_commit and
               kind == :checked and transfer.pending_native)

        {armed?, if(armed?, do: put_in(state.transfer.fault, nil), else: state)}
      end)

    if armed? do
      count = Agent.get(context.composition_control, &map_size(&1.issued))
      transfer_record(context, {:commit_armed, kind, self(), repo.in_transaction?(), count})

      assert %{num_rows: 1} =
               query!(
                 repo,
                 "UPDATE content.resources SET current_version_id=$1 WHERE id=$2 AND vault_id=$3",
                 [
                   Ecto.UUID.dump!(Ecto.UUID.generate()),
                   dump(context.document),
                   dump(scope.vault_id)
                 ]
               )
    end
  end

  def transfer_assert_audit(context, event) do
    assert event.action == "asset.downloaded" and event.result == :completed
    assert event.classification == :private and event.target_type == "asset"
    assert event.target_id == context.asset and event.metadata == %{}
    assert Ecto.UUID.cast(event.correlation_id) == {:ok, event.correlation_id}
  end

  defp transfer_document_attrs(
         %{resource_id: asset_id},
         %{stage: :storage, kind: :document, ordered_resources: true}
       ) do
    <<prefix::binary-size(6), 4::4, suffix::bitstring>> = asset_id
    document_id = <<prefix::binary, 5::4, suffix::bitstring>>
    assert asset_id < document_id and asset_id != document_id
    assert text(asset_id) < text(document_id)
    %{resource_id: document_id}
  end

  defp transfer_document_attrs(_source, _barrier), do: %{}

  defp transfer_start!(f, control, kind, options \\ []) do
    function = if kind == :asset, do: :asset_for_export, else: :document_for_export
    assert Code.ensure_loaded?(@read)
    assert function_exported?(@read, function, 3), "missing fixed committed-transfer entrypoint"
    c = composition_fixture!(f, control)

    captured =
      if kind == :asset do
        f.binding
      else
        sealed = capture!(f)
        captured = document_input(sealed, f)
        assert :ok = Spool.abort(sealed)
        captured
      end

    Agent.update(
      control,
      &Map.put(&1, :transfer, %{
        events: [],
        phase: :preflight,
        pending_native: false,
        fault: options[:fault],
        pause: options[:pause]
      })
    )

    context =
      Map.merge(c.observer, %{
        document: text(f.document.resource_id),
        asset: f.source.asset_id,
        block_read_kind: nil
      })

    runtime =
      c.runtime
      |> Map.put(:scoped_repo, {TransferScoped, context})
      |> Map.put(:authenticated_reader, {TransferReader, context})
      |> Map.put(:audit, {TransferAudit, context})

    c = %{c | runtime: runtime}
    parent = self()
    token = c.token

    {requester, request_monitor} =
      spawn_monitor(fn ->
        # Deliberately discard successful read output with a fixed error: these
        # cases qualify real read/lease/COMMIT composition, not public handles.
        result =
          apply(Singularity.Runtime.Knowledge.ExportArtifact, :generate, [
            runtime,
            f.session,
            fn owned_runtime, operation ->
              send(
                parent,
                {:transfer_native_owner, token, self(), operation.companion, operation.path}
              )

              receive do
                {:continue_transfer_work, ^token} -> :ok
              after
                15_000 -> raise "native transfer owner admission timed out"
              end

              result =
                with {:ok, descriptor} <-
                       apply(@read, function, [owned_runtime, f.session, captured]) do
                  assert descriptor.byte_size == byte_size(f.plaintext)
                  assert descriptor.sha256 == sha(f.plaintext)
                  Agent.update(control, &put_in(&1.transfer.phase, :reduce))

                  descriptor.reduce.({:crypto.hash_init(:sha256), 0, 0}, fn bytes,
                                                                            {hash, size, largest} ->
                    transfer_record(
                      context,
                      {:consumer, self(), byte_size(bytes), RequestRepo.in_transaction?()}
                    )

                    if transfer_fault?(context, :piece_authority) and size == 0,
                      do: deny!(f, :capability)

                    {:ok,
                     {:crypto.hash_update(hash, bytes), size + byte_size(bytes),
                      max(largest, byte_size(bytes))}}
                  end)
                end

              outcome =
                case result do
                  {:ok, {hash, size, largest}} ->
                    {:ok, %{byte_size: size, sha256: sha_final(hash), largest: largest}}

                  error ->
                    error
                end

              send(parent, {:transfer_read_result, token, self(), outcome})

              case result do
                {:ok, _} -> {:error, Error.new(:invalid)}
                error -> error
              end
            end
          ])

        send(parent, {:transfer_generated, token, self(), result})
      end)

    on_exit(fn -> stop_export_observer(requester) end)
    assert_receive {:transfer_native_owner, ^token, owner, companion, envelope}, 5_000
    owner_monitor = Process.monitor(owner)
    companion_monitor = Process.monitor(companion)
    assert File.regular?(Path.join(envelope, ".ownership"))
    send(owner, {:continue_transfer_work, token})

    %{
      c: c,
      owner: owner,
      companion: companion,
      owner_monitor: owner_monitor,
      companion_monitor: companion_monitor,
      envelope: envelope,
      requester: requester,
      request_monitor: request_monitor
    }
  end

  defp transfer_expect_error!(t) do
    token = t.c.token
    owner = t.owner

    assert_receive {:transfer_read_result, ^token, ^owner,
                    {:error, %Error{message: nil, details: details}}},
                   20_000

    assert details == %{}
  end

  defp transfer_finish!(t) do
    token = t.c.token
    requester = t.requester
    assert_receive {:transfer_generated, ^token, ^requester, {:error, %Error{}}}, 10_000

    assert_receive {:DOWN, ref, :process, owner, _}
                   when ref == t.owner_monitor and owner == t.owner,
                   7_000

    assert_receive {:DOWN, ref, :process, companion, _}
                   when ref == t.companion_monitor and companion == t.companion,
                   7_000

    assert_receive {:DOWN, ref, :process, ^requester, :normal} when ref == t.request_monitor,
                   5_000

    assert {:error, :enoent} = File.lstat(t.envelope)
    assert Task.Supervisor.children(t.c.supervisor) == []
    composition_assert_all_inactive!(t.c)
    composition_assert_roots!(t.c)
    remaining_assert_scope_clean!()
  end

  defp transfer_events(c), do: Agent.get(c.control, &Enum.reverse(&1.transfer.events))

  defp transfer_assert_order!(t, kind) do
    trace = transfer_events(t.c)
    owner = t.owner

    forwarded = composition_read_events(t.c.token)
    assert forwarded != []

    for event <- forwarded do
      assert {^kind, lease, false} = event
      assert is_pid(lease)
    end

    native_events =
      for {_, {:native, observed_kind, caller, lease, _mode, transaction?}} <- trace,
          do: {observed_kind, caller, lease, transaction?}

    assert length(native_events) == length(forwarded)
    for event <- native_events, do: assert({^kind, ^owner, _lease, false} = event)

    for phase <- [:preflight, :reduce] do
      events = for {^phase, event} <- trace, do: event

      natives =
        for {{:native, ^kind, ^owner, _, _, false}, index} <- Enum.with_index(events), do: index

      assert natives != []

      for index <- natives do
        prior = Enum.take(events, index)
        assert Enum.any?(prior, &match?({:committed, :initial, ^owner, false}, &1))
        {:native, ^kind, ^owner, lease, _, false} = Enum.at(events, index)

        assert {:initial_leases, ^owner, leases, false} =
                 Enum.find(Enum.reverse(prior), &match?({:initial_leases, ^owner, _, false}, &1))

        assert lease in leases

        if kind == :asset do
          previous_native =
            Enum.find_index(Enum.reverse(prior), &match?({:native, _, _, _, _, _}, &1))

          initial =
            Enum.find_index(
              Enum.reverse(prior),
              &match?({:committed, :initial, ^owner, false}, &1)
            )

          assert is_nil(previous_native) or initial < previous_native
        end

        later = Enum.drop(events, index + 1)

        returned =
          Enum.find_index(
            later,
            &match?({:native_returned, ^owner, size, false} when is_integer(size), &1)
          )

        checked = Enum.find_index(later, &match?({:committed, :checked, ^owner, false}, &1))
        assert is_integer(returned) and is_integer(checked) and returned < checked
      end

      for {{:consumer, ^owner, size, false}, index} <- Enum.with_index(events) do
        assert size in 1..65_536
        prior = Enum.take(events, index)

        native =
          Enum.find_index(Enum.reverse(prior), &match?({:native, ^kind, ^owner, _, _, false}, &1))

        checked =
          Enum.find_index(Enum.reverse(prior), &match?({:committed, :checked, ^owner, false}, &1))

        assert is_integer(native) and is_integer(checked) and checked < native
      end
    end

    refute Enum.any?(trace, &match?({_, {:native, _, _, _, _, true}}, &1))
    refute Enum.any?(trace, &match?({_, {:consumer, _, _, true}}, &1))
  end

  defp transfer_assert_audits!(t, kind, expectation) do
    audits =
      for {phase, {:audit, _, id, success?, true}} <- transfer_events(t.c),
          expectation != :rolled_back or phase == :reduce,
          do: {id, success?}

    if kind == :asset and expectation != :absent, do: assert(audits != [])
    if kind == :document or expectation == :absent, do: assert(audits == [])

    for {id, success?} <- audits do
      if expectation == :persisted do
        assert success?

        assert [["asset.downloaded", "completed", "private", "asset", target, %{}]] =
                 owner_sql(
                   "SELECT operation,result,classification,target_type,target_id::text,metadata FROM audit.events WHERE id=$1",
                   [dump(id)]
                 ).rows

        assert target == t.c.fixture.source.asset_id
      else
        assert [[0]] = owner_sql("SELECT count(*) FROM audit.events WHERE id=$1", [dump(id)]).rows
      end
    end
  end

  defp transfer_update(f, :association),
    do:
      {"UPDATE content.assets SET asset_object_id=$1 WHERE id=$2",
       [dump(f.replacement.object_id), dump(f.source.asset_id)]}

  defp transfer_update(f, mutation), do: concurrent_update(f, mutation)
  # END Task16 committed transfer native helpers

  def export_barrier(context, stage, identity) do
    if context[:stage] == stage and
         composition_barrier_kind?(context) and
         is_nil(Process.get({__MODULE__, :native_export, context.token, stage})) do
      Process.put({__MODULE__, :native_export, context.token, stage}, true)
      send(context.parent, {:live_export, :barrier, stage, self(), context.token, identity})

      receive do
        {:continue_native_export, token} when token == context.token -> :ok
      after
        15_000 -> raise "native export observer barrier timed out"
      end
    end
  end

  defp composition_barrier_kind?(%{composition_control: control, kind: kind}),
    do: Agent.get(control, & &1.current_kind) == kind

  defp composition_barrier_kind?(_context), do: true

  defp export_source!(f, :asset), do: {f, f.binding}

  defp export_source!(f, :document) do
    binding = captured_document!(f)
    release_source!(f)
    assert_retained_pin!(f)
    {f, binding}
  end

  defp export_pass!(f, kind, binding, stage \\ nil) do
    parent = self()
    token = make_ref()

    owner =
      spawn(fn ->
        context = %{parent: parent, custodian: f.custodian, token: token, stage: stage}
        runtime = Map.put(f.runtime, :custodian, {ExportCustodian, context})
        result = call(kind, %{f | runtime: runtime}, binding)
        send(parent, {:live_export, :outcome, self(), token, export_outcome(result)})
        export_observer_wait()
      end)

    on_exit(fn -> stop_export_observer(owner) end)
    {owner, token}
  end

  defp export_acquirer!(f, kind) do
    parent = self()
    token = make_ref()

    owner =
      spawn(fn ->
        context = %{parent: parent, custodian: f.custodian, token: token, stage: nil}
        result = ExportCustodian.lease(context, export_request(f, kind))
        send(parent, {:live_export, :acquired, self(), token, result})
        export_observer_wait()
      end)

    on_exit(fn -> stop_export_observer(owner) end)
    {owner, token}
  end

  defp export_request(f, kind) do
    request = %{
      session_id: f.session.session_id,
      principal_id: f.session.principal_id,
      vault_id: f.session.vault_id,
      required_capability: "asset.read",
      principal_authorization_epoch: f.session.principal_authorization_epoch,
      vault_authorization_epoch: f.session.vault_authorization_epoch,
      object_id: f.source.object_id,
      object_generation: 1
    }

    case kind do
      :asset ->
        Map.merge(request, %{purpose: :download, job_id: f.source.asset_id})

      :document ->
        Map.merge(request, %{
          purpose: :document_source,
          access: :request,
          resource_version_id: text(f.document.resource_version_id)
        })
    end
  end

  defp export_read(lease, :asset), do: DownloadLease.read(lease, :all)
  defp export_read(lease, :document), do: DownloadLease.read_document_chunk(lease, 0)
  defp export_outcome({:ok, _}), do: :ok
  defp export_outcome({:error, _} = error), do: error

  defp export_observer_wait do
    receive do
      :stop_native_export_observer -> :ok
    after
      30_000 -> :ok
    end
  end

  defp stop_export_observer(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    after
      5_000 -> raise "native export observer did not stop"
    end
  end

  defp assert_no_export_io!(trace \\ events()) do
    refute Enum.any?(trace, &match?({:live_read, :plaintext_range, _, _}, &1))
    refute Enum.any?(trace, &match?({:live_read, :document_chunk, _, _}, &1))
    refute Enum.any?(trace, &match?({:live_read, :ciphertext_range, _}, &1))
  end

  defp assert_late_export_init_closed!(token) do
    receive do
      {:live_export, :init_observed, lease, ^token, _object} ->
        monitor = Process.monitor(lease)
        assert_receive {:DOWN, ^monitor, :process, ^lease, _reason}, 5_000
        assert_late_export_init_closed!(token)
    after
      0 -> :ok
    end
  end

  # Public only to the nested delegates in this owning test module.
  def connection_witness(repo) do
    [[backend, transaction, principal, owner]] =
      query!(
        repo,
        "SELECT pg_backend_pid(),pg_current_xact_id()::text,current_setting('singularity.principal_id',true),current_setting('singularity.vault_id',true)"
      ).rows

    %{
      backend: backend,
      transaction: transaction,
      principal: principal,
      owner: owner,
      active?: repo.in_transaction?()
    }
  end

  def barrier(context, kind, repo) do
    if context[:barrier] == kind and is_nil(Process.get({__MODULE__, context.token, kind})) do
      Process.put({__MODULE__, context.token, kind}, true)
      witness = if repo, do: connection_witness(repo), else: :native_material_entry
      send(context.parent, {:live_read, :barrier, kind, self(), context.token, witness})

      receive do
        {:continue_export_read, token} when token == context.token -> :ok
      after
        5_000 -> raise "export read barrier timed out"
      end
    end
  end

  defp fixture!(tmp_dir, bytes, barrier_kind) do
    %{one: source} = Fixtures.two_vaults!()
    source_text = Map.new(source, fn {key, value} -> {key, text(value)} end)
    ids = Map.new([:domain, :domain_version, :vault_version], &{&1, Ecto.UUID.generate()})
    keys = ObjectIdentity.generate_hierarchy()
    token = :crypto.strong_rand_bytes(32)

    for name <- ["storage", "export", "backup"] do
      File.mkdir!(Path.join(tmp_dir, name))
      File.chmod!(Path.join(tmp_dir, name), 0o700)
    end

    root = Path.join(tmp_dir, "storage")
    observer = %{parent: self(), barrier: barrier_kind, token: make_ref()}

    observer =
      if is_map(barrier_kind) do
        %{observer | barrier: nil}
        |> Map.put(
          :export_observer,
          Map.merge(barrier_kind, Map.take(observer, [:parent, :token]))
        )
      else
        observer
      end

    primary = encrypted_object!(root, source_text.vault_id, ids, keys, bytes)

    replacement =
      encrypted_object!(root, source_text.vault_id, ids, keys, "genuine nonempty replacement")

    assert {:ok, wrapped_domain} =
             KeyWrapper.wrap(keys.vault_key, keys.domain_key, %{
               purpose: :domain_key,
               generation: 1,
               aad: source_text.vault_id <> ":" <> ids.domain
             })

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE core.vaults SET locked=false WHERE id=$1", [source.vault_id])

      query!(MigrationRepo, "UPDATE identity.sessions SET token_digest=$2 WHERE id=$1", [
        source.session_id,
        :crypto.hash(:sha256, token)
      ])

      for capability <- ["asset.read", "note.read"] do
        query!(
          MigrationRepo,
          "INSERT INTO core.capabilities(id,name) VALUES($1,$2) ON CONFLICT(name) DO NOTHING",
          [KnowledgeFixtures.uuid(), capability]
        )

        query!(
          MigrationRepo,
          "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name=$3 ON CONFLICT DO NOTHING",
          [source.principal_id, source.vault_id, capability]
        )
      end

      query!(
        MigrationRepo,
        "INSERT INTO core.vault_key_versions(id,vault_id,generation,state,algorithm,activated_at) VALUES($1,$2,1,'active','aes_256_gcm',clock_timestamp())",
        [dump(ids.vault_version), source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.key_domains(id,vault_id,classification,kind,state) VALUES($1,$2,'private','content','active')",
        [dump(ids.domain), source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.domain_key_versions(id,vault_id,key_domain_id,vault_key_version_id,generation,state,algorithm,wrapped_key) VALUES($1,$2,$3,$4,1,'active','aes_256_gcm',$5)",
        [
          dump(ids.domain_version),
          source.vault_id,
          dump(ids.domain),
          dump(ids.vault_version),
          wrapped_domain.encoded
        ]
      )

      for object <- [primary, replacement], do: insert_object!(source, ids, object)

      query!(
        MigrationRepo,
        "UPDATE content.assets SET state='available',asset_object_id=$1 WHERE id=$2",
        [dump(primary.object_id), source.asset_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.resource_assets(resource_version_id,asset_id,vault_id,classification) VALUES($1,$2,$3,'private')",
        [source.resource_version_id, source.asset_id, source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.asset_metadata(id,asset_id,resource_version_id,vault_id,classification,projection_version,original_filename,declared_media_type,detected_media_type,plaintext_byte_size,extraction_state,completed_at) VALUES($1,$2,$3,$4,'private',1,'original.bin','application/octet-stream','application/octet-stream',$5,'completed',clock_timestamp())",
        [
          KnowledgeFixtures.uuid(),
          source.asset_id,
          source.resource_version_id,
          source.vault_id,
          byte_size(bytes)
        ]
      )
    end)

    source_binary =
      Map.merge(source, %{
        object_id: dump(primary.object_id),
        digest: :crypto.hash(:sha256, bytes),
        byte_size: byte_size(bytes)
      })

    document =
      KnowledgeFixtures.document!(source_binary, transfer_document_attrs(source, barrier_kind))

    note = note!(source_binary)
    supervisor = start_supervised!({KeyLeaseSupervisor, name: nil}, id: make_ref())

    custody_context =
      Map.merge(observer, %{
        repo: WorkerRepo,
        repository_adapter: Singularity.Storage.Postgres.CustodyRepository,
        scope: ScopedRepo,
        key_wrapper: KeyWrapper,
        storage: %{adapter: Storage, context: %{root: root, parent: self()}}
      })

    custody_context =
      if Map.has_key?(observer, :export_observer) do
        put_in(custody_context.storage.context[:export_observer], observer.export_observer)
      else
        custody_context
      end

    custodian =
      start_supervised!(
        {KeyCustodian,
         %{
           authorization: Reader,
           clock: Reader,
           context: custody_context,
           idle_lock: fn _ -> :ok end,
           key_reader: Reader,
           object_key_loader: Reader,
           lease_supervisor: supervisor
         }},
        id: make_ref()
      )

    resolver = %{
      pre_auth: PreAuth,
      pre_auth_context: PreAuthRepo,
      custodian: KeyCustodian,
      custodian_context: custodian
    }

    assert {:ok, resolved} = ResolveSession.run(resolver, token)

    assert {:ok, pending} =
             KeyCustodian.prepare_unlock(
               custodian,
               Map.merge(
                 Map.take(source_text, [:account_id, :principal_id, :vault_id, :session_id]),
                 %{
                   expires_at: resolved.expires_at,
                   principal_authorization_epoch: resolved.principal_authorization_epoch,
                   vault_authorization_epoch: resolved.vault_authorization_epoch,
                   vault_key: keys.vault_key,
                   domain_key: keys.domain_key,
                   domain_dedup_key: keys.domain_dedup_key,
                   key_domain_id: ids.domain,
                   domain_key_version_id: ids.domain_version,
                   domain_key_generation: 1,
                   domain_classification: :private
                 }
               )
             )

    assert :ok = KeyCustodian.activate_unlock(custodian, pending)
    assert {:ok, session} = ResolveSession.run(resolver, token)
    assert session.unlocked?

    assert {:ok, authorization} =
             AuthorizationDependencies.new(%{
               store: {Identity, %{parent: self()}},
               custodian: {KeyCustodian, custodian}
             })

    runtime = %{
      request_repo: RequestRepo,
      authorization_lock: AuthorizationLock,
      vault_lock: VaultLock,
      scoped_repo: ScopedRepo,
      operation_scope: OperationScope,
      authorizer: Authorize,
      authorization: authorization,
      audit: {Audit, %{parent: self()}},
      assets: {Assets, observer},
      custodian: {Custodian, %{parent: self(), custodian: custodian}},
      authenticated_reader: DownloadLease,
      knowledge_export_repository: Repository
    }

    source_text =
      Map.merge(source_text, %{
        object_id: primary.object_id,
        digest: source_binary.digest,
        byte_size: byte_size(bytes)
      })

    binding = %{
      "kind" => "asset",
      "resource_id" => source_text.resource_id,
      "version_id" => source_text.resource_version_id,
      "asset_id" => source_text.asset_id,
      "object_id" => primary.object_id,
      "owner_scope_id" => source_text.vault_id,
      "classification" => "private",
      "key_domain_id" => ids.domain,
      "domain_key_version_id" => ids.domain_version,
      "domain_key_generation" => 1,
      "object_generation" => 1,
      "lookup_digest" => hex(primary.lookup_digest),
      "ciphertext_hash" => hex(primary.ciphertext_hash),
      "plaintext_byte_size" => byte_size(bytes),
      "ciphertext_byte_size" => primary.ciphertext_byte_size,
      "storage_ref" => primary.object_id,
      "format_version" => 1,
      "plaintext_sha256" => nil
    }

    context = %{
      root: Path.join(tmp_dir, "export"),
      storage_root: root,
      backup_root: Path.join(tmp_dir, "backup")
    }

    sentinel = Path.join(context.root, "neighbor-sentinel")
    File.write!(sentinel, "neighbor unchanged")

    f = %{
      source: source_text,
      source_binary: source_binary,
      document: document,
      note: note,
      runtime: runtime,
      session: session,
      custodian: custodian,
      supervisor: supervisor,
      binding: binding,
      plaintext: bytes,
      path: primary.path,
      replacement: replacement,
      ids: ids,
      keys: keys,
      observer: observer,
      context: context,
      sentinel: sentinel
    }

    assert_native_authority!(f)
    events()
    f
  end

  defp encrypted_object!(root, owner, ids, keys, bytes) do
    object_id = Ecto.UUID.generate()
    dek = :crypto.strong_rand_bytes(32)

    assert {:ok, ciphertext} =
             ChunkedAEAD.encode(%{
               key: dek,
               plaintext: bytes,
               chunk_index: 0,
               format_version: Format.format_version(),
               algorithm: Format.algorithm(),
               chunk_size: Format.chunk_size(),
               vault_id: owner,
               encryption_domain_id: ids.domain,
               object_id: object_id
             })

    assert {:ok, protected} =
             ObjectIdentity.protect(
               keys.domain_dedup_key,
               :crypto.hash(:sha256, bytes),
               ciphertext
             )

    storage = %{
      root: root,
      vault_namespace: owner,
      domain_namespace: ids.domain,
      lookup_digest: hex(protected.lookup_digest)
    }

    assert {:ok, stage} = LocalFilesystemAdapter.stage(storage, %{})
    assert :ok = LocalFilesystemAdapter.append_encrypted_chunk(storage, stage, ciphertext)
    assert {:ok, %{sealed?: true}} = LocalFilesystemAdapter.seal_stage(storage, stage, %{})

    assert {:ok, %ObjectRef{object_id: ^object_id}} =
             LocalFilesystemAdapter.finalize(storage, stage, %ObjectRef{object_id: object_id})

    assert {:ok, path} = PathGuard.object_path(root, owner, ids.domain, storage.lookup_digest)

    assert {:ok, wrapper} =
             KeyWrapper.wrap(keys.domain_key, dek, %{
               purpose: :object_dek,
               generation: 1,
               aad: "object:" <> object_id
             })

    %{
      object_id: object_id,
      path: path,
      lookup_digest: protected.lookup_digest,
      ciphertext_hash: protected.ciphertext_hash,
      plaintext_byte_size: byte_size(bytes),
      ciphertext_byte_size: byte_size(ciphertext),
      wrapped_dek: wrapper.encoded,
      envelope_id: Ecto.UUID.generate()
    }
  end

  defp insert_object!(source, ids, object) do
    query!(
      MigrationRepo,
      "INSERT INTO content.asset_objects(id,vault_id,key_domain_id,classification,lookup_digest,ciphertext_hash,plaintext_byte_size,ciphertext_byte_size,storage_ref,format_version,lifecycle) VALUES($1,$2,$3,'private',$4,$5,$6,$7,$8,1,'available')",
      [
        dump(object.object_id),
        source.vault_id,
        dump(ids.domain),
        object.lookup_digest,
        object.ciphertext_hash,
        object.plaintext_byte_size,
        object.ciphertext_byte_size,
        object.object_id
      ]
    )

    query!(
      MigrationRepo,
      "INSERT INTO content.asset_key_envelopes(id,vault_id,asset_object_id,domain_key_version_id,key_domain_id,classification,algorithm,key_generation,wrapped_dek) VALUES($1,$2,$3,$4,$5,'private','aes_256_gcm',1,$6)",
      [
        dump(object.envelope_id),
        source.vault_id,
        dump(object.object_id),
        dump(ids.domain_version),
        dump(ids.domain),
        object.wrapped_dek
      ]
    )
  end

  defp note!(source) do
    row =
      KnowledgeFixtures.note!(source, fn note ->
        query!(
          MigrationRepo,
          "UPDATE content.note_versions SET markdown='CUT_NOTE_界' WHERE resource_version_id=$1",
          [note.resource_version_id]
        )

        query!(
          MigrationRepo,
          "INSERT INTO content.note_attachments(note_resource_version_id,id,note_resource_id,vault_id,classification,target_resource_id,target_resource_version_id,target_kind,ordinal,role,inserted_at) VALUES($1,$2,$3,$4,'private',$5,$6,'asset',0,'source',clock_timestamp())",
          [
            note.resource_version_id,
            KnowledgeFixtures.uuid(),
            note.resource_id,
            source.vault_id,
            source.resource_id,
            source.resource_version_id
          ]
        )
      end)

    row
  end

  defp assert_native_authority!(f) do
    assert :ok =
             OperationScope.with_read_request(f.runtime, f.session, requirement(f), fn repo ->
               assert :ok =
                        Authorize.check(f.runtime.authorization, repo, f.session, requirement(f))

               assert {:ok, live} =
                        IdentityRepository.load_live_session(repo, f.session.session_id)

               assert live.principal_id == f.session.principal_id and
                        live.vault_id == f.session.vault_id

               assert {:ok, object} = AssetRepository.authorized_object(repo, f.source.asset_id)
               assert object.object_id == f.source.object_id and object.object_generation == 1
               :ok
             end)
  end

  defp capture!(f) do
    assert {:ok, spool} = Spool.open(f.context)
    assert {:ok, sealed} = apply(@snapshot, :capture, [f.runtime, f.session, %{}, spool])
    refute RequestRepo.in_transaction?()
    on_exit(fn -> Spool.abort(spool) end)
    sealed
  end

  defp captured_document!(f), do: document_input(capture!(f), f)

  defp document_input(sealed, f) do
    version =
      Enum.find(
        records(sealed, :versions),
        &(&1["version_id"] == text(f.document.resource_version_id))
      )

    assert version["availability"] == "included"

    ref =
      Map.fetch!(
        sealed.binary_refs,
        {:binary_binding, :asset, f.source.resource_id, f.source.resource_version_id}
      )

    assert {:ok, bytes} = Spool.read_chunk(sealed, ref, 0)
    source = JSON.decode!(bytes)
    assert source == f.binding
    %{version: version, source: source}
  end

  defp note_input(sealed, row) do
    version =
      Enum.find(records(sealed, :versions), &(&1["version_id"] == text(row.resource_version_id)))

    ref =
      Map.fetch!(
        sealed.text_refs,
        {:note_markdown, text(row.resource_id), text(row.resource_version_id)}
      )

    %{capture: sealed, version: version, text_ref: ref}
  end

  defp text_input(sealed, f, :note), do: note_input(sealed, f.note)

  defp text_input(sealed, f, :fragment) do
    [fragment] =
      Enum.filter(
        records(sealed, :fragments),
        &(&1["version_id"] == text(f.document.resource_version_id))
      )

    selector =
      {:fragment_text, fragment["resource_id"], fragment["version_id"], fragment["ordinal"],
       fragment["id"]}

    %{capture: sealed, fragment: fragment, text_ref: Map.fetch!(sealed.text_refs, selector)}
  end

  defp records(sealed, collection),
    do:
      page_records(
        sealed,
        %{capture_id: sealed.capture_id, collection: collection, after: nil},
        []
      )

  defp page_records(sealed, cursor, acc) do
    assert {:ok, %{records: rows, next_cursor: next}} = Repository.next_page(sealed, cursor, 500)
    if next, do: page_records(sealed, next, acc ++ rows), else: acc ++ rows
  end

  defp hash_delivery(delivery),
    do:
      delivery.reduce.({:crypto.hash_init(:sha256), 0, 0}, fn chunk, {hash, size, largest} ->
        assert byte_size(chunk) in 1..65_536

        {:ok,
         {:crypto.hash_update(hash, chunk), size + byte_size(chunk),
          max(largest, byte_size(chunk))}}
      end)

  defp assert_empty_reads(trace) do
    ranges = for {:live_read, :ciphertext_range, range} <- trace, do: range
    assert ranges != []
    assert Enum.all?(ranges, &(&1 in [0..65, 66..133]))
    assert 0..65 in ranges and 66..133 in ranges
    refute Enum.any?(trace, &match?({:live_read, :document_chunk, _, _}, &1))
  end

  defp assert_completed_audit!(f, trace) do
    audits =
      for {:live_read, :audit, caller, witness, event, result} <- trace,
          event.action == "asset.downloaded",
          do: {caller, witness, event, result}

    assert audits != []

    for {caller, witness, event, result} <- audits do
      assert caller == self()
      assert witness.active? and is_integer(witness.backend) and is_binary(witness.transaction)
      assert witness.principal == f.session.principal_id and witness.owner == f.session.vault_id
      assert result == :ok and event.result == :completed and event.metadata == %{}
      assert event.target_id == f.source.asset_id

      assert [["asset.downloaded", "completed", principal, owner, %{}]] =
               owner_sql(
                 "SELECT operation,result,principal_id::text,vault_id::text,metadata FROM audit.events WHERE id=$1",
                 [dump(event.audit_event_id)]
               ).rows

      assert principal == f.session.principal_id and owner == f.session.vault_id
    end

    refute RequestRepo.in_transaction?()
  end

  defp assert_closed!(f, trace) do
    leases = for {:live_read, :lease, request, lease} <- trace, do: {request, lease}

    for {request, lease} <- leases do
      monitor = Process.monitor(lease)

      receive do
        {:DOWN, ^monitor, :process, ^lease, reason} -> assert reason in [:normal, :noproc]
      after
        0 ->
          # Native request revoke erases custody without terminating the opaque
          # process. Its unchanged public read must deny without spawning I/O.
          result =
            if request.purpose == :document_source,
              do: DownloadLease.read_document_chunk(lease, 0),
              else: DownloadLease.read(lease, 0..0)

          case result do
            {:error, :waiting_for_unlock} ->
              # Owning fixture teardown only, AFTER native revocation proof;
              # this is not a product claim that revoke terminates request PIDs.
              assert DynamicSupervisor.terminate_child(f.supervisor, lease) in [
                       :ok,
                       {:error, :not_found}
                     ]

              assert_receive {:DOWN, ^monitor, :process, ^lease, reason}, 1_000
              assert reason in [:shutdown, :normal, :noproc]

            {:error, %Error{code: :storage_unavailable}} ->
              assert_receive {:DOWN, ^monitor, :process, ^lease, reason}, 1_000
              assert reason in [:normal, :noproc]

            _ ->
              flunk("closed custody lease accepted a new read")
          end
      end
    end

    assert DynamicSupervisor.which_children(f.supervisor) == []
    probe_events = events()
    refute Enum.any?(probe_events, &match?({:live_read, :plaintext_range, _, _}, &1))
    refute Enum.any?(probe_events, &match?({:live_read, :document_chunk, _, _}, &1))

    for repo <- [RequestRepo, WorkerRepo] do
      repo.checkout(fn ->
        refute repo.in_transaction?()

        [[principal, owner]] =
          query!(
            repo,
            "SELECT current_setting('singularity.principal_id',true),current_setting('singularity.vault_id',true)"
          ).rows

        assert principal in [nil, ""] and owner in [nil, ""]
      end)
    end

    assert File.read!(f.sentinel) == "neighbor unchanged"
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(%{root: f.context.storage_root})
  end

  defp locked_zero!(f, kind, writer_callback) do
    RequestRepo.checkout(fn ->
      writer_backend = query!(RequestRepo, "SELECT pg_backend_pid()").rows |> hd() |> hd()
      task = Task.async(fn -> call(:asset, f, f.binding) end)

      try do
        assert_receive {:live_read, :barrier, ^kind, caller, token, witness}, 5_000

        if kind == :selection do
          assert caller == task.pid
          assert witness.active? and witness.backend != writer_backend

          assert witness.principal == f.session.principal_id and
                   witness.owner == f.session.vault_id
        else
          assert caller == f.custodian
          # Main original callback selected the exact object on its distinct
          # checked-out RequestRepo connection before real custody loading.
          assert_receive {:live_read, :selected, task_pid, {:ok, selected}}, 5_000
          assert task_pid == task.pid and selected.object_id == f.source.object_id

          assert_receive {:live_read, :selection_connection, ^task_pid, selected_connection},
                         5_000

          assert selected_connection.active? and selected_connection.backend != writer_backend
          assert selected_connection.principal == f.session.principal_id
          assert selected_connection.owner == f.session.vault_id
        end

        writer_callback.(RequestRepo)
        send(caller, {:continue_export_read, token})
        assert {:ok, delivery} = Task.await(task, 10_000)
        assert delivery.byte_size == 0 and delivery.sha256 == sha("")
        trace = events()
        assert_empty_reads(trace)
        assert_closed!(f, trace)
      after
        Task.shutdown(task, :brutal_kill)
      end
    end)
  end

  defp blocked_update!(repo, f, statement, parameters) do
    error =
      assert_raise Postgrex.Error, fn ->
        ScopedRepo.transact(
          repo,
          %{principal_id: f.session.principal_id, vault_id: f.session.vault_id},
          fn scoped ->
            query!(scoped, "SET LOCAL lock_timeout='250ms'")
            query!(scoped, statement, parameters)
          end
        )
      end

    repo.checkout(fn ->
      refute repo.in_transaction?()

      [[principal, owner]] =
        query!(
          repo,
          "SELECT current_setting('singularity.principal_id',true),current_setting('singularity.vault_id',true)"
        ).rows

      assert principal in [nil, ""] and owner in [nil, ""]
    end)

    error
  end

  defp scoped_writer(f, callback),
    do:
      ScopedRepo.transact(
        RequestRepo,
        %{principal_id: f.session.principal_id, vault_id: f.session.vault_id},
        callback
      )

  defp concurrent_update(f, :object),
    do:
      {"UPDATE content.asset_objects SET plaintext_byte_size=1 WHERE id=$1",
       [dump(f.source.object_id)]}

  defp concurrent_update(f, :envelope),
    do:
      {"UPDATE content.asset_key_envelopes SET key_generation=key_generation+1 WHERE asset_object_id=$1 AND domain_key_version_id=$2",
       [dump(f.source.object_id), dump(f.ids.domain_version)]}

  defp concurrent_update(f, :domain_version),
    do:
      {"UPDATE core.domain_key_versions SET state='retired' WHERE id=$1",
       [dump(f.ids.domain_version)]}

  defp mutate_binding!(f, :association),
    do:
      owner_sql("UPDATE content.assets SET asset_object_id=$2 WHERE id=$1", [
        dump(f.source.asset_id),
        dump(f.replacement.object_id)
      ])

  defp mutate_binding!(f, :size),
    do:
      owner_sql("UPDATE content.asset_objects SET plaintext_byte_size=1 WHERE id=$1", [
        dump(f.source.object_id)
      ])

  defp mutate_binding!(f, :hash),
    do:
      owner_sql("UPDATE content.asset_objects SET ciphertext_hash=$2 WHERE id=$1", [
        dump(f.source.object_id),
        :crypto.hash(:sha256, "different ciphertext")
      ])

  defp mutate_binding!(f, :format),
    do:
      owner_sql("UPDATE content.asset_objects SET format_version=2 WHERE id=$1", [
        dump(f.source.object_id)
      ])

  defp mutate_binding!(f, :lookup),
    do:
      owner_sql("UPDATE content.asset_objects SET lookup_digest=$2 WHERE id=$1", [
        dump(f.source.object_id),
        :crypto.hash(:sha256, "different lookup")
      ])

  defp mutate_binding!(f, :reference),
    do:
      owner_sql("UPDATE content.asset_objects SET storage_ref=$2 WHERE id=$1", [
        dump(f.source.object_id),
        f.replacement.object_id
      ])

  defp mutate_binding!(f, :generation),
    do:
      owner_sql(
        "UPDATE content.asset_key_envelopes SET key_generation=2 WHERE asset_object_id=$1",
        [dump(f.source.object_id)]
      )

  defp add_eligible_envelope!(f) do
    version = Ecto.UUID.generate()

    assert {:ok, wrapped} =
             KeyWrapper.wrap(f.keys.vault_key, f.keys.domain_key, %{
               purpose: :domain_key,
               generation: 2,
               aad: f.source.vault_id <> ":" <> f.ids.domain
             })

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO core.domain_key_versions(id,vault_id,key_domain_id,vault_key_version_id,generation,state,algorithm,wrapped_key) VALUES($1,$2,$3,$4,2,'active','aes_256_gcm',$5)",
        [
          dump(version),
          dump(f.source.vault_id),
          dump(f.ids.domain),
          dump(f.ids.vault_version),
          wrapped.encoded
        ]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.asset_key_envelopes(id,vault_id,asset_object_id,domain_key_version_id,key_domain_id,classification,algorithm,key_generation,wrapped_dek) SELECT $1,vault_id,asset_object_id,$2,key_domain_id,classification,algorithm,2,wrapped_dek FROM content.asset_key_envelopes WHERE asset_object_id=$3 AND domain_key_version_id=$4",
        [
          KnowledgeFixtures.uuid(),
          dump(version),
          dump(f.source.object_id),
          dump(f.ids.domain_version)
        ]
      )
    end)
  end

  defp release_source!(f) do
    Fixtures.with_owner(fn ->
      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 "UPDATE content.resource_assets SET released_at=clock_timestamp() WHERE resource_version_id=$1 AND asset_id=$2 AND released_at IS NULL",
                 [dump(f.source.resource_version_id), dump(f.source.asset_id)]
               )

      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 "UPDATE content.assets SET state='deleted',asset_object_id=NULL WHERE id=$1",
                 [dump(f.source.asset_id)]
               )

      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 "UPDATE content.resources SET deleted_at=clock_timestamp() WHERE id=$1",
                 [dump(f.source.resource_id)]
               )

      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 "INSERT INTO content.tombstones(id,vault_id,asset_id,principal_id,classification,reason) VALUES($1,$2,$3,$4,'private','user_delete')",
                 [
                   KnowledgeFixtures.uuid(),
                   dump(f.source.vault_id),
                   dump(f.source.asset_id),
                   dump(f.source.principal_id)
                 ]
               )
    end)
  end

  defp assert_retained_pin!(f) do
    [["deleted", nil, released, deleted, object, digest, size, "available"]] =
      owner_sql(
        "SELECT a.state,a.asset_object_id,ra.released_at,r.deleted_at,d.source_object_id::text,d.source_digest,d.source_byte_size,o.lifecycle FROM content.document_versions d JOIN content.assets a ON a.id=d.source_asset_id JOIN content.resource_assets ra ON ra.asset_id=a.id AND ra.resource_version_id=d.source_resource_version_id JOIN content.resources r ON r.id=d.source_resource_id JOIN content.asset_objects o ON o.id=d.source_object_id WHERE d.resource_version_id=$1",
        [f.document.resource_version_id]
      ).rows

    assert released != nil and deleted != nil

    assert object == f.source.object_id and digest == :crypto.hash(:sha256, f.plaintext) and
             size == byte_size(f.plaintext)
  end

  defp advance_document!(f) do
    version = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',1)",
        [version, f.document.resource_id, dump(f.source.vault_id)]
      )

      KnowledgeFixtures.insert_typed!(%{f.document | resource_version_id: version})

      query!(MigrationRepo, "UPDATE content.resources SET current_version_id=$2 WHERE id=$1", [
        f.document.resource_id,
        version
      ])
    end)

    text(version)
  end

  defp advance_note!(f) do
    version = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',1)",
        [version, f.note.resource_id, dump(f.source.vault_id)]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,parent_version_id) VALUES($1,$2,$3,'private','New head','NEW_HEAD_TEXT',$4,$5)",
        [
          version,
          f.note.resource_id,
          dump(f.source.vault_id),
          dump(f.source.principal_id),
          f.note.resource_version_id
        ]
      )

      query!(MigrationRepo, "UPDATE content.resources SET current_version_id=$2 WHERE id=$1", [
        f.note.resource_id,
        version
      ])
    end)
  end

  defp complete_document!(f) do
    locator = %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}

    assert {:ok, fragment} =
             DocumentFragment.new(%{
               resource_id: text(f.document.resource_id),
               resource_version_id: text(f.document.resource_version_id),
               owner_scope_id: f.source.vault_id,
               classification: :private,
               ordinal: 0,
               text: "CUT_FRAGMENT_界",
               locator: locator
             })

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
        [f.source.principal_id, f.source.vault_id]
      )

      query!(MigrationRepo, "SELECT content.claim_document_extraction($1,0,$1,'plain_text',1)", [
        f.document.resource_version_id
      ])

      query!(MigrationRepo, "SELECT content.complete_document_extraction($1,$1,1,$2,$3,'en')", [
        f.document.resource_version_id,
        [
          %{
            "id" => fragment.fragment_id,
            "ordinal" => 0,
            "text" => fragment.text,
            "digest" => hex(fragment.digest),
            "locator" => locator
          }
        ],
        fragment.digest
      ])
    end)
  end

  defp tag!(f) do
    tag = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 "INSERT INTO content.tags(id,vault_id,classification,display_value,normalized_key,created_by_principal_id,inserted_at) VALUES($1,$2,'private','After cut','after cut',$3,clock_timestamp())",
                 [tag, dump(f.source.vault_id), dump(f.source.principal_id)]
               )

      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 "INSERT INTO content.resource_tags(resource_id,tag_id,vault_id,classification,inserted_at) VALUES($1,$2,$3,'private',clock_timestamp())",
                 [f.note.resource_id, tag, dump(f.source.vault_id)]
               )
    end)
  end

  defp selected_text_resource(f, :note), do: f.note.resource_id
  defp selected_text_resource(f, :fragment), do: f.document.resource_id

  defp wrong_text_digest(binding, :note),
    do: put_in(binding.version["body_digest"], sha("wrong canonical text"))

  defp wrong_text_digest(binding, :fragment),
    do: put_in(binding.fragment["digest"], sha("wrong canonical text"))

  defp deny!(f, :membership), do: Fixtures.revoke_membership!(f.source_binary)

  defp deny!(f, :epoch),
    do:
      owner_sql(
        "UPDATE identity.principals SET authorization_epoch=authorization_epoch+1 WHERE id=$1",
        [dump(f.source.principal_id)]
      )

  defp deny!(f, :capability),
    do:
      owner_sql(
        "DELETE FROM core.principal_capabilities WHERE principal_id=$1 AND vault_id=$2 AND capability_id=(SELECT id FROM core.capabilities WHERE name='asset.read')",
        [dump(f.source.principal_id), dump(f.source.vault_id)]
      )

  defp deny!(f, :expiry),
    do:
      owner_sql(
        "UPDATE identity.sessions SET expires_at=clock_timestamp()-interval '1 second' WHERE id=$1",
        [dump(f.source.session_id)]
      )

  defp deny!(f, :unlock) do
    assert {:ok, token} =
             KeyCustodian.begin_revoke(f.custodian, %{session_id: f.session.session_id})

    assert :ok = KeyCustodian.finish_revoke(f.custodian, token)
  end

  defp wrong_document(binding, :pin),
    do: put_in(binding.version["version_id"], Ecto.UUID.generate())

  defp wrong_document(binding, :object),
    do: put_in(binding.source["object_id"], Ecto.UUID.generate())

  defp wrong_document(binding, :size), do: put_in(binding.version["original_byte_size"], 1)

  defp wrong_document(binding, :digest),
    do: put_in(binding.version["original_digest"], sha("wrong original"))

  defp wrong_document(binding, :generation), do: put_in(binding.source["object_generation"], 2)
  defp wrong_document(binding, :format), do: put_in(binding.source["format_version"], 2)
  defp wrong_asset_field("classification"), do: "restricted"
  defp wrong_asset_field("domain_key_generation"), do: 2
  defp wrong_asset_field(_identity), do: Ecto.UUID.generate()

  defp corrupt_byte!(path, offset) do
    File.chmod!(path, 0o600)
    assert {:ok, device} = :file.open(String.to_charlist(path), [:read, :write, :binary, :raw])

    try do
      assert {:ok, <<byte>>} = :file.pread(device, offset, 1)
      assert :ok = :file.pwrite(device, offset, <<Bitwise.bxor(byte, 1)>>)
      assert :ok = :file.sync(device)
    after
      assert :ok = :file.close(device)
    end
  end

  defp requirement(f),
    do: %{
      vault_id: f.session.vault_id,
      principal_authorization_epoch: f.session.principal_authorization_epoch,
      vault_authorization_epoch: f.session.vault_authorization_epoch,
      classification: :private,
      required_capability: "asset.read",
      requires_unlocked?: true
    }

  defp call(function, f, binding) do
    assert Code.ensure_loaded?(@read), "missing concrete knowledge ExportRead"
    assert function_exported?(@read, function, 3)
    apply(@read, function, [f.runtime, f.session, binding])
  end

  defp owner_sql(statement, params),
    do: Fixtures.with_owner(fn -> query!(MigrationRepo, statement, params) end)

  defp plaintext(:zero), do: ""
  defp plaintext(:nonempty), do: :binary.copy("a", 131_073)
  defp plaintext(:aligned), do: :binary.copy("b", 4_194_304) <> "tail"
  defp dump(id), do: Ecto.UUID.dump!(id)
  defp text(<<_::binary-size(16)>> = id), do: Ecto.UUID.load!(id)
  defp text(value), do: value
  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
  defp sha(bytes), do: hex(:crypto.hash(:sha256, bytes))
  defp sha_final(hash), do: hex(:crypto.hash_final(hash))

  defp events(acc \\ []) do
    receive do
      event when elem(event, 0) == :live_read -> events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
