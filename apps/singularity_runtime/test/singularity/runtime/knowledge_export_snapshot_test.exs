defmodule Singularity.Runtime.KnowledgeExportSnapshotTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.{AuthorizationDependencies, Authorize, OperationScope, SessionContext}

  @moduletag :tmp_dir
  @snapshot Singularity.Runtime.Knowledge.ExportSnapshot
  @spool Singularity.Storage.KnowledgeExport.Spool
  @principal "00000000-0000-4000-8000-000000007001"
  @owner "00000000-0000-4000-8000-000000007002"
  @session "00000000-0000-4000-8000-000000007003"

  # These adapters exercise real OperationScope/Authorize composition only.
  # They establish no live SQL, lock, session or custody acceptance.
  defmodule Repo do
    def in_transaction?(), do: Process.get(:export_snapshot_in_transaction, false)
    def checkout(callback), do: callback.()
  end

  defmodule Lock do
    def with_shared(repo, owner, callback) do
      send(self(), {:composition, :vault_lock, owner})

      try do
        callback.(repo)
      after
        send(self(), {:composition, :vault_unlock})
      end
    end

    def with_shared(repo, principal, owner, callback) do
      send(self(), {:composition, :authorization_lock, principal, owner})

      try do
        callback.(repo)
      after
        send(self(), {:composition, :authorization_unlock})
      end
    end
  end

  defmodule Scoped do
    def transact(repo, context, options, callback) do
      send(self(), {:composition, :transaction_options, options})
      send(self(), {:composition, :context, context})
      Process.put(:export_snapshot_in_transaction, true)

      try do
        result = callback.(repo)
        send(self(), {:composition, :callback_result, result})

        case Process.get(:export_snapshot_commit_error) do
          nil ->
            send(self(), {:composition, :commit})
            result

          error ->
            {:error, error}
        end
      after
        Process.put(:export_snapshot_in_transaction, false)
        send(self(), {:composition, :transaction_closed})
      end
    end
  end

  defmodule Store do
    def load_live_session(repo, session_id) do
      send(self(), {:composition, :authorization_read, repo, session_id})
      {:ok, Process.get(:export_snapshot_live)}
    end
  end

  defmodule Custodian do
    def assert_unlocked(session, principal, owner, principal_epoch, owner_epoch) do
      send(
        self(),
        {:composition, :unlock_check, session, principal, owner, principal_epoch, owner_epoch}
      )

      Process.get(:export_snapshot_unlock_result, :ok)
    end
  end

  defmodule Audit do
    def append(_repo, event) do
      send(self(), {:composition, :audit, event})
      :ok
    end
  end

  defmodule CaptureProbe do
    alias Singularity.Runtime.KnowledgeExportSnapshotTest.Repo
    alias Singularity.Storage.KnowledgeExport.Spool
    import ExUnit.Assertions

    def capture(repo, authorize_snapshot, options, spool) do
      assert Repo.in_transaction?()
      assert is_function(authorize_snapshot, 1)
      send(self(), {:composition, :capture, repo, options})

      case Process.get(:export_snapshot_probe) do
        :wrong_repo ->
          authorize_snapshot.(:foreign_repo)

        :wrong_caller ->
          Task.async(fn -> authorize_snapshot.(repo) end) |> Task.await()

        :denied_repeat ->
          Process.put(
            :export_snapshot_live,
            %{Process.get(:export_snapshot_live) | capabilities: []}
          )

          authorize_snapshot.(repo)

        :callback_error ->
          {:error, Singularity.Core.Error.new(:integrity_failure)}

        :callback_raise ->
          raise "bounded capture failure"

        _ ->
          assert {:ok, session} = authorize_snapshot.(repo)
          assert session == Process.get(:export_snapshot_session)
          assert {:ok, sealed} = apply(Spool, :seal, [spool])
          {:ok, sealed}
      end
    end
  end

  setup %{tmp_dir: tmp_dir} do
    for name <- ~w(export storage backup) do
      path = Path.join(tmp_dir, name)
      File.mkdir!(path)
      File.chmod!(path, 0o700)
    end

    {:ok, authorization} = AuthorizationDependencies.new(%{store: Store, custodian: Custodian})

    session = %SessionContext{
      session_id: @session,
      principal_id: @principal,
      vault_id: @owner,
      expires_at: DateTime.add(DateTime.utc_now(), 3600),
      principal_authorization_epoch: 7,
      authorization_epoch: 7,
      vault_authorization_epoch: 23,
      unlocked?: true
    }

    Process.put(:export_snapshot_session, session)

    Process.put(
      :export_snapshot_live,
      %{
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
      }
    )

    runtime = %{
      request_repo: Repo,
      vault_lock: Lock,
      authorization_lock: Lock,
      scoped_repo: Scoped,
      operation_scope: OperationScope,
      authorizer: Authorize,
      authorization: authorization,
      audit: Audit,
      knowledge_export_repository: CaptureProbe
    }

    context = %{
      root: Path.join(tmp_dir, "export"),
      storage_root: Path.join(tmp_dir, "storage"),
      backup_root: Path.join(tmp_dir, "backup")
    }

    %{runtime: runtime, session: session, context: context}
  end

  test "private transaction adapter fixes RR before context without changing shared adapters",
       c do
    assert {:ok, :callback} =
             call(:transact, [
               Scoped,
               Repo,
               %{principal_id: @principal, vault_id: @owner},
               fn repo ->
                 assert repo == Repo
                 assert Repo.in_transaction?()
                 {:ok, :callback}
               end
             ])

    assert_receive {:composition, :transaction_options, [isolation: :repeatable_read]}
    assert_receive {:composition, :context, %{principal_id: @principal, vault_id: @owner}}
    assert_receive {:composition, :commit}
    refute Repo.in_transaction?()
    assert c.runtime.scoped_repo == Scoped
  end

  test "capture repeats fixed unlocked Note Asset authority under existing shared locks", c do
    spool = open(c)
    runtime_before = c.runtime
    assert {:ok, sealed} = call(:capture, [c.runtime, c.session, %{}, spool])
    refute Repo.in_transaction?()
    assert c.runtime == runtime_before
    trace = drain()
    names = Enum.map(trace, &elem(&1, 1))

    assert names == [
             :vault_lock,
             :authorization_lock,
             :transaction_options,
             :context,
             :authorization_read,
             :unlock_check,
             :capture,
             :authorization_read,
             :unlock_check,
             :callback_result,
             :commit,
             :transaction_closed,
             :authorization_unlock,
             :vault_unlock
           ]

    assert {:composition, :transaction_options, [isolation: :repeatable_read]} in trace
    assert {:composition, :capture, Repo, %{include_tombstones: false}} in trace
    assert :ok = spool_call(:abort, [sealed])
  end

  test "nested active transactions reject before the scope or content selection", c do
    spool = open(c)
    Process.put(:export_snapshot_in_transaction, true)
    assert_error(call(:capture, [c.runtime, c.session, %{}, spool]))
    Process.put(:export_snapshot_in_transaction, false)
    refute Enum.any?(drain(), &(elem(&1, 1) == :capture))
    assert :ok = spool_call(:abort, [spool])
  end

  test "forged session values and caller owner adapter or path options cannot enter capture", c do
    for session <- [Map.from_struct(c.session), true, nil], options <- [%{}] do
      spool = open(c)
      assert_error(call(:capture, [c.runtime, session, options, spool]))
      refute Enum.any?(drain(), &(elem(&1, 1) == :capture))
      assert :ok = spool_call(:abort, [spool])
    end

    for key <- [:owner_scope_id, :vault_id, :destination, :adapter, :limits] do
      spool = open(c)
      assert_error(call(:capture, [c.runtime, c.session, %{key => "caller"}, spool]))
      refute Enum.any?(drain(), &(elem(&1, 1) == :capture))
      assert :ok = spool_call(:abort, [spool])
    end
  end

  for mode <- [:wrong_repo, :wrong_caller, :denied_repeat] do
    @mode mode
    test "trusted lexical closure denies #{mode} before returning any sealed output", c do
      Process.put(:export_snapshot_probe, @mode)
      spool = open(c)
      assert_error(call(:capture, [c.runtime, c.session, %{}, spool]))
      refute Repo.in_transaction?()
      refute File.exists?(Path.join(c.context.root, spool.capture_id))
    end
  end

  for mode <- [:callback_error, :callback_raise, :commit_failure] do
    @mode mode
    test "#{mode} closes the transaction and cleans even sealed uncommitted output", c do
      if @mode == :commit_failure,
        do: Process.put(:export_snapshot_commit_error, Error.new(:storage_unavailable)),
        else: Process.put(:export_snapshot_probe, @mode)

      spool = open(c)
      sentinel = Path.join(c.context.root, "neighbor")
      File.write!(sentinel, "safe")
      assert_error(call(:capture, [c.runtime, c.session, %{}, spool]))
      refute Repo.in_transaction?()
      refute File.exists?(Path.join(c.context.root, spool.capture_id))
      assert File.read!(sentinel) == "safe"
    end
  end

  test "initial real Authorize denial preserves OperationScope denial audit and no capture", c do
    Process.put(:export_snapshot_live, %{Process.get(:export_snapshot_live) | capabilities: []})
    spool = open(c)
    assert {:error, %Error{code: :forbidden}} = call(:capture, [c.runtime, c.session, %{}, spool])
    trace = drain()
    assert Enum.any?(trace, &match?({:composition, :audit, %{result: :denied}}, &1))
    refute Enum.any?(trace, &(elem(&1, 1) == :capture))
    refute File.exists?(Path.join(c.context.root, spool.capture_id))
  end

  defp open(c) do
    {:ok, spool} = spool_call(:open, [c.context])
    spool
  end

  defp spool_call(function, args), do: apply(@spool, function, args)

  defp call(function, args) do
    assert Code.ensure_loaded?(@snapshot), "missing fixed Runtime ExportSnapshot entry"
    assert function_exported?(@snapshot, function, length(args))
    apply(@snapshot, function, args)
  end

  defp assert_error(result), do: assert(match?({:error, %Error{}}, result))

  defp drain(events \\ []) do
    receive do
      {:composition, _, _} = event -> drain([event | events])
      {:composition, _, _, _} = event -> drain([event | events])
      {:composition, _, _, _, _, _, _} = event -> drain([event | events])
      {:composition, _} = event -> drain([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end

defmodule Singularity.Runtime.KnowledgeExportSnapshotSQLTest do
  use Singularity.Storage.DataCase, async: false

  alias Singularity.Core.Error
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.KnowledgeExportSnapshotFixture, as: LiveFixture
  alias Singularity.Runtime.KnowledgeExportSnapshotFixture.ObservedIdentity
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo}

  @moduletag :integration
  @moduletag :tmp_dir
  @snapshot Singularity.Runtime.Knowledge.ExportSnapshot
  @repository Singularity.Storage.KnowledgeExport.Repository
  @spool Singularity.Storage.KnowledgeExport.Spool

  defmodule CommitFailure do
    def transact(context, repo, scope, options, callback) do
      Singularity.Storage.ScopedRepo.transact(repo, scope, options, fn scoped ->
        result = callback.(scoped)
        send(context.parent, {:sealed_before_failed_commit, result, scoped.in_transaction?()})
        # The existing deferred head FK/typed-head constraint is violated only
        # after a successful capture. The legacy UPDATE privilege is unchanged.
        Singularity.Storage.SafeSQL.query!(
          scoped,
          "UPDATE content.resources SET current_version_id=$1 WHERE id=$2 AND vault_id=$3",
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            context.resource_id,
            Ecto.UUID.dump!(scope.vault_id)
          ]
        )

        send(context.parent, :deferred_head_update_completed)
        result
      end)
    end
  end

  defmodule CallbackFailure do
    def capture(repo, authorize_snapshot, options, spool) do
      {:ok, sealed} =
        apply(Singularity.Storage.KnowledgeExport.Repository, :capture, [
          repo,
          authorize_snapshot,
          options,
          spool
        ])

      send(self(), {:sealed_before_callback_failure, sealed, repo.in_transaction?()})
      {:error, Singularity.Core.Error.new(:integrity_failure)}
    end
  end

  defmodule IdentityResultObserver do
    def load_live_session(observer, repo, session_id) do
      result =
        Singularity.Runtime.KnowledgeExportSnapshotFixture.ObservedIdentity.load_live_session(
          %{parent: observer.parent},
          repo,
          session_id
        )

      send(
        observer.parent,
        {:native_identity_result, observer.probe, repo, self(), repo.in_transaction?(), result}
      )

      result
    end
  end

  defmodule AuditInsertObserver do
    def with_observer(observer, callback) do
      key = {__MODULE__, :observer}
      previous = Process.get(key)
      Process.put(key, observer)

      try do
        callback.()
      after
        if is_nil(previous), do: Process.delete(key), else: Process.put(key, previous)
      end
    end

    def insert(changeset) do
      alias Singularity.Storage.RequestRepo
      %{parent: _, probe: _} = observer = Process.get({__MODULE__, :observer})

      %{rows: [[backend, principal, owner]]} =
        Singularity.Storage.DataCase.query!(
          RequestRepo,
          "SELECT pg_backend_pid(),current_setting('singularity.principal_id',true),current_setting('singularity.vault_id',true)"
        )

      send(
        observer.parent,
        {:native_audit_insert_scope, observer.probe, self(), RequestRepo.in_transaction?(),
         backend, principal, owner}
      )

      try do
        RequestRepo.insert(changeset)
      rescue
        error in Postgrex.Error ->
          send(
            observer.parent,
            {:native_audit_insert_error, observer.probe, self(), error.postgres.code,
             error.postgres.pg_code}
          )

          reraise error, __STACKTRACE__
      end
    end
  end

  defmodule AuditResultObserver do
    def append(observer, repo, event) do
      import ExUnit.Assertions
      assert repo == Singularity.Storage.RequestRepo
      assert repo.in_transaction?()
      assert self() == observer.parent
      send(observer.parent, {:native_audit_attempt, observer.probe, repo, self(), event})

      result =
        Singularity.Runtime.KnowledgeExportSnapshotSQLTest.AuditInsertObserver.with_observer(
          observer,
          fn ->
            Singularity.Storage.Postgres.AuditSink.append(
              Singularity.Runtime.KnowledgeExportSnapshotSQLTest.AuditInsertObserver,
              event
            )
          end
        )

      send(observer.parent, {:native_audit_result, observer.probe, result})
      result
    end
  end

  defmodule CaptureEntryObserver do
    def capture(observer, repo, authorize_snapshot, options, spool) do
      send(observer.parent, {:repository_capture_entered, observer.probe})

      apply(Singularity.Storage.KnowledgeExport.Repository, :capture, [
        repo,
        authorize_snapshot,
        options,
        spool
      ])
    end
  end

  setup %{tmp_dir: tmp_dir}, do: LiveFixture.live_fixture!(tmp_dir)

  test "real resolver and Authorize capture under RR before auth SQL without READ ONLY", c do
    note = note!(c, "canonical 界\r\n")
    spool = open(c)
    assert {:ok, sealed} = capture(c, spool)
    assert_receive {:sql_snapshot_authorization, _, "repeatable read", "off"}
    assert_receive {:sql_snapshot_authorization, _, "repeatable read", "off"}
    assert_fresh_scope()

    assert {:ok, %{records: [version], next_cursor: nil}} =
             apply(@repository, :next_page, [sealed, cursor(sealed, :versions), 500])

    assert version["version_id"] == text(note.resource_version_id)
    assert version["body_digest"] == sha("canonical 界\r\n")
    assert :ok = apply(@spool, :abort, [sealed])
  end

  for denial <- [
        :session_revoked,
        :session_expired,
        :principal_revoked,
        :membership_revoked,
        :principal_epoch,
        :owner_epoch,
        :missing_note_read,
        :missing_asset_read,
        :database_locked,
        :custody_locked,
        :wrong_principal,
        :wrong_owner
      ] do
    @denial denial
    test "live #{@denial} rejects stale resolved hints and cleans only its operation", c do
      note!(c, "DENIAL_BODY_CANARY")
      c = deny!(c, @denial)
      spool = open(c)
      sentinel = Path.join(c.context.root, "neighbor")
      File.write!(sentinel, "safe")

      if denial_audit_failure?(@denial) do
        assert_native_denial_audit_failure(c, spool, @denial)
      else
        assert {:error, %Error{code: code}} = capture(c, spool)
        assert code in [:forbidden, :unauthenticated, :vault_locked]
      end

      refute File.exists?(Path.join(c.context.root, spool.capture_id))
      assert File.read!(sentinel) == "safe"
      assert_fresh_scope()
    end
  end

  test "real nested request transaction cannot create or publish another snapshot", c do
    note!(c, "body")
    spool = open(c)

    assert {:ok, :nested_rejected} =
             RequestRepo.transaction(fn ->
               assert {:error, %Error{code: :invalid}} = capture(c, spool)
               assert RequestRepo.in_transaction?()
               :nested_rejected
             end)

    assert_fresh_scope()
    assert :ok = apply(@spool, :abort, [spool])
  end

  test "real deferred COMMIT failure aborts a sealed spool and exposes no success descriptor",
       c do
    note = note!(c, "body")
    spool = open(c)

    runtime = %{
      c.runtime
      | scoped_repo: {CommitFailure, %{parent: self(), resource_id: note.resource_id}}
    }

    assert {:error, %Error{}} = capture(%{c | runtime: runtime}, spool)
    assert_receive :deferred_head_update_completed
    assert_receive {:sealed_before_failed_commit, {:ok, internal_sealed}, true}
    assert internal_sealed.capture_id == spool.capture_id
    refute File.exists?(Path.join(c.context.root, spool.capture_id))
    assert_fresh_scope()
  end

  test "real SQL callback failure after sealing rolls back and invalidates all handles", c do
    note!(c, "CALLBACK_FAILURE_BODY_CANARY")
    spool = open(c)
    runtime = Map.put(c.runtime, :knowledge_export_repository, CallbackFailure)
    assert {:error, %Error{code: :integrity_failure}} = capture(%{c | runtime: runtime}, spool)
    assert_receive {:sealed_before_callback_failure, sealed, true}
    assert sealed.capture_id == spool.capture_id
    refute File.exists?(Path.join(c.context.root, spool.capture_id))

    assert {:error, %Error{}} =
             apply(@repository, :next_page, [sealed, cursor(sealed, :versions), 500])

    assert_fresh_scope()
  end

  test "two-connection cut preserves head and canonical text and transaction closes before consumption",
       c do
    note = note!(c, "CUT_CANONICAL_界")
    spool = open(c)
    barrier = make_ref()

    dependencies = %{
      c.runtime.authorization
      | store: {ObservedIdentity, %{parent: self(), barrier: barrier}}
    }

    runtime = %{c.runtime | authorization: dependencies}
    task = Task.async(fn -> capture(%{c | runtime: runtime}, spool) end)
    assert_receive {:sql_snapshot_cut, pid, ^barrier}, 5_000
    task_ref = task.ref
    refute_receive {^task_ref, {:ok, _}}
    next_version = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',1)",
        [next_version, note.resource_id, dump(c.source.vault_id)]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,parent_version_id,inserted_at) VALUES($1,$2,$3,'private','After cut','AFTER_CUT_BODY',$4,$5,CURRENT_TIMESTAMP)",
        [
          next_version,
          note.resource_id,
          dump(c.source.vault_id),
          dump(c.source.principal_id),
          note.resource_version_id
        ]
      )

      query!(
        MigrationRepo,
        "UPDATE content.resources SET current_version_id=$1,title='After cut' WHERE id=$2",
        [next_version, note.resource_id]
      )
    end)

    send(pid, {:continue_snapshot, barrier})
    assert {:ok, sealed} = Task.await(task, 5_000)
    assert_fresh_scope()

    assert {:ok, %{records: [resource], next_cursor: nil}} =
             apply(@repository, :next_page, [sealed, cursor(sealed, :resources), 500])

    assert resource["current_version_id"] == text(note.resource_version_id)
    key = {:note_markdown, text(note.resource_id), text(note.resource_version_id)}

    assert {:ok, "CUT_CANONICAL_界"} =
             apply(@spool, :read_chunk, [sealed, Map.fetch!(sealed.text_refs, key), 0])

    refute Map.has_key?(
             sealed.text_refs,
             {:note_markdown, text(note.resource_id), text(next_version)}
           )

    assert :ok = apply(@spool, :abort, [sealed])
  end

  defp note!(c, body) do
    source =
      Map.new(c.source, fn {key, value} ->
        {key, if(String.ends_with?(Atom.to_string(key), "_id"), do: dump(value), else: value)}
      end)

    note = KnowledgeFixtures.note_identity!(source)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resources(id,vault_id,classification,kind,current_version_id,title) VALUES($1,$2,'private','note',$3,'Captured Note')",
        [note.resource_id, note.vault_id, note.resource_version_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',0)",
        [note.resource_version_id, note.resource_id, note.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,inserted_at) VALUES($1,$2,$3,'private','Captured Note',$4,$5,CURRENT_TIMESTAMP)",
        [note.resource_version_id, note.resource_id, note.vault_id, body, source.principal_id]
      )
    end)

    note
  end

  defp deny!(c, :wrong_principal),
    do: %{c | session: %{c.session | principal_id: Ecto.UUID.generate()}}

  defp deny!(c, :wrong_owner), do: %{c | session: %{c.session | vault_id: Ecto.UUID.generate()}}

  defp deny!(c, :custody_locked) do
    assert {:ok, token} =
             KeyCustodian.begin_revoke(c.custodian, %{session_id: c.session.session_id})

    assert :ok = KeyCustodian.finish_revoke(c.custodian, token)
    c
  end

  defp deny!(c, denial) do
    Fixtures.with_owner(fn ->
      case denial do
        :session_revoked ->
          query!(
            MigrationRepo,
            "UPDATE identity.sessions SET revoked_at=CURRENT_TIMESTAMP WHERE id=$1",
            [dump(c.source.session_id)]
          )

        :session_expired ->
          query!(
            MigrationRepo,
            "UPDATE identity.sessions SET expires_at=CURRENT_TIMESTAMP-interval '1 second' WHERE id=$1",
            [dump(c.source.session_id)]
          )

        :principal_revoked ->
          query!(
            MigrationRepo,
            "UPDATE identity.principals SET revoked_at=CURRENT_TIMESTAMP WHERE id=$1",
            [dump(c.source.principal_id)]
          )

        :membership_revoked ->
          query!(
            MigrationRepo,
            "UPDATE core.vault_members SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
            [dump(c.source.principal_id), dump(c.source.vault_id)]
          )

        :principal_epoch ->
          query!(
            MigrationRepo,
            "UPDATE identity.principals SET authorization_epoch=authorization_epoch+1 WHERE id=$1",
            [dump(c.source.principal_id)]
          )

        :owner_epoch ->
          query!(
            MigrationRepo,
            "UPDATE core.vaults SET authorization_epoch=authorization_epoch+1 WHERE id=$1",
            [dump(c.source.vault_id)]
          )

        :database_locked ->
          query!(MigrationRepo, "UPDATE core.vaults SET locked=true WHERE id=$1", [
            dump(c.source.vault_id)
          ])

        missing when missing in [:missing_note_read, :missing_asset_read] ->
          capability = if missing == :missing_note_read, do: "note.read", else: "asset.read"

          query!(
            MigrationRepo,
            "DELETE FROM core.principal_capabilities WHERE principal_id=$1 AND vault_id=$2 AND capability_id=(SELECT id FROM core.capabilities WHERE name=$3)",
            [dump(c.source.principal_id), dump(c.source.vault_id), capability]
          )
      end
    end)

    c
  end

  defp open(c) do
    {:ok, spool} = apply(@spool, :open, [c.context])
    spool
  end

  defp capture(c, spool), do: apply(@snapshot, :capture, [c.runtime, c.session, %{}, spool])

  defp denial_audit_failure?(denial),
    do: denial in [:wrong_principal, :wrong_owner, :membership_revoked]

  defp assert_native_denial_audit_failure(c, spool, denial) do
    caller = self()
    probe = make_ref()
    observer = %{parent: caller, probe: probe}
    authorization = %{c.runtime.authorization | store: {IdentityResultObserver, observer}}
    scope = %{principal_id: c.session.principal_id, vault_id: c.session.vault_id}

    requirement = %{
      required_capabilities: ["asset.read", "note.read"],
      classification: :private,
      requires_unlocked?: true,
      vault_id: c.session.vault_id,
      principal_authorization_epoch:
        c.session.principal_authorization_epoch || c.session.authorization_epoch,
      vault_authorization_epoch: c.session.vault_authorization_epoch
    }

    assert {:error, %Error{code: code}} =
             RequestRepo.checkout(fn ->
               Singularity.Storage.ScopedRepo.transact(
                 RequestRepo,
                 scope,
                 [isolation: :repeatable_read],
                 fn repo ->
                   Singularity.Runtime.Authorize.check(
                     authorization,
                     repo,
                     c.session,
                     requirement
                   )
                 end
               )
             end)

    assert code in [:forbidden, :unauthenticated, :vault_locked]
    assert code == if(denial == :membership_revoked, do: :forbidden, else: :unauthenticated)
    assert_receive {:sql_snapshot_authorization, ^caller, "repeatable read", "off"}
    assert_receive {:native_identity_result, ^probe, RequestRepo, ^caller, true, {:ok, live}}
    assert_native_identity_return(live, c.session, denial)
    assert_fresh_scope()

    runtime =
      c.runtime
      |> Map.put(:authorization, authorization)
      |> Map.put(:audit, {AuditResultObserver, observer})
      |> Map.put(:knowledge_export_repository, {CaptureEntryObserver, observer})

    capture_result = capture(%{c | runtime: runtime}, spool)
    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} = capture_result
    assert_receive {:sql_snapshot_authorization, ^caller, "repeatable read", "off"}

    assert_receive {:native_identity_result, ^probe, RequestRepo, ^caller, true,
                    {:ok, captured_live}}

    assert_native_identity_return(captured_live, c.session, denial)
    assert_receive {:native_audit_attempt, ^probe, RequestRepo, ^caller, event}
    assert event.action == "authorization.denied"
    assert event.result == :denied
    assert event.actor_kind == :principal
    assert event.principal_id == c.session.principal_id
    assert event.vault_id == c.session.vault_id
    assert event.metadata == %{}
    assert {:ok, audit_id} = Ecto.UUID.cast(event.audit_event_id)
    assert audit_id == event.audit_event_id
    assert_receive {:native_audit_insert_scope, ^probe, ^caller, true, backend, principal, owner}
    assert is_integer(backend) and backend > 0
    assert principal == c.session.principal_id
    assert owner == c.session.vault_id
    assert_receive {:native_audit_insert_error, ^probe, ^caller, :insufficient_privilege, "42501"}
    assert_receive {:native_audit_result, ^probe, sink_result}
    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} = sink_result
    assert capture_result == sink_result
    refute_receive {:repository_capture_entered, ^probe}

    assert %{rows: [[0]]} =
             Fixtures.with_owner(fn ->
               query!(MigrationRepo, "SELECT count(*) FROM audit.events WHERE id=$1", [
                 dump(audit_id)
               ])
             end)
  end

  defp assert_native_identity_return(live, session, :membership_revoked) do
    assert live.session_id == session.session_id
    assert live.principal_id == session.principal_id
    assert live.vault_id == session.vault_id
    assert %DateTime{} = live.membership_revoked_at
  end

  defp assert_native_identity_return(live, _session, denial)
       when denial in [:wrong_principal, :wrong_owner],
       do: assert(is_nil(live))

  defp cursor(sealed, collection),
    do: %{capture_id: sealed.capture_id, collection: collection, after: nil}

  defp dump(id), do: Ecto.UUID.dump!(id)
  defp text(id), do: Ecto.UUID.load!(id)
  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp assert_fresh_scope do
    RequestRepo.checkout(fn ->
      refute RequestRepo.in_transaction?()

      assert %{rows: [[principal, owner]]} =
               query!(
                 RequestRepo,
                 "SELECT current_setting('singularity.principal_id',true),current_setting('singularity.vault_id',true)"
               )

      assert principal in [nil, ""]
      assert owner in [nil, ""]
    end)
  end
end
