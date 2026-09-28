defmodule Singularity.Ingest.Documents.PDFTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Singularity.Ingest.Documents.{PDF, Poppler}

  @fixtures Path.expand("../../../fixtures/documents", __DIR__)

  defmodule FaultRunner do
    def run(:info, _bytes, opts), do: {:ok, Keyword.fetch!(opts, :info)}
    def run(:text, _bytes, opts), do: Keyword.fetch!(opts, :text)
  end

  defmodule ProbeRunner do
    def run(kind, _bytes, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:runner_called, kind})

      case kind do
        :info -> {:ok, "Pages: 1\n"}
        :text -> {:ok, "text\f"}
      end
    end
  end

  defmodule ClassificationRunner do
    def run(:info, _bytes, opts), do: Keyword.fetch!(opts, :result)
    def run(:text, _bytes, _opts), do: {:ok, "text\f"}
  end

  test "real Poppler preserves two pages and character provenance" do
    assert {:ok, [first, second]} = PDF.extract(fixture("two_pages.pdf"), runner: Poppler)
    assert %{page: 1, start_char: 0, end_char: first_end} = first.locator
    assert %{page: 2, start_char: 0, end_char: second_end} = second.locator
    assert first_end > 0 and second_end > 0
    assert first.text =~ "First page"
    assert second.text =~ "Second page"
  end

  test "real Poppler classifies encrypted PDF variants without exposing diagnostics" do
    for name <- ["encrypted.pdf", "encrypted_pdf20_xref_stream.pdf"] do
      parent = self()

      assert "" ==
               capture_io(:stderr, fn ->
                 send(parent, {:extraction_result, PDF.extract(fixture(name), runner: Poppler)})
               end)

      assert_receive {:extraction_result, {:error, {:unsupported, "encrypted_document"}}}
    end

    assert {:error, {:unsupported, "malformed_document"}} =
             PDF.extract(fixture("malformed.pdf"), runner: Poppler)
  end

  test "does not classify an arbitrary Encrypt token as an encrypted document" do
    for bytes <- [
          "%PDF-1.7\nthis is malformed /Encrypt 2 0 R\n%%EOF\n",
          "%PDF-1.7\ntrailer << /Root 1 0 R /Metadata [ /Encrypt 2 0 R ] >>\nstartxref\n0\n%%EOF\n",
          "%PDF-1.7\ntrailer << /Size 2 /Root 1 0 R /Encrypt 1 0 R >>\nstartxref\n0\n%%EOF\n",
          "%PDF-1.7\nCommand Line Error: Incorrect password\n/Encrypt 1 0 R\n%%EOF\n"
        ] do
      assert {:error, {:unsupported, "malformed_document"}} =
               PDF.extract(bytes, runner: Poppler)
    end
  end

  test "bounds pdfinfo diagnostics with the requested output limit" do
    assert {:error, {:unsupported, "output_too_large"}} =
             PDF.extract(fixture("encrypted.pdf"), runner: Poppler, output_limit: 38)
  end

  @tag :tmp_dir
  test "does not classify guardian internal failure as encrypted", %{tmp_dir: tmp_dir} do
    executable = Path.join(tmp_dir, "pdfinfo-internal-error")

    File.write!(
      executable,
      "#!/bin/sh\ncat >/dev/null\nprintf 'Command Line Error: Incorrect password\\n'\nexit 125\n"
    )

    File.chmod!(executable, 0o700)
    key = {Poppler, "pdfinfo"}
    previous = :persistent_term.get(key, :missing)

    on_exit(fn ->
      case previous do
        :missing -> :persistent_term.erase(key)
        value -> :persistent_term.put(key, value)
      end
    end)

    :persistent_term.put(key, {:ok, executable})

    assert {:error, {:failed, "extractor_failed"}} =
             PDF.extract("small", runner: Poppler)
  end

  test "real Poppler rejects a scanned or empty document" do
    assert {:error, {:unsupported, "no_extractable_text"}} =
             PDF.extract(fixture("empty.pdf"), runner: Poppler)
  end

  test "rejects source, page, and text limits" do
    assert {:error, {:unsupported, "source_too_large"}} =
             PDF.extract(:binary.copy("x", 67_108_865), runner: FaultRunner)

    assert {:error, {:unsupported, "page_limit_exceeded"}} =
             PDF.extract("small", runner: FaultRunner, info: "Pages: 4097\n", text: {:ok, "x\f"})

    assert {:error, {:unsupported, "output_too_large"}} =
             PDF.extract("small",
               runner: FaultRunner,
               info: "Pages: 1\n",
               text: {:ok, :binary.copy("x", 16_777_217)}
             )
  end

  test "rejects invalid UTF-8 and content-free extraction" do
    assert {:error, {:unsupported, "invalid_utf8"}} =
             PDF.extract("small",
               runner: FaultRunner,
               info: "Pages: 1\n",
               text: {:ok, <<255, 12>>}
             )

    assert {:error, {:unsupported, "no_extractable_text"}} =
             PDF.extract("small", runner: FaultRunner, info: "Pages: 1\n", text: {:ok, "\f"})
  end

  test "sanitizes timeout, exit, and stderr-bearing process failures" do
    for fault <- [:timeout, {:exit, 42}, {:error, "secret stderr content"}] do
      assert {:error, {:failed, code}} =
               PDF.extract("small", runner: FaultRunner, info: "Pages: 1\n", text: fault)

      assert code in ["extractor_timeout", "extractor_failed"]
      refute inspect(code) =~ "secret"
    end
  end

  test "passes through only approved runner classification codes" do
    for code <- [
          "encrypted_document",
          "malformed_document",
          "no_extractable_text",
          "source_too_large",
          "page_limit_exceeded",
          "output_too_large",
          "invalid_utf8",
          "invalid_input"
        ] do
      assert {:error, {:unsupported, ^code}} =
               PDF.extract("small",
                 runner: ClassificationRunner,
                 result: {:error, {:unsupported, code}}
               )
    end

    for code <- ["extractor_timeout", "extractor_failed"] do
      assert {:error, {:failed, ^code}} =
               PDF.extract("small",
                 runner: ClassificationRunner,
                 result: {:error, {:failed, code}}
               )
    end

    for fault <- [
          {:error, {:unsupported, "secret"}},
          {:error, {:failed, "secret"}},
          {:error, {:unsupported, %{code: "encrypted_document"}}},
          {:error, {:failed, ["extractor_timeout"]}},
          {:error, {:failed, {:nested, "extractor_timeout"}}}
        ] do
      assert {:error, {:failed, "extractor_failed"}} =
               PDF.extract("small", runner: ClassificationRunner, result: fault)
    end

    assert {:error, {:unsupported, "malformed_document"}} =
             PDF.extract("small", runner: ClassificationRunner, result: {:exit, 1})
  end

  @tag :tmp_dir
  test "invalid or excessive runner limits fail closed without spawning", %{tmp_dir: tmp_dir} do
    marker = Path.join(tmp_dir, "spawned")
    args = ["-c", "touch \"$1\"", "limit-test", marker]

    for opts <- [
          [timeout_ms: 0],
          [timeout_ms: 799],
          [timeout_ms: -1],
          [timeout_ms: "120000"],
          [timeout_ms: 120_001],
          [output_limit: 0],
          [output_limit: -1],
          [output_limit: "16777216"],
          [output_limit: 16_777_217]
        ] do
      assert {:error, :process_failed} = Poppler.run_guarded("/bin/sh", args, <<>>, opts)
      refute File.exists?(marker)
    end
  end

  test "PDF does not forward excessive runner limits" do
    for opts <- [[timeout_ms: 799], [timeout_ms: 120_001], [output_limit: 16_777_217]] do
      assert {:error, {:failed, "extractor_failed"}} =
               PDF.extract("small", [runner: ProbeRunner, test_pid: self()] ++ opts)

      refute_receive {:runner_called, _kind}
    end
  end

  @tag :linux
  test "guardian accepts one framed payload and rejects malformed frames before exec" do
    cat =
      case System.find_executable("cat") do
        executable when is_binary(executable) -> executable
        nil -> flunk("cat executable is required for the guardian protocol test")
      end

    assert {0, "hello"} = run_guardian_frame(frame("hello"), cat, [], false)

    for malformed <- [
          <<"SGP", 2, 0::64>>,
          <<"SGP", 1, 67_108_865::64-big>>,
          <<"SGP", 1, 4::64-big, "no">>
        ] do
      {status, output} =
        run_guardian_frame(malformed, "/bin/sh", ["-c", "printf target-started"], true)

      refute status == 0
      assert output == ""
    end
  end

  @tag :linux
  @tag :tmp_dir
  test "guardian rejects a short declared payload before starting the target", %{tmp_dir: tmp_dir} do
    marker = Path.join(tmp_dir, "target-started")
    short_frame = <<"SGP", 1, 4::64-big, "no">>

    for _ <- 1..20 do
      {status, output} =
        run_guardian_frame(
          short_frame,
          "/bin/sh",
          ["-c", "touch \"$1\"", "guardian-test", marker],
          true
        )

      refute status == 0
      assert output == ""
      refute File.exists?(marker)
    end
  end

  @tag :linux
  test "guardian timeout terminates the target and a TERM-ignoring setsid escapee" do
    for _iteration <- 1..5 do
      pid_dir = temp_pid_dir!()
      started_at = System.monotonic_time(:millisecond)

      assert :timeout =
               Poppler.run_guarded("/bin/sh", spawning_target_args(pid_dir), <<>>,
                 timeout_ms: 1_600
               )

      elapsed = System.monotonic_time(:millisecond) - started_at
      assert elapsed >= 950
      assert elapsed <= 1_600
      assert_process_tree_gone(pid_dir)
    end
  end

  @tag :linux
  test "caller cancellation terminates the target and a TERM-ignoring setsid escapee" do
    for _iteration <- 1..5 do
      pid_dir = temp_pid_dir!()
      parent = self()

      {caller, monitor} =
        spawn_monitor(fn ->
          send(parent, :runner_started)

          Poppler.run_guarded("/bin/sh", spawning_target_args(pid_dir), <<>>, timeout_ms: 30_000)
        end)

      assert_receive :runner_started
      await_pid_files(pid_dir)
      cancelled_at = System.monotonic_time(:millisecond)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
      assert_process_tree_gone(pid_dir)

      elapsed = System.monotonic_time(:millisecond) - cancelled_at
      assert elapsed <= 1_050
    end
  end

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp frame(payload), do: <<"SGP", 1, byte_size(payload)::64-big, payload::binary>>

  defp run_guardian_frame(frame, executable, args, close_after_write?) do
    guardian = Application.app_dir(:singularity_ingest, "priv/poppler_guardian")
    {:ok, process} = ExCmd.Process.start_link([guardian, executable | args], stderr: :disable)
    :ok = ExCmd.Process.write(process, frame)
    if close_after_write?, do: :ok = ExCmd.Process.close_stdin(process)
    output = read_all(process, [])
    if not close_after_write?, do: :ok = ExCmd.Process.close_stdin(process)
    {:ok, status} = ExCmd.Process.await_exit(process, 2_000)
    {status, output}
  end

  defp read_all(process, chunks) do
    case ExCmd.Process.read(process, 65_531) do
      {:ok, chunk} -> read_all(process, [chunk | chunks])
      :eof -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp temp_pid_dir! do
    path =
      Path.join(System.tmp_dir!(), "singularity-guardian-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp spawning_target_args(pid_dir) do
    child = Path.join(pid_dir, "child")
    grandchild = Path.join(pid_dir, "grandchild")
    escapee = Path.join(pid_dir, "escapee")
    setsid = System.find_executable("setsid") || flunk("setsid executable is required")

    [
      "-c",
      "echo $$ > \"$1\"; sleep 60 & echo $! > \"$2\"; \"$3\" /bin/sh -c 'trap \"\" TERM; echo $$ > \"$1\"; exec sleep 60' guardian-escape \"$4\" & wait",
      "guardian-test",
      child,
      grandchild,
      setsid,
      escapee
    ]
  end

  defp await_pid_files(pid_dir), do: eventually(fn -> read_pids(pid_dir) end)

  defp assert_process_tree_gone(pid_dir) do
    {child, grandchild, escapee} = await_pid_files(pid_dir)

    assert eventually(fn ->
             not process_alive?(child) and not process_alive?(grandchild) and
               not process_alive?(escapee)
           end)
  end

  defp read_pids(pid_dir) do
    with {:ok, child} <- File.read(Path.join(pid_dir, "child")),
         {:ok, grandchild} <- File.read(Path.join(pid_dir, "grandchild")),
         {:ok, escapee} <- File.read(Path.join(pid_dir, "escapee")),
         {child_pid, ""} <- Integer.parse(String.trim(child)),
         {grandchild_pid, ""} <- Integer.parse(String.trim(grandchild)),
         {escapee_pid, ""} <- Integer.parse(String.trim(escapee)) do
      {child_pid, grandchild_pid, escapee_pid}
    else
      _ -> false
    end
  end

  defp process_alive?(pid), do: File.exists?("/proc/#{pid}")

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: flunk("condition did not become true")

  defp eventually(fun, attempts) do
    case fun.() do
      false ->
        Process.sleep(20)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end
end
