defmodule Singularity.Runtime.UploadMessageStreamTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Core.StageRef
  alias Singularity.Runtime.Assets.UploadSession

  @wait 2_000
  @id "00000000-0000-4000-8000-000000000101"

  # Pure injected boundaries only: these tests do not open a repo, lock, key
  # lease, file or custodian. The stream itself always comes from UploadSession.
  defmodule Boundaries do
    def checkout(_context, callback), do: callback.()
    def with_shared_checked_out(_context, repo, _scope, callback), do: callback.(repo)
    def with_shared(_context, repo, _principal, _scope, callback), do: callback.(repo)
    def transact(_context, repo, _scope, callback), do: callback.(repo)
    def check(_context, _authorization, _repo, _session, _requirement), do: :ok

    def consume_grant_and_create_stage(_context, _repo, command) do
      {:ok,
       %{
         id: command.stage_id,
         asset_id: command.asset_id,
         storage_ref: command.storage_ref,
         state: :open,
         state_revision: 0
       }}
    end

    def record_sealed_stage(_context, _repo, command) do
      {:ok,
       %{
         asset: %{asset_id: command.asset_id, state: :uploaded, state_revision: 1},
         stage: %{id: command.stage_ref.stage_id, state: :sealed, state_revision: 1}
       }}
    end

    def mark_stage_abandoned(%{test: test, ref: ref}, _repo, command) do
      send(test, {:abandoned, ref, self(), command.failure_code})
      {:ok, %{id: command.stage_id, state: :abandoned, state_revision: 1}}
    end

    def abort_stage(%{test: test, ref: ref}, %StageRef{}) do
      send(test, {:aborted, ref, self()})
      :ok
    end
  end

  defmodule CaptureWriter do
    def stream_and_seal_stage(%{test: test, ref: ref} = context, _storage, upload, stream) do
      send(test, {:handoff, ref, self(), stream})

      receive do
        {:reduce, ^ref, initial, reducer} ->
          drive(context, upload, Enumerable.reduce(stream, initial, reducer))
      end
    end

    defp drive(%{test: test, ref: ref} = context, upload, result) do
      summary =
        case result do
          {:suspended, value, _continuation} -> {:suspended, value}
          other -> other
        end

      send(test, {:reduced, ref, self(), summary})
      parked(context, upload, result)
    end

    defp parked(%{test: test, ref: ref} = context, upload, result) do
      receive do
        {:resume, ^ref, accumulator} ->
          {:suspended, _value, continuation} = result
          drive(context, upload, continuation.(accumulator))

        {:inspect_message, ^ref, message} ->
          present =
            receive do
              ^message -> true
            after
              0 -> false
            end

          send(test, {:inspected, ref, self(), message, present})
          parked(context, upload, result)

        {:complete, ^ref, :error} ->
          {:error, Error.new(:invalid), upload.stage_ref}

        {:complete, ^ref, :sealed} ->
          {:done, _value} = result

          {:ok,
           %{
             stage_ref: upload.stage_ref,
             plaintext_byte_size: upload.expected_bytes,
             ciphertext_byte_size: upload.expected_bytes + 134,
             lookup_digest: :binary.copy(<<0xA1>>, 32),
             ciphertext_hash: :binary.copy(<<0xB2>>, 32),
             format_version: 1
           }}
      end
    end
  end

  test "actual writer handoff is a local function capturing only the session PID" do
    with_upload(fn %{stream: stream, session: session} ->
      assert is_function(stream, 2)
      assert {:module, UploadSession} = :erlang.fun_info(stream, :module)
      assert {:env, [^session]} = :erlang.fun_info(stream, :env)
    end)
  end

  test "initial halt is lazy and unsupported fast paths do not consume messages" do
    with_upload(fn fixture ->
      %{stream: stream, writer: writer, session: session, ref: run} = fixture
      chunk_ref = make_ref()
      chunk = {:"$upload_stream_chunk", session, chunk_ref, "unit"}
      finish = {:"$upload_stream_finish", session}

      with_trace(fixture, [chunk_ref], fn trace ->
        send(writer, chunk)
        send(writer, finish)
        implementation = Enumerable.impl_for(stream)
        assert {:error, ^implementation} = Enumerable.count(stream)
        assert {:error, ^implementation} = Enumerable.member?(stream, "unit")
        assert {:error, ^implementation} = Enumerable.slice(stream)
        send(writer, {:reduce, run, {:halt, :seed}, reducer(fixture)})
        assert_receive {:reduced, ^run, ^writer, {:halted, :seed}}, @wait
        assert trace_events(trace, writer) == []
        assert_message_preserved(fixture, chunk)
        assert_message_preserved(fixture, finish)
      end)
    end)
  end

  test "initial suspension preserves messages and resumes in the actual writer" do
    with_upload(fn fixture ->
      %{writer: writer, session: session, ref: run} = fixture
      chunk_ref = make_ref()

      with_trace(fixture, [chunk_ref], fn trace ->
        send(writer, {:"$upload_stream_chunk", session, chunk_ref, "first"})
        send(writer, {:"$upload_stream_finish", session})
        send(writer, {:reduce, run, {:suspend, :seed}, reducer(fixture)})
        assert_receive {:reduced, ^run, ^writer, {:suspended, :seed}}, @wait
        assert trace_events(trace, writer) == []
        send(writer, {:resume, run, {:cont, :seed}})
        assert_callback(fixture, "first")
        assert trace_events(trace, writer) == [boundary(fixture, :entered)]
        send(writer, {:return_callback, run, {:cont, :next}})
        assert_receive {:reduced, ^run, ^writer, {:done, :next}}, @wait

        assert trace_events(trace, writer) == [
                 boundary(fixture, :returning),
                 applied(fixture, chunk_ref)
               ]

        assert trace_events(trace, writer) == []
      end)
    end)
  end

  test "continue filters owner and unrelated messages and acknowledges only after return" do
    with_upload(fn fixture ->
      %{writer: writer, session: session, ref: run} = fixture
      chunk_ref = make_ref()
      wrong_ref = make_ref()
      wrong_chunk = {:"$upload_stream_chunk", self(), wrong_ref, "wrong"}
      wrong_finish = {:"$upload_stream_finish", self()}
      unrelated = {:unrelated_stream_fixture, run}

      with_trace(fixture, [chunk_ref, wrong_ref], fn trace ->
        Enum.each([wrong_chunk, wrong_finish, unrelated], &send(writer, &1))
        send(writer, {:"$upload_stream_chunk", session, chunk_ref, "right"})
        send(writer, {:"$upload_stream_finish", session})
        send(writer, {:reduce, run, {:cont, :seed}, reducer(fixture)})
        assert_callback(fixture, "right")
        assert trace_events(trace, writer) == [boundary(fixture, :entered)]
        send(writer, {:return_callback, run, {:cont, :next}})
        assert_receive {:reduced, ^run, ^writer, {:done, :next}}, @wait

        assert trace_events(trace, writer) == [
                 boundary(fixture, :returning),
                 applied(fixture, chunk_ref)
               ]

        assert trace_events(trace, writer) == []
        Enum.each([wrong_chunk, wrong_finish, unrelated], &assert_message_preserved(fixture, &1))
      end)
    end)
  end

  test "halt emits one halted ACK and retains the following chunk" do
    with_upload(fn fixture ->
      %{writer: writer, session: session, ref: run} = fixture
      chunk_ref = make_ref()
      next_ref = make_ref()
      next_chunk = {:"$upload_stream_chunk", session, next_ref, "next"}

      with_trace(fixture, [chunk_ref, next_ref], fn trace ->
        send(writer, {:"$upload_stream_chunk", session, chunk_ref, "first"})
        send(writer, next_chunk)
        send(writer, {:reduce, run, {:cont, :seed}, reducer(fixture)})
        assert_callback(fixture, "first")
        assert trace_events(trace, writer) == [boundary(fixture, :entered)]
        send(writer, {:return_callback, run, {:halt, :stopped}})
        assert_receive {:reduced, ^run, ^writer, {:halted, :stopped}}, @wait

        assert trace_events(trace, writer) == [
                 boundary(fixture, :returning),
                 halted(fixture, chunk_ref)
               ]

        assert_message_preserved(fixture, next_chunk)
        assert trace_events(trace, writer) == []
        send(writer, {:complete, run, :error})
        assert_abandoned(fixture, "invalid")
      end)
    end)
  end

  test "chunk suspension acknowledges once and resumes the same accumulator and reducer" do
    with_upload(fn fixture ->
      %{writer: writer, session: session, ref: run} = fixture
      first_ref = make_ref()
      second_ref = make_ref()

      with_trace(fixture, [first_ref, second_ref], fn trace ->
        send(writer, {:"$upload_stream_chunk", session, first_ref, "first"})
        send(writer, {:"$upload_stream_chunk", session, second_ref, "second"})
        send(writer, {:"$upload_stream_finish", session})
        send(writer, {:reduce, run, {:cont, :seed}, reducer(fixture)})
        assert_callback(fixture, "first")
        assert trace_events(trace, writer) == [boundary(fixture, :entered)]
        send(writer, {:return_callback, run, {:suspend, :saved}})
        assert_receive {:reduced, ^run, ^writer, {:suspended, :saved}}, @wait

        assert trace_events(trace, writer) == [
                 boundary(fixture, :returning),
                 applied(fixture, first_ref)
               ]

        assert trace_events(trace, writer) == []
        send(writer, {:resume, run, {:cont, :saved}})
        assert_callback(fixture, "second", :saved)
        assert trace_events(trace, writer) == [boundary(fixture, :entered)]
        send(writer, {:return_callback, run, {:cont, :done}})
        assert_receive {:reduced, ^run, ^writer, {:done, :done}}, @wait

        assert trace_events(trace, writer) == [
                 boundary(fixture, :returning),
                 applied(fixture, second_ref)
               ]

        assert trace_events(trace, writer) == []
      end)
    end)
  end

  test "public append and finish use the actual writer and existing sealed acknowledgement" do
    with_upload(fn fixture ->
      %{writer: writer, session: session, ref: run} = fixture
      task_supervisor = start_supervised!(Task.Supervisor)
      send(writer, {:reduce, run, {:cont, :seed}, reducer(fixture)})

      append =
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          UploadSession.append(session, "%PDF-unit")
        end)

      assert_callback(fixture, "%PDF-unit")
      send(writer, {:return_callback, run, {:cont, :processed}})
      assert :ok = Task.await(append, @wait)

      finish =
        Task.Supervisor.async_nolink(task_supervisor, fn -> UploadSession.finish(session) end)

      assert_receive {:reduced, ^run, ^writer, {:done, :processed}}, @wait
      send(writer, {:complete, run, :sealed})

      assert {:ok, %{asset: %{state: :uploaded}, stage: %{state: :sealed}}} =
               Task.await(finish, @wait)

      assert_closed(fixture)
    end)
  end

  for failure <- [:raise, :throw] do
    test "reducer #{failure} has no ACK and follows ordinary writer abandonment" do
      with_upload(fn fixture ->
        %{writer: writer, session: session, ref: run} = fixture
        chunk_ref = make_ref()

        with_trace(fixture, [chunk_ref], fn trace ->
          send(writer, {:"$upload_stream_chunk", session, chunk_ref, "unit"})
          send(writer, {:reduce, run, {:cont, :seed}, reducer(fixture)})
          assert_callback(fixture, "unit")
          assert trace_events(trace, writer) == [boundary(fixture, :entered)]
          send(writer, {:return_callback, run, unquote(failure)})
          assert_abandoned(fixture, "storage_unavailable")
          assert trace_events(trace, writer) == [boundary(fixture, :returning)]
          assert trace_events(trace, writer) == []
        end)
      end)
    end
  end

  defp reducer(%{test: test, ref: ref}) do
    fn chunk, accumulator ->
      send(test, {:callback_chunk, ref, self(), chunk, accumulator})
      send(test, {:stream_boundary, ref, self(), :entered})

      receive do
        {:return_callback, ^ref, result} ->
          send(test, {:stream_boundary, ref, self(), :returning})

          case result do
            :raise -> raise "inert stream fixture"
            :throw -> throw(:inert_stream_fixture)
            tagged -> tagged
          end
      end
    end
  end

  defp assert_callback(%{writer: writer, ref: ref}, chunk, accumulator \\ :seed) do
    assert_receive {:callback_chunk, ^ref, ^writer, ^chunk, ^accumulator}, @wait
    assert_receive {:stream_boundary, ^ref, ^writer, :entered}, @wait
  end

  defp assert_message_preserved(%{writer: writer, ref: ref}, message) do
    send(writer, {:inspect_message, ref, message})
    assert_receive {:inspected, ^ref, ^writer, ^message, true}, @wait
  end

  defp boundary(%{test: test, writer: writer, ref: ref}, phase),
    do: {test, {:stream_boundary, ref, writer, phase}}

  defp applied(%{session: session, writer: writer}, reference),
    do: {session, {:upload_chunk_applied, writer, reference}}

  defp halted(%{session: session, writer: writer}, reference),
    do: {session, {:upload_chunk_halted, writer, reference}}

  defp with_trace(%{test: test, writer: writer, session: owner, ref: ref}, references, callback) do
    trace = :trace.session_create(:upload_message_stream_unit, self(), [])
    on_exit(fn -> :trace.session_destroy(trace) end)

    try do
      acknowledgements =
        for reference <- references, kind <- [:upload_chunk_applied, :upload_chunk_halted] do
          {[owner, {kind, writer, reference}], [], [true]}
        end

      boundaries =
        for phase <- [:entered, :returning] do
          {[test, {:stream_boundary, ref, writer, phase}], [], [true]}
        end

      :trace.send(trace, acknowledgements ++ boundaries, [])
      assert :trace.process(trace, writer, true, [:send]) == 1
      callback.(trace)
    after
      assert :trace.session_destroy(trace)
    end
  end

  defp trace_events(trace, writer) do
    # OTP delivered/2 is a global delivery barrier, not a session identity.
    # :all also works after the exact owned writer has naturally exited.
    barrier = :trace.delivered(trace, :all)
    collect_trace(writer, barrier, [], System.monotonic_time(:millisecond) + @wait)
  end

  defp collect_trace(_writer, _barrier, events, _deadline) when length(events) > 16,
    do: flunk("unexpected owned writer trace volume")

  defp collect_trace(writer, barrier, events, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:trace, ^writer, :send, message, destination} ->
        collect_trace(writer, barrier, [{destination, message} | events], deadline)

      {:trace_delivered, :all, ^barrier} ->
        Enum.reverse(events)
    after
      remaining -> flunk("owned writer delivery barrier did not close")
    end
  end

  defp assert_abandoned(%{session: session, ref: ref} = fixture, code) do
    assert_receive {:aborted, ^ref, ^session}, @wait
    assert_receive {:abandoned, ^ref, ^session, ^code}, @wait
    assert_closed(fixture)
  end

  defp assert_closed(%{session: session, session_monitor: sm, writer: writer, writer_monitor: wm}) do
    assert_receive {:DOWN, ^sm, :process, ^session, :normal}, @wait
    assert_receive {:DOWN, ^wm, :process, ^writer, _reason}, @wait
  end

  defp with_upload(callback) do
    context = %{test: self(), ref: make_ref()}
    now = ~U[2026-10-14 00:00:00.000000Z]
    adapter = {Boundaries, context}

    runtime = %{
      request_repo: adapter,
      vault_lock: adapter,
      authorization_lock: adapter,
      scoped_repo: adapter,
      authorizer: adapter,
      authorization: :isolated_stream_unit,
      assets: adapter,
      stage_writer: {CaptureWriter, context},
      clock: fn -> now end
    }

    session_context = %{
      session_id: @id,
      principal_id: @id,
      vault_id: @id,
      principal_authorization_epoch: 1,
      vault_authorization_epoch: 1
    }

    grant =
      Map.merge(session_context, %{
        grant_id: @id,
        asset_id: @id,
        filename: "unit.pdf",
        byte_size: byte_size("%PDF-unit"),
        declared_media_type: "application/pdf",
        request_declared_media_type: "application/pdf",
        request_content_length: byte_size("%PDF-unit"),
        token_digest: :binary.copy(<<1>>, 32),
        csrf_token_digest: :binary.copy(<<2>>, 32),
        idempotency_key: "isolated-stream-unit",
        classification: :private,
        expires_at: DateTime.add(now, 600, :second)
      })

    upload = %{
      stage_id: @id,
      candidate_object_id: @id,
      key_domain_id: @id,
      domain_key_version_id: @id,
      storage_ref: @id,
      wrapper_algorithm: "aes_256_gcm",
      key_generation: 1,
      dek_wrapper: :binary.copy(<<3>>, 60),
      object_dek: :binary.copy(<<4>>, 32),
      domain_dedup_key: :binary.copy(<<5>>, 32)
    }

    session =
      start_supervised!(
        {UploadSession,
         runtime: runtime,
         session: session_context,
         grant: grant,
         owner: self(),
         storage: %{adapter: Boundaries, context: context},
         upload: upload}
      )

    session_monitor = Process.monitor(session)
    on_exit(fn -> assert_terminated(session) end)
    ref = context.ref

    try do
      assert_receive {:handoff, ^ref, writer, stream}, @wait
      writer_monitor = Process.monitor(writer)
      on_exit(fn -> assert_terminated(writer) end)

      fixture =
        Map.merge(context, %{
          session: session,
          session_monitor: session_monitor,
          writer: writer,
          writer_monitor: writer_monitor,
          stream: stream
        })

      try do
        assert {:ok, ^session} = UploadSession.await_ready(session)
        callback.(fixture)

        if Process.alive?(session) do
          assert :ok = UploadSession.abandon(session, :controller_aborted, @wait)
        end
      after
        # Earlier assertions may already have consumed the original DOWNs.
        # Fresh exact monitors also cover assertion failure with a held reducer.
        cleanup_session = Process.monitor(session)
        cleanup_writer = Process.monitor(writer)
        assert stop_supervised(UploadSession) in [:ok, {:error, :not_found}]
        assert_receive {:DOWN, ^cleanup_session, :process, ^session, _reason}, @wait
        assert_receive {:DOWN, ^cleanup_writer, :process, ^writer, _reason}, @wait
      end
    after
      # Exact supervised ownership supplies the assertion-failure fallback.
      assert stop_supervised(UploadSession) in [:ok, {:error, :not_found}]
    end
  end

  defp assert_terminated(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, @wait
  end
end
