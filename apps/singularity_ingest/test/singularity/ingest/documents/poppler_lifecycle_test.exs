defmodule Singularity.Ingest.Documents.PopplerLifecycleTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Singularity.Ingest.Documents.Poppler

  @moduletag :linux

  @script ~S"""
  exec 3<>"$4"
  printf '%s\n' "$$" > "$1"
  "$5" 60 &
  printf '%s\n' "$!" > "$2"
  "$6" "$7" -c 'trap "" TERM; printf "%s\n" "$$" > "$1"; exec "$2" 60' escape "$3" "$5" &
  IFS= read -r command <&3
  case "$command" in
    overflow) printf '%01025d' 0 ;;
    hold) : ;;
    *) exit 90 ;;
  esac
  wait
  """

  test "timeout reaps the observed native tree while target stdin is backpressured" do
    require_linux!()
    input = :binary.copy("x", 67_108_864)

    pipe_max_size =
      "/proc/sys/fs/pipe-max-size" |> File.read!() |> String.trim() |> String.to_integer()

    assert byte_size(input) > pipe_max_size

    # The guardian buffers the outer frame before forking. The unread, unresized
    # target pipe therefore backpressures the guardian's write to target stdin.
    qualify_tree(input, "hold", :timeout)
  end

  test "output overflow reaps the observed native tree including its TERM-ignoring escapee" do
    require_linux!()
    qualify_tree("", "overflow", {:error, :output_limit})
  end

  defp qualify_tree(input, command, expected) do
    sh = executable!("sh")
    sleep = executable!("sleep")
    setsid = executable!("setsid")
    mkfifo = executable!("mkfifo")
    suffix = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    directory = Path.join(System.tmp_dir!(), "poppler-lifecycle-#{suffix}")
    File.mkdir!(directory)
    key = {__MODULE__, directory}
    Process.put(key, %{owned: %{}, passed: false})

    try do
      paths = Map.new([:child, :grandchild, :escapee], &{&1, Path.join(directory, "#{&1}.pid")})
      fifo_path = Path.join(directory, "release.fifo")
      assert {"", 0} = System.cmd(mkfifo, [fifo_path])
      {:ok, fifo} = File.open(fifo_path, [:read, :write, :binary])

      try do
        supervisor = start_supervised!(Task.Supervisor)
        owner = self()
        result_ref = make_ref()

        args = [
          "-c",
          @script,
          "lifecycle",
          paths.child,
          paths.grandchild,
          paths.escapee,
          fifo_path,
          sleep,
          setsid,
          sh
        ]

        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            result = Poppler.run_guarded(sh, args, input, timeout_ms: 5000, output_limit: 1024)
            send(owner, {result_ref, result})
            result
          end)

        try do
          assert poll(fn -> tree_ready?(key, paths) end, 3000),
                 "native tree did not become observable: #{inspect(Process.get(key).owned)}"

          owned = Process.get(key).owned
          assert_topology(owned)
          assert :ok = IO.binwrite(fifo, command <> "\n")
          assert_receive {^result_ref, result}, 6000
          assert result == expected
          assert {:ok, ^expected} = Task.yield(task, 1000)

          assert poll(fn -> identities_absent?(owned) end, 1000),
                 "original native identities remain after #{inspect(result)}: #{inspect(owned)}"

          Process.put(key, %{owned: owned, passed: true})
        after
          Task.shutdown(task, :brutal_kill)
        end
      after
        File.close(fifo)
      end
    after
      finish_fixture(key, directory)
    end
  end

  defp require_linux! do
    assert {:unix, :linux} == :os.type()
    assert File.dir?("/proc/self"), "Linux procfs is required for native lifecycle qualification"
  end

  defp executable!(name) do
    path = System.find_executable(name)
    assert is_binary(path), "required executable is unavailable: #{name}"
    assert Path.type(path) == :absolute
    path
  end

  defp tree_ready?(key, paths) do
    Enum.each(paths, fn {name, path} ->
      if not Map.has_key?(Process.get(key).owned, name) do
        case File.read(path) do
          {:ok, contents} ->
            case Integer.parse(String.trim(contents)) do
              {pid, ""} when pid > 0 -> remember_identity(key, name, pid)
              _ -> :ok
            end

          {:error, :enoent} ->
            :ok

          {:error, reason} ->
            flunk("cannot read owned PID artifact #{path}: #{inspect(reason)}")
        end
      end
    end)

    case Process.get(key).owned do
      %{child: child} -> remember_identity(key, :guardian, child.ppid)
      _ -> :ok
    end

    owned = Process.get(key).owned

    map_size(owned) == 4 and
      Enum.all?(owned, fn {_name, identity} -> live_identity?(identity) end) and
      ignores_term?(owned.escapee.pid)
  end

  defp remember_identity(key, name, pid) do
    state = Process.get(key)

    unless Map.has_key?(state.owned, name) do
      case identity(pid) do
        nil -> :ok
        observed -> Process.put(key, %{state | owned: Map.put(state.owned, name, observed)})
      end
    end
  end

  defp identity(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, contents} ->
        [_, tail] = Regex.run(~r/^\d+ \(.*\) (.*)$/s, contents)
        fields = String.split(tail)

        %{
          pid: pid,
          state: Enum.at(fields, 0),
          ppid: fields |> Enum.at(1) |> String.to_integer(),
          pgrp: fields |> Enum.at(2) |> String.to_integer(),
          session: fields |> Enum.at(3) |> String.to_integer(),
          start_time: fields |> Enum.at(19) |> String.to_integer()
        }

      {:error, reason} when reason in [:enoent, :esrch] ->
        nil

      {:error, reason} ->
        flunk("cannot read /proc/#{pid}/stat: #{inspect(reason)}")
    end
  end

  defp live_identity?(original) do
    case identity(original.pid) do
      %{start_time: start_time, state: state} ->
        start_time == original.start_time and state not in ["Z", "X"]

      nil ->
        false
    end
  end

  defp ignores_term?(pid) do
    case File.read("/proc/#{pid}/status") do
      {:ok, contents} ->
        [_, mask] = Regex.run(~r/^SigIgn:\s*([[:xdigit:]]+)$/m, contents)
        (String.to_integer(mask, 16) &&& 0x4000) != 0

      {:error, reason} when reason in [:enoent, :esrch] ->
        false

      {:error, reason} ->
        flunk("cannot read /proc/#{pid}/status: #{inspect(reason)}")
    end
  end

  defp assert_topology(%{
         guardian: guardian,
         child: child,
         grandchild: grandchild,
         escapee: escapee
       }) do
    assert child.ppid == guardian.pid
    assert child.pgrp == child.pid
    assert grandchild.ppid == child.pid
    assert grandchild.pgrp == child.pgrp
    assert grandchild.session == child.session
    assert escapee.ppid == child.pid
    assert escapee.pgrp == escapee.pid
    assert escapee.session == escapee.pid
    refute escapee.session == child.session
    assert ignores_term?(escapee.pid)
  end

  defp identities_absent?(owned) do
    Enum.all?(owned, fn {_name, original} ->
      case identity(original.pid) do
        nil -> true
        current -> current.start_time != original.start_time
      end
    end)
  end

  defp poll(condition, timeout_ms) do
    poll_until(condition, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp poll_until(condition, deadline) do
    if condition.() do
      true
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining > 0 do
        Process.sleep(min(10, remaining))
        poll_until(condition, deadline)
      else
        false
      end
    end
  end

  defp finish_fixture(key, directory) do
    %{owned: owned, passed: passed} = Process.delete(key)

    if passed do
      File.rm_rf!(directory)
    else
      absent = poll(fn -> identities_absent?(owned) end, 2000)

      IO.warn(
        "native lifecycle qualification failed; artifacts preserved at #{directory}; " <>
          "observed identities absent: #{absent}; observed identities: #{inspect(owned)}; " <>
          "absence of any unobserved descendants is not proven"
      )
    end
  end
end
