defmodule Singularity.Runtime.KnowledgeExportArtifactTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{Error, KnowledgeExport, NoteSnapshot}
  alias Singularity.Runtime.{AuthorizationDependencies, Authorize, OperationScope, SessionContext}
  alias Singularity.Storage.KnowledgeExport.{Spool, Writer}

  @moduletag :tmp_dir
  @export Singularity.Runtime.Knowledge.Export
  @session "00000000-0000-4000-8000-000000009201"
  @principal "00000000-0000-4000-8000-000000009202"
  @owner "00000000-0000-4000-8000-000000009203"
  @resource "00000000-0000-4000-8000-000000009204"
  @version "00000000-0000-4000-8000-000000009205"
  @foreign "00000000-0000-4000-8000-000000009206"
  @body "# Owned note\n\nReal retained Markdown 界\n"
  @collections ~w(resources versions fragments tags tag_assignments relationships attachments citations)a
  @now 5_000

  # This fixture uses real Spool, Writer, filesystem and ETS, and the actual
  # OperationScope/Authorize modules. Agent-backed authority, custody unlock,
  # locks and Scoped COMMIT are SYNTHETIC: no SQL, native custody, encrypted
  # original, lease cleanup or real database COMMIT acceptance is claimed here.
  defmodule Repo do
    def in_transaction?(), do: Process.get({__MODULE__, :transaction}, false)
    def in_transaction?(_context), do: in_transaction?()
    def checkout(_context, callback), do: callback.()
  end

  defmodule Lock do
    alias Singularity.Runtime.KnowledgeExportArtifactTest, as: Contract

    def with_shared(context, repo, owner, callback),
      do: locked(context, {:vault_lock, owner}, repo, callback)

    def with_shared(context, repo, principal, owner, callback),
      do: locked(context, {:authorization_lock, principal, owner}, repo, callback)

    defp locked(context, event, repo, callback) do
      Contract.record(context, event)
      key = {__MODULE__, :depth}
      previous = Process.get(key, 0)
      Process.put(key, previous + 1)

      try do
        callback.(repo)
      after
        Process.put(key, previous)
      end
    end
  end

  defmodule Scoped do
    alias Singularity.Runtime.KnowledgeExportArtifactTest, as: Contract
    alias Singularity.Runtime.KnowledgeExportArtifactTest.Repo

    def transact(context, repo, scope, callback),
      do: transact(context, repo, scope, [], callback)

    def transact(context, repo, scope, options, callback) do
      Contract.record(context, {:transaction, scope, options})
      previous = Repo.in_transaction?()
      Process.put({Repo, :transaction}, true)

      try do
        result = callback.(repo)
        Contract.record(context, {:simulated_commit, self()})
        result
      after
        Process.put({Repo, :transaction}, previous)
      end
    end
  end

  defmodule Store do
    alias Singularity.Runtime.KnowledgeExportArtifactTest, as: Contract
    alias Singularity.Runtime.KnowledgeExportArtifactTest.Repo

    def load_live_session(context, _repo, session_id) do
      Contract.record(context, {:live_authority, session_id, Repo.in_transaction?()})
      {:ok, Agent.get(context.state, & &1.live)}
    end
  end

  defmodule Custodian do
    alias Singularity.Runtime.KnowledgeExportArtifactTest, as: Contract

    def assert_unlocked(context, session, principal, owner, principal_epoch, owner_epoch) do
      Contract.record(context, {:unlock, session, principal, owner, principal_epoch, owner_epoch})
      Agent.get(context.state, & &1.unlock)
    end
  end

  defmodule Audit do
    def append(_context, _repo, _event), do: :ok
  end

  defmodule Repository do
    alias Singularity.Runtime.KnowledgeExportArtifactTest, as: Contract
    alias Singularity.Runtime.KnowledgeExportArtifactTest.Repo

    def capture(context, repo, authorize, options, spool) do
      true = Repo.in_transaction?()
      {:ok, _session} = authorize.(repo)
      Contract.record(context, {:capture, self(), options})
      Agent.update(context.state, &Map.put(&1, :capture_root, spool._identity.root))
      Contract.barrier(context, :during_capture)
      {:ok, Contract.sealed_fixture!(spool)}
    end

    def revalidate_note(context, _repo, %{version: version}) do
      true = Repo.in_transaction?()
      true = version["resource_id"] == Contract.resource_id()
      true = version["version_id"] == Contract.version_id()
      true = version["body_digest"] == Contract.sha(Contract.body())
      Contract.record(context, {:revalidate_note, self()})

      if Contract.completed_writer?(context), do: Contract.barrier(context, :before_completion)
      :ok
    end
  end

  setup %{tmp_dir: tmp} do
    roots = Map.new(~w(export storage backup)a, &{&1, Path.join(tmp, to_string(&1))})

    for path <- Map.values(roots) do
      File.mkdir!(path)
      File.chmod!(path, 0o700)
    end

    File.write!(Path.join(roots.export, "foreign-sentinel"), "foreign bytes")
    File.write!(Path.join(roots.storage, "storage-sentinel"), "storage bytes")
    File.write!(Path.join(roots.backup, "backup-sentinel"), "backup bytes")

    session = %SessionContext{
      session_id: @session,
      principal_id: @principal,
      vault_id: @owner,
      expires_at: ~U[2099-01-01 00:00:00Z],
      principal_authorization_epoch: 7,
      authorization_epoch: 7,
      vault_authorization_epoch: 23,
      unlocked?: true
    }

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             now: @now,
             live: live(session),
             unlock: :ok,
             events: [],
             barrier: nil,
             barrier_fired: false,
             capture_root: nil
           }
         end}
      )

    supervisor = start_supervised!({Task.Supervisor, []})
    context = %{state: state, observer: self(), ref: make_ref()}

    {:ok, authorization} =
      AuthorizationDependencies.new(%{store: {Store, context}, custodian: {Custodian, context}})

    runtime = %{
      request_repo: {Repo, context},
      vault_lock: {Lock, context},
      authorization_lock: {Lock, context},
      scoped_repo: {Scoped, context},
      operation_scope: OperationScope,
      authorizer: Authorize,
      authorization: authorization,
      audit: {Audit, context},
      knowledge_export_repository: {Repository, context},
      knowledge_export: %{
        root: roots.export,
        storage_root: roots.storage,
        backup_root: roots.backup,
        task_supervisor: supervisor,
        clock: fn -> Agent.get(state, & &1.now) end
      }
    }

    %{
      runtime: runtime,
      session: session,
      roots: roots,
      state: state,
      context: context,
      supervisor: supervisor
    }
  end

  test "standalone sealed fixture uses real Writer and independently verified retained bytes",
       c do
    root = Path.join(Path.dirname(c.roots.export), "fixture")
    File.mkdir!(root)
    File.chmod!(root, 0o700)

    {:ok, spool} =
      Spool.open(%{root: root, storage_root: c.roots.storage, backup_root: c.roots.backup})

    capture = sealed_fixture!(spool)

    {:ok, writer} =
      Writer.open(%{
        root: root,
        storage_root: c.roots.storage,
        backup_root: c.roots.backup,
        capture: capture,
        options: %{include_tombstones: false},
        original_fold: fn _selector, _acc, _emit ->
          flunk("Note-only fixture has no originals")
        end
      })

    assert :ets.info(writer._ledger, :owner) == self()

    writer =
      Enum.reduce(@collections, writer, fn collection, current ->
        {:ok, next} =
          Spool.reduce_metadata(capture, collection, current, fn record, acc ->
            Writer.append_manifest_record(acc, collection, record)
          end)

        next
      end)

    selector = {:note_markdown, @resource, @version}
    {:ok, writer} = Writer.append_file(writer, selector, Map.fetch!(capture.text_refs, selector))
    {:ok, artifact} = Writer.finish(writer)
    {:ok, bytes} = Writer.read_chunk(artifact, note_path(), 0)
    assert bytes == @body
    {:ok, %{entries: entries, next_cursor: nil}} = Writer.entries(artifact, nil)
    assert Enum.find(entries, &(&1["path"] == note_path()))["sha256"] == sha(@body)
    assert :ok = Writer.abort(artifact)
    assert :ok = Spool.abort(capture)
    assert File.ls!(root) == []
    assert_sentinels(c)
  end

  test "successful requester DOWN preserves actual Writer ledger manifest and Note chunks", c do
    {handle, requester} = generate_from_requester(c)
    refute Process.alive?(requester)
    refute handle.owner == requester
    assert Process.alive?(handle.owner)
    [ledger] = owner_ledgers(handle.owner)
    assert :ets.info(ledger, :owner) == handle.owner

    {:ok, %{entries: entries, next_cursor: nil}} = export(c, :entries, [handle, nil])
    assert length(entries) <= 500
    manifest = Enum.find(entries, &(&1["path"] == "manifest.json"))
    assert manifest["byte_size"] > 0
    {:ok, bytes} = export(c, :read_chunk, [handle, "manifest.json", 0])
    assert byte_size(bytes) <= 65_536
    assert byte_size(bytes) == manifest["byte_size"]
    assert sha(bytes) == manifest["sha256"]

    assert {:ok, %{"format" => "singularity.portable-knowledge", "version" => 1}} =
             Jason.decode(bytes)

    assert {:ok, @body} = export(c, :read_chunk, [handle, note_path(), 0])
    assert :ok = export(c, :close, [handle])
    assert :ok = export(c, :close, [handle])
    assert_cleaned(c)
  end

  for point <- [:during_capture, :before_completion] do
    @point point
    test "requester DOWN at #{@point} aborts real files before any successful handle", c do
      set_barrier(c, @point)
      {requester, requester_monitor} = start_requester(c)
      ref = c.context.ref
      assert_receive {:artifact_barrier, ^ref, @point, owner}, 5_000
      owner_monitor = Process.monitor(owner)
      [companion] = Task.Supervisor.children(c.supervisor) -- [owner]
      companion_monitor = Process.monitor(companion)
      Process.exit(requester, :kill)
      assert_receive {:DOWN, ^requester_monitor, :process, ^requester, :killed}, 5_000
      send(owner, {:release_artifact_barrier, ref})
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _}, 5_000
      assert_receive {:DOWN, ^companion_monitor, :process, ^companion, _}, 5_000
      refute_received {:export_result, ^ref, {:ok, _}}
      assert_cleaned(c)
    end
  end

  test "generation uses current synthetic authority instead of DTO unlocked hint", c do
    Agent.update(c.state, &put_in(&1.live.vault_locked, true))
    assert_error(export(c, :run, [%{}]), :vault_locked)
    assert_cleaned(c)
  end

  for {change, code} <- [
        {%{session_revoked_at: ~U[2026-10-19 00:00:00Z]}, :unauthenticated},
        {%{principal_revoked_at: ~U[2026-10-19 00:00:00Z]}, :forbidden},
        {%{membership_revoked_at: ~U[2026-10-19 00:00:00Z]}, :forbidden},
        {%{principal_authorization_epoch: 8}, :forbidden},
        {%{vault_authorization_epoch: 24}, :forbidden},
        {%{capabilities: []}, :forbidden},
        {%{vault_locked: true}, :vault_locked}
      ] do
    @change change
    @code code
    test "completed artifact rejects current synthetic authority change #{inspect(change)} and cleans",
         c do
      {handle, _requester} = generate_from_requester(c)
      Agent.update(c.state, &Map.update!(&1, :live, fn live -> Map.merge(live, @change) end))
      assert_error(export(c, :entries, [handle, nil]), @code)
      assert_cleaned(c)
      assert {:error, %Error{}} = export(c, :read_chunk, [handle, note_path(), 0])
    end
  end

  test "each actual entry and chunk delivery reloads synthetic authority under real scope", c do
    {handle, _requester} = generate_from_requester(c)
    Agent.update(c.state, &Map.put(&1, :events, []))
    assert {:ok, _} = export(c, :entries, [handle, nil])
    first = authority_count(c)
    assert first > 0
    assert {:ok, @body} = export(c, :read_chunk, [handle, note_path(), 0])
    assert authority_count(c) > first

    events = Agent.get(c.state, & &1.events)
    assert Enum.any?(events, &match?({:live_authority, @session, true}, &1))
    assert Enum.any?(events, &match?({:simulated_commit, _}, &1))
    assert Enum.any?(events, &match?({:unlock, @session, @principal, @owner, 7, 23}, &1))
    assert :ok = export(c, :close, [handle])
    assert_cleaned(c)
  end

  test "foreign identity or operation reference cannot read or destroy the victim artifact", c do
    {handle, _requester} = generate_from_requester(c)

    for session <- [
          %{c.session | session_id: @foreign},
          %{c.session | principal_id: @foreign},
          %{c.session | vault_id: @foreign},
          %{c.session | principal_authorization_epoch: 8, authorization_epoch: 8},
          %{c.session | vault_authorization_epoch: 24}
        ] do
      assert_error(export(c, :entries, [handle, nil], session), :forbidden)
      assert_error(export(c, :close, [handle], session), :forbidden)
      assert Process.alive?(handle.owner)
      assert {:ok, @body} = export(c, :read_chunk, [handle, note_path(), 0])
    end

    forged = %{handle | operation_ref: make_ref()}
    assert {:error, %Error{code: code}} = export(c, :entries, [forged, nil])
    assert code in [:invalid, :forbidden]
    assert {:ok, @body} = export(c, :read_chunk, [handle, note_path(), 0])
    assert :ok = export(c, :close, [handle])
    assert_cleaned(c)
  end

  test "malformed paths ordinals and cursors do not cancel an admitted victim", c do
    {handle, _requester} = generate_from_requester(c)
    assert_error(export(c, :read_chunk, [handle, "../foreign-sentinel", 0]), :invalid)
    assert_error(export(c, :read_chunk, [handle, note_path(), -1]), :invalid)
    assert_error(export(c, :entries, [handle, %{host_path: "PRIVATE_ARTIFACT_CANARY"}]), :invalid)
    assert {:ok, @body} = export(c, :read_chunk, [handle, note_path(), 0])
    assert :ok = export(c, :close, [handle])
    assert_cleaned(c)
  end

  test "original fixed deadline is neither refreshed by reads nor extended by a forged handle",
       c do
    {handle, _requester} = generate_from_requester(c)
    # Expired forged handles are unadmitted, not cleanup acknowledgements.
    owner = handle.owner
    [companion] = Task.Supervisor.children(c.supervisor) -- [owner]
    owner_monitor = Process.monitor(owner)
    companion_monitor = Process.monitor(companion)
    assert handle.deadline == @now + 900_000
    Agent.update(c.state, &Map.put(&1, :now, handle.deadline - 1))
    assert {:ok, @body} = export(c, :read_chunk, [handle, note_path(), 0])
    assert handle.deadline == @now + 900_000
    Agent.update(c.state, &Map.put(&1, :now, handle.deadline))
    forged = %{handle | deadline: handle.deadline + 900_000}
    assert {:error, %Error{}} = export(c, :entries, [forged, nil])
    # Observe autonomous expiry cleanup independently of the denied request.
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _}, 5_000
    assert_receive {:DOWN, ^companion_monitor, :process, ^companion, :normal}, 5_000
    assert_cleaned(c)
  end

  test "close is idempotent but never restores readable data", c do
    {handle, _requester} = generate_from_requester(c)
    assert :ok = export(c, :close, [handle])
    assert_cleaned(c)
    assert :ok = export(c, :close, [handle])
    assert {:error, %Error{}} = export(c, :entries, [handle, nil])
    assert {:error, %Error{}} = export(c, :read_chunk, [handle, note_path(), 0])
    assert_cleaned(c)
  end

  # Recovery below still uses SYNTHETIC authority/COMMIT. Only actual fixture
  # task lifetime, Writer files/ETS, envelope identity and cleanup are witnessed.
  for point <- [:during_capture, :before_completion] do
    @recovery_point point
    test "companion death at #{@recovery_point} waits for the blocked owner then removes its envelope",
         c do
      set_barrier(c, @recovery_point)
      {_requester, requester_monitor} = start_requester(c)
      ref = c.context.ref
      assert_receive {:artifact_barrier, ^ref, @recovery_point, owner}, 5_000
      [companion] = Task.Supervisor.children(c.supervisor) -- [owner]
      root = capture_root!(c)
      owned_sentinel = Path.join(root, "blocked-owner-sentinel")
      File.write!(owned_sentinel, "owner still holds this envelope")
      trace_owner(c, owner)
      owner_monitor = Process.monitor(owner)
      companion_monitor = Process.monitor(companion)
      Process.exit(companion, :kill)
      assert_receive {:DOWN, ^companion_monitor, :process, ^companion, :killed}, 5_000

      # A blocked real callback is not interruptible. No deletion is permitted
      # while it still owns the producer, even after the companion is gone.
      assert Process.alive?(owner)
      assert File.read!(owned_sentinel) == "owner still holds this envelope"
      queue_unrelated_recovery_messages(owner, companion, make_ref())
      send(owner, {:release_artifact_barrier, ref})
      {_replacement, replacement_monitor} = await_cleanup_replacement!(owner)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _}, 5_000
      assert_receive {:DOWN, ^replacement_monitor, :process, _, reason}, 5_000
      assert reason in [:normal, :noproc]
      assert_receive {:DOWN, ^requester_monitor, :process, _, _}, 5_000
      refute_received {:export_result, ^ref, {:ok, _}}
      assert {:error, :enoent} = File.lstat(root)
      assert_cleaned(c)
    end
  end

  test "accepted companion loss after requester exit preserves an independent real export", c do
    {handle, requester} = generate_from_requester(c)
    refute Process.alive?(requester)
    first_root = capture_root!(c)
    [companion] = Task.Supervisor.children(c.supervisor) -- [handle.owner]
    {independent, independent_requester} = generate_from_requester(c)
    refute Process.alive?(independent_requester)
    independent_root = capture_root!(c)
    refute independent_root == first_root
    assert {:ok, @body} = export(c, :read_chunk, [independent, note_path(), 0])

    trace_owner(c, handle.owner)
    owner_monitor = Process.monitor(handle.owner)
    companion_monitor = Process.monitor(companion)
    queue_unrelated_recovery_messages(handle.owner, companion, handle.operation_ref)
    Process.exit(companion, :kill)
    assert_receive {:DOWN, ^companion_monitor, :process, ^companion, :killed}, 5_000

    {replacement, replacement_monitor} =
      await_cleanup_replacement!(handle.owner, handle.operation_ref)

    refute replacement in [handle.owner, companion, independent.owner]
    owner = handle.owner
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _}, 5_000
    assert_receive {:DOWN, ^replacement_monitor, :process, ^replacement, reason}, 5_000
    assert reason in [:normal, :noproc]
    assert {:error, :enoent} = File.lstat(first_root)
    assert File.dir?(independent_root)
    assert Process.alive?(independent.owner)
    assert {:ok, @body} = export(c, :read_chunk, [independent, note_path(), 0])
    assert {:error, %Error{}} = export(c, :entries, [handle, nil])
    assert_sentinels(c)
    assert :ok = export(c, :close, [independent])
    assert_cleaned(c)
  end

  test "cleanup replacement refuses a foreign marker identity without deleting it", c do
    set_barrier(c, :during_capture)
    {_requester, requester_monitor} = start_requester(c)
    ref = c.context.ref
    assert_receive {:artifact_barrier, ^ref, :during_capture, owner}, 5_000
    [companion] = Task.Supervisor.children(c.supervisor) -- [owner]
    root = capture_root!(c)
    marker = Path.join(root, ".ownership")
    File.rename!(marker, Path.join(root, "original-marker-held-by-fixture"))
    File.write!(marker, "foreign replacement must remain")
    trace_owner(c, owner)
    owner_monitor = Process.monitor(owner)
    companion_monitor = Process.monitor(companion)
    Process.exit(companion, :kill)
    assert_receive {:DOWN, ^companion_monitor, :process, ^companion, :killed}, 5_000
    send(owner, {:release_artifact_barrier, ref})
    {replacement, replacement_monitor} = await_cleanup_replacement!(owner)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _}, 5_000
    assert_receive {:DOWN, ^replacement_monitor, :process, ^replacement, reason}, 5_000
    # :noproc explicitly means the late monitor did NOT witness the exit reason.
    # The unchanged foreign marker independently proves actual identity refusal.
    assert reason in [{:shutdown, :export_cleanup_failed}, :noproc]
    assert_receive {:DOWN, ^requester_monitor, :process, _, _}, 5_000
    refute_received {:export_result, ^ref, {:ok, _}}
    assert File.read!(marker) == "foreign replacement must remain"
    assert File.dir?(root)
    assert_sentinels(c)
  end

  test "replacement capacity failure closes the owner without claiming envelope cleanup", c do
    supervisor = start_supervised!({Task.Supervisor, max_children: 2}, id: :recovery_capacity)
    runtime = put_in(c.runtime, [:knowledge_export, :task_supervisor], supervisor)
    c = %{c | runtime: runtime, supervisor: supervisor}
    set_barrier(c, :during_capture)
    {_requester, requester_monitor} = start_requester(c)
    ref = c.context.ref
    assert_receive {:artifact_barrier, ^ref, :during_capture, owner}, 5_000
    [companion] = Task.Supervisor.children(supervisor) -- [owner]
    root = capture_root!(c)
    trace_owner(c, owner)
    owner_monitor = Process.monitor(owner)
    companion_monitor = Process.monitor(companion)
    Process.exit(companion, :kill)
    assert_receive {:DOWN, ^companion_monitor, :process, ^companion, :killed}, 5_000
    assert Task.Supervisor.terminate_child(supervisor, companion) in [:ok, {:error, :not_found}]
    observer = self()

    {:ok, sentinel} =
      Task.Supervisor.start_child(supervisor, fn ->
        send(observer, {:capacity_sentinel_ready, ref, self()})

        receive do
          {:stop_capacity_sentinel, ^ref} -> :ok
        end
      end)

    assert_receive {:capacity_sentinel_ready, ^ref, ^sentinel}, 5_000
    send(owner, {:release_artifact_barrier, ref})

    assert_receive {:DOWN, ^owner_monitor, :process, ^owner,
                    {:shutdown, :export_cleanup_unavailable}},
                   5_000

    assert_receive {:DOWN, ^requester_monitor, :process, _, _}, 5_000
    refute_received {:export_result, ^ref, {:ok, _}}
    assert File.dir?(root)
    assert Process.alive?(sentinel)
    assert_sentinels(c)
    sentinel_monitor = Process.monitor(sentinel)
    send(sentinel, {:stop_capacity_sentinel, ref})
    assert_receive {:DOWN, ^sentinel_monitor, :process, ^sentinel, :normal}, 5_000
  end

  # BEGIN Task16 actual supervisor shutdown witness
  test "actual task supervisor shutdown terminates the owner without starting recovery", c do
    {handle, _requester} = generate_from_requester(c)
    owner = handle.owner
    supervisor = c.supervisor
    [companion] = Task.Supervisor.children(supervisor) -- [owner]
    [ledger] = owner_ledgers(owner)
    root = capture_root!(c)
    assert File.dir?(root)
    trace_owner(c, owner)
    owner_monitor = Process.monitor(owner)
    companion_monitor = Process.monitor(companion)
    supervisor_monitor = Process.monitor(supervisor)

    # This supported call sends the real supervisor-origin shutdown, using its
    # unchanged default child policy. No forged EXIT or timeout extension.
    assert :ok = Task.Supervisor.terminate_child(supervisor, owner)
    assert_receive {:trace, ^owner, :receive, {:EXIT, ^supervisor, :shutdown}}, 5_000
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :shutdown}, 5_000
    assert_receive {:DOWN, ^companion_monitor, :process, ^companion, :normal}, 5_000
    refute_received {:trace, ^owner, :receive, {_reply_ref, {:ok, _replacement}}}
    refute_received {:trace, ^owner, :receive, {:export_cleanup_ready, _, _, _}}
    assert :ets.info(ledger) == :undefined
    assert {:error, :enoent} = File.lstat(root)
    # Fence the already-dead exact child registration before querying the tree.
    assert Task.Supervisor.terminate_child(supervisor, companion) in [:ok, {:error, :not_found}]
    assert Task.Supervisor.children(supervisor) == []
    assert :ok = stop_supervised(Task.Supervisor)
    assert_receive {:DOWN, ^supervisor_monitor, :process, ^supervisor, :shutdown}, 5_000
    assert_cleaned(c)
  end

  # END Task16 actual supervisor shutdown witness

  # Terminal-close authority is still SYNTHETIC; owner DOWN, Writer/ETS and
  # permission-refused envelope cleanup below use the actual fixture processes.
  test "first close waits for owner DOWN and cleanup while repeat close reloads current authority",
       c do
    {handle, _requester} = generate_from_requester(c)
    owner = handle.owner
    [companion] = Task.Supervisor.children(c.supervisor) -- [owner]
    [ledger] = owner_ledgers(owner)
    owner_monitor = Process.monitor(owner)
    companion_monitor = Process.monitor(companion)
    root = capture_root!(c)

    assert :ok = export(c, :close, [handle])
    assert_received {:DOWN, ^owner_monitor, :process, ^owner, _}
    assert_received {:DOWN, ^companion_monitor, :process, ^companion, :normal}
    assert :ets.info(ledger) == :undefined
    assert File.lstat(root) == {:error, :enoent}
    assert_cleaned(c)

    Agent.update(c.state, &Map.put(&1, :events, []))
    assert :ok = export(c, :close, [handle])
    assert authority_count(c) > 0
    refute Process.alive?(owner)
    assert {:error, %Error{}} = export(c, :entries, [handle, nil])
    assert {:error, %Error{}} = export(c, :read_chunk, [handle, note_path(), 0])
    assert_cleaned(c)
  end

  test "dead-owner close is a current-authority no-op and never accepts a foreign identity", c do
    {handle, _requester} = generate_from_requester(c)
    owner = handle.owner
    monitor = Process.monitor(owner)
    assert :ok = export(c, :close, [handle])
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 5_000

    for {change, code} <- [
          {%{session_revoked_at: ~U[2026-10-19 00:00:00Z]}, :unauthenticated},
          {%{principal_revoked_at: ~U[2026-10-19 00:00:00Z]}, :forbidden},
          {%{membership_revoked_at: ~U[2026-10-19 00:00:00Z]}, :forbidden},
          {%{principal_authorization_epoch: 8}, :forbidden},
          {%{vault_authorization_epoch: 24}, :forbidden},
          {%{capabilities: []}, :forbidden},
          {%{vault_locked: true}, :vault_locked}
        ] do
      Agent.update(c.state, &%{&1 | live: Map.merge(live(c.session), change), events: []})
      assert_error(export(c, :close, [handle]), code)
      assert authority_count(c) > 0
      assert_cleaned(c)
    end

    Agent.update(c.state, &Map.put(&1, :live, live(c.session)))

    for session <- [
          %{c.session | session_id: @foreign},
          %{c.session | principal_id: @foreign},
          %{c.session | vault_id: @foreign},
          %{c.session | principal_authorization_epoch: 8, authorization_epoch: 8},
          %{c.session | vault_authorization_epoch: 24}
        ] do
      assert_error(export(c, :close, [handle], session), :forbidden)
      assert_cleaned(c)
    end
  end

  test "in-flight close cleanup failure is not converted to dead-owner success", c do
    {handle, _requester} = generate_from_requester(c)
    owner = handle.owner
    monitor = Process.monitor(owner)
    root = capture_root!(c)
    blocked = Path.join(root, "permission-refused-envelope-child")
    File.mkdir!(blocked)
    File.write!(Path.join(blocked, "retained"), "unremoved fixture residue")
    File.chmod!(blocked, 0o000)
    on_exit(fn -> File.chmod(blocked, 0o700) end)
    assert File.ls(blocked) == {:error, :eacces}

    assert_error(export(c, :close, [handle]), :storage_unavailable)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 5_000
    assert File.dir?(root)
    assert File.dir?(blocked)
    assert_sentinels(c)

    File.chmod!(blocked, 0o700)
    assert File.read!(Path.join(blocked, "retained")) == "unremoved fixture residue"
    Agent.update(c.state, &Map.put(&1, :events, []))
    assert :ok = export(c, :close, [handle])
    assert authority_count(c) > 0
    assert File.read!(Path.join(blocked, "retained")) == "unremoved fixture residue"
    assert_sentinels(c)
  end

  test "a changed live operation reference or deadline cannot read or close its original owner",
       c do
    {handle, _requester} = generate_from_requester(c)

    for forged <- [
          %{handle | operation_ref: make_ref()},
          %{handle | deadline: handle.deadline - 1},
          %{handle | deadline: handle.deadline + 1}
        ] do
      assert_error(export(c, :entries, [forged, nil]), :forbidden)
      assert_error(export(c, :read_chunk, [forged, note_path(), 0]), :forbidden)
      assert_error(export(c, :close, [forged]), :forbidden)
      assert Process.alive?(handle.owner)
      assert {:ok, @body} = export(c, :read_chunk, [handle, note_path(), 0])
      assert_sentinels(c)
    end

    assert :ok = export(c, :close, [handle])
    assert_cleaned(c)
  end

  def sealed_fixture!(spool) do
    {:ok, note} =
      NoteSnapshot.initial(%{classification: :private, title: "Owned note", markdown: @body})

    {:ok, path} = KnowledgeExport.path(:note, @resource, @version, nil)

    version =
      ~w(resource_id version_id revision kind inserted_at availability body_path original_path extracted_path body_digest original_digest original_byte_size extracted_digest media_type state extraction_adapter extraction_format parent_version_id merge_parent_version_id)
      |> Map.new(&{&1, nil})
      |> Map.merge(%{
        "resource_id" => @resource,
        "version_id" => @version,
        "revision" => 0,
        "kind" => "note",
        "inserted_at" => "2026-10-19T00:00:00.000000Z",
        "availability" => "included",
        "body_path" => path,
        "body_digest" => sha(note.markdown)
      })

    resource = %{
      "id" => @resource,
      "kind" => "note",
      "title" => note.title,
      "current_version_id" => @version,
      "deleted_at" => nil,
      "selection_reason" => "head"
    }

    {:ok, spool} = Spool.append(spool, {:metadata, :resources}, resource)
    {:ok, spool} = Spool.append(spool, {:metadata, :versions}, version)
    {:ok, spool} = Spool.append(spool, {:note_markdown, @resource, @version}, note.markdown)

    {:ok, spool} =
      Spool.append(spool, {:render_descriptions, @resource, @version}, %{
        attachments: [],
        citations: []
      })

    {:ok, capture} = Spool.seal(spool)
    capture
  end

  def record(context, event),
    do: Agent.update(context.state, &Map.update!(&1, :events, fn events -> [event | events] end))

  def barrier(context, point) do
    admit =
      Agent.get_and_update(context.state, fn state ->
        if state.barrier == point and not state.barrier_fired,
          do: {true, %{state | barrier_fired: true}},
          else: {false, state}
      end)

    if admit do
      send(context.observer, {:artifact_barrier, context.ref, point, self()})

      receive do
        {:release_artifact_barrier, ref} when ref == context.ref -> :ok
      after
        5_000 -> raise "artifact fixture barrier not released"
      end
    end

    :ok
  end

  def completed_writer?(context) do
    case Agent.get(context.state, & &1.capture_root) do
      nil -> false
      root -> Enum.any?(File.ls!(root), &String.ends_with?(&1, ".complete"))
    end
  end

  def resource_id, do: @resource
  def version_id, do: @version
  def body, do: @body
  def sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp export(c, function, arguments, session \\ nil),
    do: apply(@export, function, [c.runtime, session || c.session | arguments])

  defp start_requester(c) do
    parent = self()
    ref = c.context.ref
    spawn_monitor(fn -> send(parent, {:export_result, ref, export(c, :run, [%{}])}) end)
  end

  defp generate_from_requester(c) do
    {requester, monitor} = start_requester(c)
    ref = c.context.ref
    assert_receive {:export_result, ^ref, {:ok, handle}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^requester, :normal}, 5_000
    {handle, requester}
  end

  defp owner_ledgers(owner) do
    Enum.filter(:ets.all(), fn table ->
      :ets.info(table, :owner) == owner and :ets.info(table, :name) == Writer
    end)
  end

  defp set_barrier(c, point),
    do: Agent.update(c.state, &%{&1 | barrier: point, barrier_fired: false})

  defp capture_root!(c) do
    root = Agent.get(c.state, & &1.capture_root)
    assert is_binary(root)
    assert File.dir?(root)
    root
  end

  defp queue_unrelated_recovery_messages(owner, companion, operation_ref) do
    send(owner, {:export_cleanup_ready, make_ref(), make_ref(), self()})
    send(owner, {:export_cleanup_ready, operation_ref, make_ref(), self()})
    send(owner, {:export_cleanup_ready, operation_ref})
    send(owner, {:EXIT, companion, :killed})
    send(owner, {:DOWN, make_ref(), :process, companion, :killed})
  end

  defp trace_owner(_c, owner) do
    assert :erlang.trace(owner, true, [:receive, {:tracer, self()}]) == 1

    on_exit(fn ->
      if Process.alive?(owner), do: :erlang.trace(owner, false, [:receive])
    end)
  end

  defp await_cleanup_replacement!(owner, expected_operation_ref \\ nil) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    collect_cleanup_witness(owner, expected_operation_ref, deadline, nil, nil)
  end

  defp collect_cleanup_witness(owner, operation_ref, deadline, started, ready) do
    case {started, ready} do
      {{replacement, monitor}, {observed_operation, recovery_ref, replacement}}
      when is_reference(recovery_ref) and
             (is_nil(operation_ref) or observed_operation == operation_ref) ->
        {replacement, monitor}

      _ ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {:trace, ^owner, :receive, {reply_ref, {:ok, replacement}}}
          when is_reference(reply_ref) and is_pid(replacement) ->
            monitor = Process.monitor(replacement)
            collect_cleanup_witness(owner, operation_ref, deadline, {replacement, monitor}, ready)

          {:trace, ^owner, :receive,
           {:export_cleanup_ready, observed_operation, recovery_ref, replacement}}
          when is_reference(observed_operation) and is_reference(recovery_ref) and
                 is_pid(replacement) ->
            # A readiness-shaped message alone never identifies a replacement.
            # Retain only fixed control references/PIDs, never runtime payloads.
            candidate = {observed_operation, recovery_ref, replacement}
            collect_cleanup_witness(owner, operation_ref, deadline, started, candidate)

          {:trace, ^owner, :receive, _discarded_control_or_payload} ->
            collect_cleanup_witness(owner, operation_ref, deadline, started, ready)
        after
          remaining -> flunk("actual cleanup start-result/ready witness missing")
        end
    end
  end

  defp authority_count(c),
    do:
      Agent.get(c.state, fn state ->
        Enum.count(state.events, &match?({:live_authority, _, _}, &1))
      end)

  defp assert_error(result, code) do
    assert {:error, %Error{code: ^code, message: nil, details: details}} = result
    assert details == %{}
  end

  defp assert_cleaned(c) do
    assert File.ls!(c.roots.export) == ["foreign-sentinel"]
    assert_sentinels(c)
  end

  defp assert_sentinels(c) do
    assert File.read!(Path.join(c.roots.export, "foreign-sentinel")) == "foreign bytes"
    assert File.read!(Path.join(c.roots.storage, "storage-sentinel")) == "storage bytes"
    assert File.read!(Path.join(c.roots.backup, "backup-sentinel")) == "backup bytes"
  end

  defp note_path do
    {:ok, path} = KnowledgeExport.path(:note, @resource, @version, nil)
    path
  end

  defp live(session) do
    %{
      session_id: session.session_id,
      principal_id: session.principal_id,
      vault_id: session.vault_id,
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
  end
end
