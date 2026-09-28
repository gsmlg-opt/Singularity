defmodule Singularity.Ingest.Documents.Poppler do
  @moduledoc false

  alias ExCmd.Process, as: ExProcess

  @source_limit 67_108_864
  @text_limit 16_777_216
  @info_output_limit 65_536
  @timeout_ms 120_000
  @read_size 65_531
  @cleanup_reserve_ms 750
  @await_minimum_ms 50
  @minimum_timeout_ms @cleanup_reserve_ms + @await_minimum_ms
  @writer_close_grace_ms 50
  @frame_prefix <<"SGP", 1>>
  @password_required_diagnostic "Command Line Error: Incorrect password\n"

  @spec run(:info | :text, binary(), keyword()) ::
          {:ok, binary()}
          | :timeout
          | {:exit, non_neg_integer()}
          | {:error, atom() | {:unsupported, String.t()}}
  def run(kind, bytes, opts \\ []) when kind in [:info, :text] and is_binary(bytes) do
    with {:ok, executable} <- executable(kind) do
      run_command(kind, executable, bytes, opts)
    end
  end

  defp run_command(:info, executable, bytes, opts) do
    with {:ok, requested_limit} <- limit(opts, :output_limit, @text_limit, @text_limit) do
      opts = Keyword.put(opts, :output_limit, min(requested_limit, @info_output_limit))

      executable
      |> run_guarded_with_options(["-"], bytes, opts,
        env: [{"LC_ALL", "C"}],
        stderr: :redirect_to_stdout,
        include_exit_output?: true
      )
      |> classify_information()
    else
      :error -> {:error, :process_failed}
    end
  end

  defp run_command(:text, executable, bytes, opts) do
    run_guarded_with_options(
      executable,
      ["-enc", "UTF-8", "-eol", "unix", "-q", "-", "-"],
      bytes,
      opts,
      stderr: :disable
    )
  end

  defp classify_information({:exit, 1, @password_required_diagnostic}),
    do: {:error, {:unsupported, "encrypted_document"}}

  defp classify_information({:exit, 125, _diagnostic}),
    do: {:error, :process_failed}

  defp classify_information({:exit, _status, _diagnostic}),
    do: {:error, {:unsupported, "malformed_document"}}

  defp classify_information(result), do: result

  @doc false
  @spec run_guarded(binary(), [binary()], binary(), keyword()) ::
          {:ok, binary()} | :timeout | {:exit, non_neg_integer()} | {:error, atom()}
  def run_guarded(executable, args, input, opts \\ [])
      when is_binary(executable) and is_list(args) and is_binary(input) do
    run_guarded_with_options(executable, args, input, opts, stderr: :disable)
  end

  defp run_guarded_with_options(executable, args, input, opts, process_opts)
       when is_binary(executable) and is_list(args) and is_binary(input) do
    with {:ok, timeout_ms} <-
           limit(opts, :timeout_ms, @timeout_ms, @timeout_ms, @minimum_timeout_ms),
         {:ok, output_limit} <- limit(opts, :output_limit, @text_limit, @text_limit) do
      if byte_size(input) > @source_limit do
        {:error, :source_limit}
      else
        start_controller(executable, args, input, output_limit, timeout_ms, process_opts)
      end
    else
      :error -> {:error, :process_failed}
    end
  end

  defp limit(opts, key, default, maximum, minimum \\ 1) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= minimum and value <= maximum -> {:ok, value}
      _other -> :error
    end
  end

  defp start_controller(executable, args, input, output_limit, timeout_ms, process_opts) do
    if Path.type(executable) == :absolute and File.regular?(executable) do
      caller = self()
      ref = make_ref()

      {controller, controller_monitor} =
        spawn_monitor(fn ->
          control(caller, ref, executable, args, input, output_limit, timeout_ms, process_opts)
        end)

      receive do
        {^ref, :result, result} ->
          Process.demonitor(controller_monitor, [:flush])
          result

        {:DOWN, ^controller_monitor, :process, ^controller, _reason} ->
          {:error, :process_failed}
      end
    else
      {:error, :unavailable}
    end
  end

  defp control(caller, ref, executable, args, input, output_limit, timeout_ms, process_opts) do
    caller_monitor = Process.monitor(caller)
    guardian = Application.app_dir(:singularity_ingest, "priv/poppler_guardian")
    final_deadline = System.monotonic_time(:millisecond) + timeout_ms
    execution_deadline = final_deadline - @cleanup_reserve_ms

    with true <- Path.type(guardian) == :absolute and File.regular?(guardian),
         {:ok, process} <-
           ExProcess.start_link(
             [guardian, executable | args],
             Keyword.take(process_opts, [:env, :stderr])
           ) do
      transfer_pipes(
        caller,
        caller_monitor,
        ref,
        process,
        input,
        output_limit,
        execution_deadline,
        final_deadline,
        Keyword.get(process_opts, :include_exit_output?, false)
      )
    else
      _ -> send(caller, {ref, :result, {:error, :process_failed}})
    end
  end

  defp transfer_pipes(
         caller,
         caller_monitor,
         ref,
         process,
         input,
         output_limit,
         execution_deadline,
         final_deadline,
         include_exit_output?
       ) do
    controller = self()
    writer = spawn(fn -> pipe_writer(controller, process, input) end)
    reader = spawn(fn -> pipe_reader(controller, process, output_limit) end)
    writer_monitor = Process.monitor(writer)
    reader_monitor = Process.monitor(reader)

    with :ok <- ExProcess.change_pipe_owner(process, :stdin, writer),
         :ok <- ExProcess.change_pipe_owner(process, :stdout, reader) do
      send(writer, :start)
      send(reader, :start)

      await_pipes(%{
        caller: caller,
        caller_monitor: caller_monitor,
        notify?: true,
        ref: ref,
        process: process,
        execution_deadline: execution_deadline,
        final_deadline: final_deadline,
        include_exit_output?: include_exit_output?,
        mode: :running,
        writer: writer,
        writer_monitor: writer_monitor,
        writer_state: :pending,
        reader: reader,
        reader_monitor: reader_monitor,
        reader_state: :pending
      })
    else
      _ ->
        stop_pipe_owner(writer)
        stop_pipe_owner(reader)
        _ = bounded_await(process, final_deadline)
        send(caller, {ref, :result, {:error, :process_failed}})
    end
  end

  defp pipe_writer(controller, process, input) do
    receive do
      :start ->
        frame = [@frame_prefix, <<byte_size(input)::64-big>>, input]
        result = ExProcess.write(process, frame)
        send(controller, {:writer_ready, self(), result})

        if result == :ok do
          receive do
            {:close, close_ref} ->
              send(
                controller,
                {:writer_closed, self(), close_ref, ExProcess.close_stdin(process)}
              )
          end
        end
    end
  end

  defp pipe_reader(controller, process, limit) do
    receive do
      :start -> read_output(controller, process, limit, [], 0)
    end
  end

  defp read_output(controller, process, limit, chunks, size) do
    case ExProcess.read(process, @read_size) do
      {:ok, chunk} when size + byte_size(chunk) <= limit ->
        read_output(controller, process, limit, [chunk | chunks], size + byte_size(chunk))

      {:ok, _chunk} ->
        send(controller, {:reader_issue, self(), :output_limit})
        drain_output(controller, process, :output_limit)

      :eof ->
        output = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        send(controller, {:reader_done, self(), {:ok, output}})

      {:error, _reason} ->
        send(controller, {:reader_done, self(), {:error, :process_failed}})
    end
  end

  defp drain_output(controller, process, reason) do
    case ExProcess.read(process, @read_size) do
      {:ok, _chunk} -> drain_output(controller, process, reason)
      :eof -> send(controller, {:reader_done, self(), {:error, reason}})
      {:error, _reason} -> send(controller, {:reader_done, self(), {:error, :process_failed}})
    end
  end

  defp await_pipes(state) do
    deadline =
      case state.mode do
        :running -> state.execution_deadline
        {:closing, _result} -> state.final_deadline
      end

    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:writer_ready, pid, :ok} when pid == state.writer ->
        state |> Map.put(:writer_state, :ready) |> finish_or_continue()

      {:writer_ready, pid, {:error, _reason}} when pid == state.writer ->
        state |> Map.put(:writer_state, :failed) |> begin_close({:error, :process_failed})

      {:writer_closed, pid, _close_ref, result} when pid == state.writer ->
        writer_state = if result == :ok, do: :closed, else: :failed
        state |> Map.put(:writer_state, writer_state) |> finish_or_continue()

      {:reader_issue, pid, :output_limit} when pid == state.reader ->
        begin_close(state, {:error, :output_limit})

      {:reader_done, pid, result} when pid == state.reader ->
        state = Map.put(state, :reader_state, result)

        case state.mode do
          :running -> begin_close(state, normal_result(result))
          {:closing, _result} -> finish_or_continue(state)
        end

      {:force_writer_close, close_ref} ->
        state = force_writer_close(state, close_ref)
        finish_or_continue(state)

      {:DOWN, monitor, :process, pid, _reason}
      when monitor == state.caller_monitor and pid == state.caller ->
        state
        |> Map.put(:notify?, false)
        |> begin_close({:error, :process_failed})

      {:DOWN, monitor, :process, pid, _reason}
      when monitor == state.writer_monitor and pid == state.writer ->
        state = Map.put(state, :writer_state, :closed)

        case state.mode do
          :running -> begin_close(state, {:error, :process_failed})
          {:closing, _result} -> finish_or_continue(state)
        end

      {:DOWN, monitor, :process, pid, _reason}
      when monitor == state.reader_monitor and pid == state.reader ->
        state = Map.put(state, :reader_state, {:error, :process_failed})

        case state.mode do
          :running -> begin_close(state, {:error, :process_failed})
          {:closing, _result} -> finish_or_continue(state)
        end
    after
      remaining ->
        case state.mode do
          :running -> begin_close(state, :timeout)
          {:closing, _result} -> cleanup_failed(state)
        end
    end
  end

  defp normal_result({:ok, output}), do: {:normal, output}
  defp normal_result({:error, reason}), do: {:error, reason}

  defp begin_close(%{mode: {:closing, _existing_result}} = state, _new_result),
    do: finish_or_continue(state)

  defp begin_close(state, result) do
    close_ref = make_ref()
    send(state.writer, {:close, close_ref})
    Process.send_after(self(), {:force_writer_close, close_ref}, @writer_close_grace_ms)

    state
    |> Map.put(:mode, {:closing, result})
    |> Map.put(:close_ref, close_ref)
    |> finish_or_continue()
  end

  defp force_writer_close(%{close_ref: close_ref, writer_state: writer_state} = state, close_ref)
       when writer_state not in [:closed, :failed] do
    stop_pipe_owner(state.writer)
    Map.put(state, :writer_state, :closed)
  end

  defp force_writer_close(state, _close_ref), do: state

  defp finish_or_continue(%{mode: :running} = state), do: await_pipes(state)

  defp finish_or_continue(
         %{
           mode: {:closing, result},
           writer_state: writer_state,
           reader_state: reader_state
         } = state
       )
       when writer_state in [:closed, :failed] and reader_state != :pending do
    finish(state, result)
  end

  defp finish_or_continue(state), do: await_pipes(state)

  defp finish(state, requested_result) do
    result =
      case bounded_await(state.process, state.final_deadline) do
        {:ok, status} ->
          completed_result(requested_result, status, state.include_exit_output?)

        {:error, _reason} ->
          {:error, :process_failed}
      end

    stop_pipe_owner(state.writer)
    stop_pipe_owner(state.reader)
    notify(state, result)
  end

  defp completed_result({:normal, output}, 0, _include_exit_output?), do: {:ok, output}

  defp completed_result({:normal, output}, status, true),
    do: {:exit, status, output}

  defp completed_result({:normal, _output}, status, false), do: {:exit, status}
  defp completed_result(:timeout, _status, _include_exit_output?), do: :timeout

  defp completed_result({:error, reason}, _status, _include_exit_output?),
    do: {:error, reason}

  defp cleanup_failed(state) do
    stop_pipe_owner(state.writer)
    stop_pipe_owner(state.reader)
    _ = bounded_await(state.process, state.final_deadline)
    notify(state, {:error, :process_failed})
  end

  defp notify(%{notify?: true} = state, result),
    do: send(state.caller, {state.ref, :result, result})

  defp notify(_state, _result), do: :ok

  defp stop_pipe_owner(owner) do
    if Process.alive?(owner), do: Process.exit(owner, :kill)
  end

  defp bounded_await(process, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining >= @await_minimum_ms do
      ExProcess.await_exit(process, remaining)
    else
      {:error, :process_failed}
    end
  catch
    :exit, _reason -> {:error, :process_failed}
  end

  defp executable(kind) do
    name = if kind == :info, do: "pdfinfo", else: "pdftotext"
    key = {__MODULE__, name}

    case :persistent_term.get(key, :missing) do
      :missing ->
        resolved = resolve_executable(name)
        :persistent_term.put(key, resolved)
        resolved

      resolved ->
        resolved
    end
  end

  defp resolve_executable(name) do
    case System.find_executable(name) do
      path when is_binary(path) ->
        absolute = Path.expand(path)
        if Path.type(absolute) == :absolute, do: {:ok, absolute}, else: {:error, :unavailable}

      nil ->
        {:error, :unavailable}
    end
  end
end
