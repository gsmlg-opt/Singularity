# Real Extractor Qualification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Close the bounded real-extractor evidence gaps in Phase 2 Task 15 without changing production behavior.

**Architecture:** Add three qualification tests and one image-only fixture to the existing PDF test contract. Add a separate two-test native lifecycle module with explicit descendant readiness and owned-process cleanup. The coordinator serializes verification and records only demonstrated evidence.

**Tech Stack:** Elixir/ExUnit, Core immutable values, existing Poppler/ExCmd guardian, Linux procfs, test-only POSIX shell and FIFO.

---

## Task 1: Freeze the scope and baseline

**Read:** `AGENTS.md`, the matching real-extractor qualification design, the current PDF adapter, Poppler controller, guardian C, Core fragmentation/completion values, existing PDF tests and Task 15 matrix.

- [x] Coordinator read the complete plan and design and self-reviewed them. Independent architecture review returned GO with exact normalized page-text assertions, now applied below. Parent test-only implementation GO issued under standing approval; no production repairs authorized.
- [x] Work only in `/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-2-import-extraction`. Preserve the unrelated untracked Runtime-outcomes plan.
- [x] Confirm the baseline and protected files before writing implementation:

```sh
git rev-parse HEAD
git status --short
sha256sum apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs
sha256sum apps/singularity_ingest/c_src/poppler_guardian.c
git diff d39ad93f257df3a6e01a87a420c7a034c888192b -- apps/*/lib apps/*/priv apps/*/c_src config mix.exs mix.lock devenv.nix Dockerfile
```

Parent-verified baseline: HEAD `d39ad93f257df3a6e01a87a420c7a034c888192b`; PDF SHA-256 `38302505e1266731e081141eef2d6565199349be08f446ed7efc2de49f843d0d`; guardian SHA-256 `c9232d53efa3280fb1d53fe7badcd317138e4ffe10425d4637d4d0f6af66d607`; no protected production diff. The coordinator already reports PDF baseline session 73785, exit 0, 19 tests, zero failures, 18.9 seconds. If checkout evidence differs, reconcile it before proceeding; do not present that earlier run as a new result.

- [x] Delegate Task 2 and Task 3 in parallel with disjoint ownership. Workers must not run Mix, manage services, write Git state, edit shared support, modify old native helpers, or alter the matrix.
- [x] This is qualification of existing behavior, so new assertions may pass on first execution. No artificial production red is required. A valid behavioral red stops the affected case and is not permission to repair production.

## Task 2: Add real PDF, Core composition, and privacy evidence

**Modify:** `apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs`.
**Create:** `apps/singularity_ingest/test/fixtures/documents/scanned_image_only.pdf`.

- [x] Add these imports/aliases and three tests inside the existing module, leaving all old tests and helpers intact:

```elixir
  import ExUnit.CaptureLog
  alias Singularity.Core.{DocumentCompletion, DocumentFragmentation, SourceLocator}

  test "real Poppler refuses a painted image-only scan without OCR" do
    bytes = fixture("scanned_image_only.pdf")
    assert bytes =~ "/Subtype /Image"
    assert bytes =~ "/Width 23 /Height 7"
    assert bytes =~ "/ColorSpace /DeviceGray"
    assert bytes =~ "/XObject << /Scan 5 0 R >>"
    assert bytes =~ "/Scan Do"
    refute bytes =~ "/Font"
    refute Regex.match?(~r/\b(?:BT|ET|Tj|TJ)\b/, bytes)

    assert {:error, {:unsupported, "no_extractable_text"}} =
             PDF.extract(bytes, runner: Poppler)
  end

  test "real PDF produces repeatable Core fragments and completion" do
    identity = %{
      resource_id: "00000000-0000-4000-8000-000000000001",
      resource_version_id: "00000000-0000-4000-8000-000000000002",
      owner_scope_id: "00000000-0000-4000-8000-000000000003",
      classification: :private
    }

    runs =
      for _ <- 1..2 do
        assert {:ok, [first, second] = blocks} =
                 PDF.extract(fixture("two_pages.pdf"), runner: Poppler)

        assert first.text == "First page"
        assert second.text == "Second page"

        for {block, page} <- Enum.with_index(blocks, 1) do
          assert block.locator == %{
                   version: 1,
                   kind: "pdf",
                   page: page,
                   start_char: 0,
                   end_char: String.length(block.text)
                 }
        end

        assert {:ok, fragments} =
                 DocumentFragmentation.build(identity, "application/pdf", blocks)

        assert [first_fragment, second_fragment] = fragments
        assert Enum.map(fragments, & &1.ordinal) == [0, 1]
        assert first_fragment.fragment_id != second_fragment.fragment_id

        for {fragment, block} <- Enum.zip(fragments, blocks) do
          assert Map.take(fragment, Map.keys(identity)) == identity
          assert fragment.text == block.text
          assert fragment.digest == :crypto.hash(:sha256, block.text)
          assert byte_size(fragment.fragment_id) == 64

          assert SourceLocator.to_map(fragment.locator) ==
                   Map.new(block.locator, fn {key, value} -> {Atom.to_string(key), value} end)
        end

        digest = :crypto.hash(:sha256, Enum.map(blocks, & &1.text))

        attrs =
          Map.merge(identity, %{
            generation: 1,
            outcome: :ready,
            adapter_name: "pdf",
            format_version: 1,
            finished_at: ~U[2026-10-09 00:00:00Z],
            media_type: "application/pdf",
            fragments: fragments,
            extracted_text_digest: digest
          })

        assert {:ok, completion} = DocumentCompletion.new(attrs)
        assert Map.take(completion, Map.keys(attrs)) == attrs
        assert completion.failure_code == nil
        assert completion.detected_language == nil
        {blocks, fragments, completion}
      end

    assert [first_run, second_run] = runs
    assert first_run == second_run
  end

  test "real PDF and adapter faults keep diagnostic content out of Logger and BEAM IO" do
    sentinel = "PRIVATE_PDF_DIAGNOSTIC_7A94"
    previous_level = :logger.get_primary_config().level
    :ok = :logger.set_primary_config(:level, :debug)
    owner = self()
    ref = make_ref()

    try do
      logs =
        capture_log([level: :debug, metadata: :all], fn ->
          stdout =
            capture_io(fn ->
              stderr =
                capture_io(:stderr, fn ->
                  for {name, code} <- [
                        {"encrypted.pdf", "encrypted_document"},
                        {"encrypted_pdf20_xref_stream.pdf", "encrypted_document"},
                        {"malformed.pdf", "malformed_document"},
                        {"empty.pdf", "no_extractable_text"},
                        {"scanned_image_only.pdf", "no_extractable_text"}
                      ] do
                    assert {:error, {:unsupported, ^code}} =
                             PDF.extract(fixture(name), runner: Poppler)
                  end

                  assert {:ok, [first, second]} =
                           PDF.extract(fixture("two_pages.pdf"), runner: Poppler)

                  assert first.text =~ "First page"
                  assert second.text =~ "Second page"

                  for fault <- [
                        {:error, {:unsupported, sentinel}},
                        {:error, {:failed, sentinel}},
                        {:error, {:failed, %{diagnostic: sentinel}}}
                      ] do
                    assert {:error, {:failed, "extractor_failed"}} =
                             PDF.extract("small", runner: ClassificationRunner, result: fault)
                  end

                  for {fault, code} <- [
                        {{:error, sentinel}, "extractor_failed"},
                        {:timeout, "extractor_timeout"},
                        {{:exit, 42}, "extractor_failed"}
                      ] do
                    assert {:error, {:failed, ^code}} =
                             PDF.extract("small",
                               runner: FaultRunner,
                               info: "Pages: 1\n",
                               text: fault
                             )
                  end
                end)

              send(owner, {ref, :stderr, stderr})
            end)

          send(owner, {ref, :stdout, stdout})
        end)

      assert logs == ""
      assert_receive {^ref, :stdout, ""}
      assert_receive {^ref, :stderr, ""}
    after
      :ok = :logger.set_primary_config(:level, previous_level)
    end
  end
```

- [x] After adding tests and fixture, the coordinator verified all 22 PDF cases in both complete 24-case owning-file runs. The standalone PDF command below was not separately repeated:

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs --seed 1208
```

- [x] Add the following literal fixture through apply_patch. Use ASCII and LF only. Its PDF 1.5 cross-reference stream avoids fixed-width classic records and preserves ordinary whitespace checks. Independent Astra repair review verified all six object offsets, seven decoded xref entries, stream lengths 33/324/100, total size 1,070 bytes, and startxref 820. The original CRLF proposal was withdrawn because apply_patch normalized its records. Compute and check lengths and offsets before applying the literal; do not regenerate the fixture during tests or change Git attributes/configuration.

```text
%PDF-1.5
1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj
2 0 obj
<< /Type /Pages /Kids [3 0 R] /Count 1 >>
endobj
3 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 250 90] /Resources << /XObject << /Scan 5 0 R >> >> /Contents 4 0 R >>
endobj
4 0 obj
<< /Length 33 >>
stream
q
230 0 0 70 10 10 cm
/Scan Do
Q
endstream
endobj
5 0 obj
<< /Type /XObject /Subtype /Image /Width 23 /Height 7 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length 324 >>
stream
FF00000000FFFF00000000FFFF000000FFFF00FFFFFF0000FFFFFFFFFF00FFFFFFFFFF00FFFFFF00FF0000FFFF0000FFFFFFFFFF00FFFFFFFFFF00FFFFFF00FF0000FFFF00FF000000FFFF00FFFFFFFFFF0000000000FF00FF00FF00FFFFFFFF00FF00FFFFFFFFFF00FFFFFF00FF00FFFF0000FFFFFFFF00FF00FFFFFFFFFF00FFFFFF00FF00FFFF000000000000FFFFFF00000000FF00FFFFFF00FF00FFFFFF00>
endstream
endobj
6 0 obj
<< /Type /XRef /Size 7 /Root 1 0 R /W [1 4 2] /Index [0 7] /Filter /ASCIIHexDecode /Length 100 >>
stream
0000000000FFFF01000000090000010000003A00000100000073000001000000F500000100000147000001000003340000>
endstream
endobj
startxref
820
%%EOF
```

- [x] Both complete owning-file runs executed all 22 PDF cases, zero failures, as part of 24 Ingest tests per seed. New behavioral assertions passed on first execution. This does not prove arbitrary native stderr, general telemetry, audit, outbox, job argument, custody, or Runtime privacy.

## Task 3: Add two native lifecycle qualification tests

**Create:** `apps/singularity_ingest/test/singularity/ingest/documents/poppler_lifecycle_test.exs`.

- [x] Add this complete companion module. The per-test directory is unique and owned; no ExUnit tmp_dir automatic deletion is used because failure artifacts must survive. Shell commands are test fixtures only. The 10 ms polling interval always checks an explicit condition against a deadline.

```elixir
defmodule Singularity.Ingest.Documents.PopplerLifecycleTest do
  use ExUnit.Case, async: false
  import Bitwise
  alias Singularity.Ingest.Documents.Poppler

  @moduletag :linux
  @timeout 5_000

  test "guardian timeout reaps the established tree while target stdin is backpressured" do
    pipe_max = "/proc/sys/fs/pipe-max-size" |> File.read!() |> String.trim() |> String.to_integer()
    input = :binary.copy("x", 67_108_864)
    assert byte_size(input) > pipe_max
    run_case(input, "hold\n", :timeout)
  end

  test "guardian output overflow reaps the established tree and setsid escapee" do
    run_case(<<>>, "overflow\n", {:error, :output_limit})
  end

  defp run_case(input, release, expected) do
    assert File.dir?("/proc/self"), "Linux procfs is required"
    executables = Map.new(~w(sh sleep setsid mkfifo), &{&1, executable!(&1)})

    dir =
      Path.join(
        System.tmp_dir!(),
        "singularity-qualification-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      )

    File.mkdir!(dir)
    fifo_path = Path.join(dir, "control")
    assert {"", 0} = System.cmd(executables["mkfifo"], [fifo_path])
    {:ok, fifo} = File.open(fifo_path, [:read, :write, :binary])
    supervisor = start_supervised!(Task.Supervisor)
    owner = self()
    result_ref = make_ref()
    state_key = {__MODULE__, dir}
    Process.put(state_key, %{owned: %{}, passed: false})

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        result =
          Poppler.run_guarded(executables["sh"], target_args(dir, executables), input,
            timeout_ms: @timeout,
            output_limit: 1_024
          )

        send(owner, {result_ref, result})
      end)

    try do
      tree =
        await(fn ->
          owned = remember_owned(dir, state_key)

          if map_size(owned) == 4 and Enum.all?(owned, fn {_name, p} -> live?(p) end) and
               ignores_term?(owned.escapee.pid) do
            owned
          else
            false
          end
        end, now() + 3_000)

      assert is_map(tree), "tree readiness failed; artifacts: #{dir}"
      assert tree.child.ppid == tree.guardian.pid
      assert tree.child.group == tree.child.pid
      assert tree.grandchild.ppid == tree.child.pid
      assert tree.grandchild.group == tree.child.group
      assert tree.grandchild.session == tree.child.session
      assert tree.escapee.ppid == tree.child.pid
      assert tree.escapee.group == tree.escapee.pid
      assert tree.escapee.session == tree.escapee.pid
      assert tree.escapee.session != tree.child.session
      assert ignores_term?(tree.escapee.pid)

      :ok = IO.binwrite(fifo, release)
      assert_receive {^result_ref, result}, 6_000
      assert result == expected, "unexpected result #{inspect(result)}; artifacts: #{dir}"
      assert {:ok, _} = Task.yield(task, 1_000)

      assert await(fn -> Enum.all?(tree, fn {_name, p} -> gone?(p) end) end, now() + 1_000),
             "owned native identity survived the result; artifacts: #{dir}"

      Process.put(state_key, %{owned: tree, passed: true})
    after
      # Only the owned BEAM caller is cancelled; its controller owns native cleanup.
      Task.shutdown(task, :brutal_kill)
      File.close(fifo)
      state = Process.get(state_key)

      if state.passed do
        File.rm_rf!(dir)
      else
        _ =
          await(fn ->
            owned = remember_owned(dir, state_key)
            Enum.all?(owned, fn {_name, p} -> gone?(p) end)
          end, now() + 2_000)

        IO.warn("native qualification failed; retained owned PID/FIFO artifacts: #{dir}")
      end

      Process.delete(state_key)
    end
  end

  defp target_args(dir, executables) do
    script = """
    exec 3<>"$4"
    printf '%s\\n' "$$" > "$1"
    "$5" 60 &
    printf '%s\\n' "$!" > "$2"
    "$6" "$7" -c 'trap "" TERM; printf "%s\\n" "$$" > "$1"; exec "$2" 60' escape "$3" "$5" &
    IFS= read -r command <&3
    case "$command" in
      overflow) printf '%01025d' 0 ;;
      hold) : ;;
      *) exit 90 ;;
    esac
    wait
    """

    [
      "-c",
      script,
      "qualification-target",
      Path.join(dir, "child"),
      Path.join(dir, "grandchild"),
      Path.join(dir, "escapee"),
      Path.join(dir, "control"),
      executables["sleep"],
      executables["setsid"],
      executables["sh"]
    ]
  end

  defp executable!(name) do
    executable = System.find_executable(name) || flunk("#{name} executable is required")
    assert Path.type(executable) == :absolute
    executable
  end

  defp remember_owned(dir, key) do
    state = Process.get(key)

    discovered =
      Enum.reduce([:child, :grandchild, :escapee], %{}, fn name, acc ->
        with {:ok, bytes} <- File.read(Path.join(dir, Atom.to_string(name))),
             {pid, ""} when pid > 0 <- Integer.parse(String.trim(bytes)),
             identity when is_map(identity) <- proc_identity(pid) do
          Map.put(acc, name, identity)
        else
          _ -> acc
        end
      end)

    discovered =
      case discovered do
        %{child: child} ->
          case proc_identity(child.ppid) do
            guardian when is_map(guardian) -> Map.put(discovered, :guardian, guardian)
            _ -> discovered
          end

        _ ->
          discovered
      end

    # Keep the first observed start time even if the numeric PID is later reused.
    owned = Map.merge(discovered, state.owned)
    Process.put(key, %{state | owned: owned})
    owned
  end

  defp proc_identity(pid) do
    with {:ok, raw} <- File.read("/proc/#{pid}/stat"),
         [_, rest] <- Regex.run(~r/^\d+ \(.*\) (.*)$/s, raw) do
      fields = String.split(rest)

      %{
        pid: pid,
        state: Enum.at(fields, 0),
        ppid: fields |> Enum.at(1) |> String.to_integer(),
        group: fields |> Enum.at(2) |> String.to_integer(),
        session: fields |> Enum.at(3) |> String.to_integer(),
        start: fields |> Enum.at(19) |> String.to_integer()
      }
    else
      {:error, :enoent} -> nil
      {:error, :esrch} -> nil
      other -> flunk("cannot inspect owned process #{pid}: #{inspect(other)}")
    end
  end

  defp live?(identity) do
    case proc_identity(identity.pid) do
      %{start: start, state: state} -> start == identity.start and state not in ["Z", "X"]
      nil -> false
    end
  end

  defp gone?(identity) do
    case proc_identity(identity.pid) do
      nil -> true
      %{start: start} -> start != identity.start
    end
  end

  defp ignores_term?(pid) do
    with {:ok, status} <- File.read("/proc/#{pid}/status"),
         [mask] <- Regex.run(~r/^SigIgn:\s+([0-9a-fA-F]+)$/m, status, capture: :all_but_first),
         {value, ""} <- Integer.parse(mask, 16) do
      (value &&& 0x4000) != 0
    else
      _ -> false
    end
  end

  defp await(fun, deadline) do
    case fun.() do
      false ->
        remaining = deadline - now()

        if remaining > 0 do
          Process.sleep(min(10, remaining))
          await(fun, deadline)
        else
          false
        end

      result ->
        result
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
```

The timeout fixture never reads fd 0. Its creation proves the guardian received the complete outer frame before fork; 64 MiB exceeds the checked pipe limit. This establishes target-side backpressure. The FIFO release proves the complete tree existed before triggering overflow. The four captured identities include the guardian itself; a zombie still counts as present and fails disappearance.

- [x] Coordinator runs the complete new file once:

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_ingest/test/singularity/ingest/documents/poppler_lifecycle_test.exs --seed 1208
```

Expected: two tests, zero failures; timeout is exactly `:timeout` and overflow exactly `{:error, :output_limit}`. If either case fails, preserve its artifacts and stop the affected case. Diagnose before proposing any implementation change. Do not skip, retry the whole case until green, extend the process limits, weaken the tree assertions, or kill numeric PIDs.

## Task 4: Verify the candidate, review, and record bounded evidence

**Modify:** `docs/verification/2026-10-09-phase-2-task-15-matrix.md`, coordinator only.
**Review:** All six allowlisted files.

- [x] Format only the two changed test modules:

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs apps/singularity_ingest/test/singularity/ingest/documents/poppler_lifecycle_test.exs
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format --check-formatted apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs apps/singularity_ingest/test/singularity/ingest/documents/poppler_lifecycle_test.exs
```

Expected: exit 0. Do not format unrelated files.

- [x] Run both whole owning files with two explicit seeds, one Mix process at a time:

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs apps/singularity_ingest/test/singularity/ingest/documents/poppler_lifecycle_test.exs --seed 1208
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs apps/singularity_ingest/test/singularity/ingest/documents/poppler_lifecycle_test.exs --seed 90731
```

Expected per command: 24 Ingest tests, zero failures. Record actual counts, elapsed times, sessions, exits and source hashes. Seed variation is planned order coverage, not a retry for a failing case.

- [x] Optional separate Core coverage was not selected; the new composition case directly exercises real Core values. The optional command below was NOT RUN:

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_core/test/singularity/core/document_fragmentation_test.exs --seed 1208
```

Expected: 8 Core tests, zero failures; combined with one 24-test Ingest pass this is 32 tests. The pure values are directly exercised by the new composition test; this additional existing-file run is optional, not a fabricated required gate.

- [x] Verify dependency cycles and protected source:

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
git diff d39ad93f257df3a6e01a87a420c7a034c888192b -- apps/*/lib apps/*/priv apps/*/c_src config mix.exs mix.lock devenv.nix Dockerfile
sha256sum apps/singularity_ingest/c_src/poppler_guardian.c
sha256sum apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs apps/singularity_ingest/test/singularity/ingest/documents/poppler_lifecycle_test.exs apps/singularity_ingest/test/fixtures/documents/scanned_image_only.pdf
git status --short
```

Expected: zero cycles, no diff whitespace errors, no production changes, unchanged guardian hash. PDF test hash now differs from baseline; record its actual candidate hash, along with companion and fixture hashes. Verify the fixture's three stream lengths, seven decoded xref entries and referenced offsets, 1,070-byte size, and startxref 820 directly from actual bytes. Do not change .gitattributes, global Git configuration, encoding checks, or verification assertions.

- [x] Obtain fresh specification review, resolve any valid findings within the six-file scope, then fresh quality review. Each review identifies exact file hashes and distinguishes source inspection from execution. Repeat affected verification only after changes. A real production failure requires a separately reviewed repair; no production edit is authorized here.
- [x] Append a coordinator-authored matrix section recording the baseline, six-file scope, added contracts, actual commands/results, hashes and reviews. State explicitly: no Vault feature work; no migration, production code/config/dependency change, custody change, V2/Runtime change, production activation, service restart, push, release, deployment, or full Phase 2 acceptance. E2E and the complete README/Phase 2 gate remain NOT RUN, and Task 15 remains open.
- [x] Standing local-commit authorization confirmed; exactly these six paths staged after full diff/new-file review and independent closure. Commit only this bounded slice; preserve the unrelated untracked plan:

```sh
git add docs/superpowers/specs/2026-10-09-singularity-v0.2-real-extractor-qualification-design.md docs/superpowers/plans/2026-10-09-singularity-v0.2-real-extractor-qualification.md apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs apps/singularity_ingest/test/singularity/ingest/documents/poppler_lifecycle_test.exs apps/singularity_ingest/test/fixtures/documents/scanned_image_only.pdf docs/verification/2026-10-09-phase-2-task-15-matrix.md
git diff --cached --stat
git diff --cached --check
git diff --cached --name-only
git commit -m "test(ingest): qualify real extractor lifecycle and privacy"
git rev-parse HEAD
git status --short
```

Expected: only the six approved paths committed; unrelated user files remain untouched and unstaged. Omit generated/co-author trailers. Commit evidence does not imply push, merge, release or deployment; keep this worktree. Stop when this bounded slice and its checklist are complete.
