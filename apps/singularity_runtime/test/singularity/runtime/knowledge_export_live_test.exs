defmodule Singularity.Runtime.KnowledgeExportLiveTest do
  use ExUnit.Case, async: false

  alias Singularity.Runtime.{Api, NativeAssetFixture}
  alias Singularity.Runtime.KnowledgeExportLiveFixture, as: Live
  alias Singularity.Runtime.KnowledgeExportLiveFixture.{IssuedLeases, Observer}
  alias Singularity.Runtime.KnowledgeExportOfflineOracle, as: Offline
  alias Singularity.Storage.KnowledgeExport.{Spool, Writer}

  @moduletag :integration
  @moduletag timeout: 180_000
  @chunk 65_536
  @collections ~w(resources versions fragments tags tag_assignments relationships attachments citations)a
  @offline_top ~w(format version selection resources versions fragments tags tag_assignments relationships attachments citations files)
  @offline_fields %{
    "resources" => ~w(id kind title current_version_id deleted_at selection_reason),
    "versions" =>
      ~w(resource_id version_id revision kind inserted_at availability body_path original_path extracted_path body_digest original_digest original_byte_size extracted_digest media_type state extraction_adapter extraction_format parent_version_id merge_parent_version_id),
    "fragments" =>
      ~w(id resource_id version_id ordinal digest locator extracted_path start_byte byte_size),
    "tags" => ~w(id display_value normalized_key),
    "tag_assignments" => ~w(resource_id tag_id),
    "relationships" => ~w(id source_resource_id target_resource_id target_version_id type),
    "attachments" =>
      ~w(note_resource_id note_version_id id ordinal target_resource_id target_version_id target_kind role label),
    "citations" =>
      ~w(note_resource_id note_version_id id ordinal source_resource_id source_version_id fragment_id locator),
    "files" => ~w(path media_type byte_size sha256)
  }

  # Only operation tasks are traced. Raw protocol payloads are discarded here;
  # the retained trace consists of PIDs, owned paths and lifecycle labels.
  defmodule CleanupTrace do
    use GenServer
    @cleanup {Singularity.Storage.KnowledgeExport.ArtifactDirectory, :cleanup, 1}
    @cancel {Singularity.Runtime.Knowledge.ExportArtifact, :cancel, 2}
    @source {Singularity.Storage.KnowledgeExport.Repository, :lock_asset_source, 3}

    def start_link(target_asset_id \\ nil) do
      patterns = [
        {@cleanup, [{:_, [], []}]},
        {@cancel, [{:_, [], [{:message, false}, {:return_trace}]}]}
      ]

      patterns =
        if target_asset_id do
          patterns ++
            [
              {@source,
               [
                 {[:_, %{"asset_id" => target_asset_id}, :_], [],
                  [{:message, false}, {:return_trace}]}
               ]}
            ]
        else
          patterns
        end

      {:ok, pid} = result = GenServer.start_link(__MODULE__, {target_asset_id, patterns})

      ExUnit.Callbacks.on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        restore_patterns(patterns)
      end)

      result
    end

    def task(trace, pid), do: GenServer.call(trace, {:task, pid})
    def owner(trace, pid), do: GenServer.call(trace, {:owner, pid})

    def events(trace) do
      :ok = GenServer.call(trace, :sync)
      GenServer.call(trace, :events)
    end

    @impl true
    def init({target_asset_id, patterns}) do
      # Preflight every function before installing anything. Never overwrite a
      # pre-existing local/global pattern or emit cancel/source call arguments.
      for {mfa, _} <- patterns do
        Code.ensure_loaded!(elem(mfa, 0))
        {:traced, false} = :erlang.trace_info(mfa, :traced)
        {:match_spec, false} = :erlang.trace_info(mfa, :match_spec)
      end

      try do
        for {mfa, pattern} <- patterns, do: :erlang.trace_pattern(mfa, pattern, [:local])

        {:ok,
         %{
           tasks: MapSet.new(),
           owner: nil,
           events: [],
           target_asset_id: target_asset_id,
           patterns: patterns
         }}
      rescue
        error ->
          restore_patterns(patterns)
          reraise error, __STACKTRACE__
      catch
        kind, reason ->
          restore_patterns(patterns)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end

    @impl true
    def handle_call({:task, pid}, _from, state) do
      if not MapSet.member?(state.tasks, pid) do
        {:flags, []} = :erlang.trace_info(pid, :flags)
        {:tracer, []} = :erlang.trace_info(pid, :tracer)
        1 = :erlang.trace(pid, true, [:call, :receive, :send, {:tracer, self()}])
      end

      {:reply, :ok, %{state | tasks: MapSet.put(state.tasks, pid)}}
    end

    def handle_call({:owner, pid}, _from, state), do: {:reply, :ok, %{state | owner: pid}}

    def handle_call(:sync, _from, state) do
      for pid <- state.tasks do
        reference = :erlang.trace_delivered(pid)

        receive do
          {:trace_delivered, ^pid, ^reference} -> :ok
        after
          5_000 -> raise "operation trace delivery timeout"
        end
      end

      {:reply, :ok, state}
    end

    def handle_call(:events, _from, state), do: {:reply, Enum.reverse(state.events), state}

    @impl true
    def handle_info({:trace, pid, :receive, {:DOWN, _, :process, owner, _}}, %{owner: owner} = s),
      do: {:noreply, %{s | events: [{:owner_down, pid, owner} | s.events]}}

    def handle_info(
          {:trace, pid, :call,
           {Singularity.Storage.KnowledgeExport.ArtifactDirectory, :cleanup, [%{path: path}]}},
          s
        ),
        do:
          {:noreply,
           %{
             s
             | events: [
                 {:cleanup, pid, path, is_pid(s.owner) and Process.alive?(s.owner)} | s.events
               ]
           }}

    def handle_info({:trace, pid, :return_from, @cancel, :ok}, s),
      do: {:noreply, %{s | events: [{:cancel_completed, pid} | s.events]}}

    def handle_info(
          {:trace, pid, :return_from, @source, {:error, %Singularity.Core.Error{code: code}}},
          s
        ),
        do: {:noreply, %{s | events: [{:target_preflight_denied, pid, code} | s.events]}}

    def handle_info(
          {:trace, pid, tag, {:export_request_cancel, _, requester}, companion},
          s
        )
        when requester == pid and tag in [:send, :send_to_non_existing_process] do
      outcome = if tag == :send, do: :live_pid_send, else: :dead_target_attempt

      {:noreply,
       %{
         s
         | events: [
             {:request_cancel_send, pid, companion, outcome},
             {:request_cancel, pid, companion} | s.events
           ]
       }}
    end

    def handle_info(
          {:trace, pid, tag, {:export_lease, _, pid, _, %{purpose: :download, job_id: asset}},
           companion},
          %{target_asset_id: asset} = s
        )
        when is_binary(asset) and tag in [:send, :send_to_non_existing_process],
        do: {:noreply, %{s | events: [{:target_lease_request, pid, companion} | s.events]}}

    def handle_info(_message, state), do: {:noreply, state}

    @impl true
    def terminate(_, state) do
      for pid <- state.tasks,
          Process.alive?(pid),
          :erlang.trace_info(pid, :tracer) == {:tracer, self()},
          do: :erlang.trace(pid, false, [:call, :receive, :send])

      restore_patterns(state.patterns)
      :ok
    end

    defp restore_patterns(patterns) do
      for {mfa, installed} <- patterns do
        case :erlang.trace_info(mfa, :match_spec) do
          {:match_spec, ^installed} -> :erlang.trace_pattern(mfa, false, [:local])
          {:match_spec, false} -> :ok
          _ -> raise "operation trace pattern ownership changed"
        end
      end
    end
  end

  defmodule RetainedModel do
    @moduledoc false
    import ExUnit.Assertions
    alias Singularity.Storage.KnowledgeExport.Spool

    @collections ~w(resources versions fragments tags tag_assignments relationships attachments citations)a
    @indexes ~w(_selected _collections _versions _drafts _bindings _texts _documents text_refs render_refs binary_refs)a
    @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    @sha ~r/\A[0-9a-f]{64}\z/
    @integer 9_223_372_036_854_775_807
    @vmax 19 * (2 + 6 * 23 + 1 + (2 + 6 * 255)) + 18 + 2

    # external_size is applied only to fixed bounded skeletons. Actual content
    # indexes are enumerated structurally; no corpus JSON/ETF is constructed.
    def e(value), do: :erlang.external_size(value) - 1

    def logical(value) when is_map(value),
      do: :maps.fold(fn k, v, n -> n + logical(k) + logical(v) end, 5, value)

    def logical(value) when is_tuple(value),
      do:
        if(tuple_size(value) < 256, do: 2, else: 5) +
          Enum.reduce(Tuple.to_list(value), 0, &(logical(&1) + &2))

    def logical([]), do: 1
    def logical(value) when is_list(value), do: 6 + Enum.reduce(value, 0, &(logical(&1) + &2))
    def logical(value), do: e(value)

    def coefficients do
      u = String.duplicate("0", 36)
      h = String.duplicate("0", 64)

      n =
        if e(@integer) >= e(-9_223_372_036_854_775_808),
          do: @integer,
          else: -9_223_372_036_854_775_808

      keys = [u, {u, u}, {u, u, n, h}, {u, u, n, u}]

      selectors = [
        {:note_markdown, u, u},
        {:render_descriptions, u, u},
        {:binary_binding, :asset, u, u},
        {:fragment_text, u, u, n, h}
      ]

      pair = fn key, value -> e({key, value}) end

      set_delta = fn member ->
        max(e(MapSet.new([member])) - e(MapSet.new()), pair.(member, true))
      end

      %{
        s: max_of(for kind <- ~w(asset note document), do: set_delta.({kind, u, u})),
        c: max_of(Enum.map(keys, &pair.(&1, nil))),
        v:
          max_of(
            for kind <- ~w(asset note document),
                state <- [nil | ~w(pending extracting ready failed unsupported)],
                availability <- ~w(included metadata_only_deleted metadata_only_unselected),
                digest <- [nil, h],
                do:
                  pair.({u, u}, %{
                    "kind" => kind,
                    "state" => state,
                    "availability" => availability,
                    "extracted_digest" => digest
                  })
          ),
        a: pair.({u, u}, n),
        b: pair.({:binary_binding, :asset, u, u}, n),
        t:
          max_of(
            for selector <- selectors,
                do:
                  pair.(selector, %{byte_size: n, frames: []}) +
                    pair.(selector, %{
                      capture_id: u,
                      selector: selector,
                      offset: n,
                      byte_size: n,
                      sha256: h
                    })
          ),
        d: pair.({u, u}, %{ordinals: %{}, bytes: n}),
        q: pair.(n, {:fragment_text, u, u, n, h}),
        j:
          e([
            %{
              offset: n,
              length: n,
              hash: <<0::256>>,
              index: %{offset: n, length: n, hash: <<0::256>>}
            }
          ]) - e([]),
        captured: max_of(Enum.map(keys, &pair.(&1, true))),
        record: max_of(Enum.map(keys, &pair.(&1, %{offset: n, byte_size: n, sha256: h}))),
        fragment_count: pair.({u, u}, n),
        fragment_identity: max(pair.({u, u, h}, {u, u, n, h}), pair.({u, u, h}, :ambiguous)),
        source_group: pair.({u, u}, []),
        source_member: e([{u, u, n, u}]) - e([]),
        progress: pair.({u, u}, %{count: n, byte_size: n, hash: :crypto.hash_init(:sha256)}),
        seen:
          max_of(
            Enum.map(
              selectors ++ for(kind <- [:asset, :document], do: {:original, kind, u, u}),
              set_delta
            )
          ),
        o:
          pair.(String.duplicate("p", 100), %{
            media_type: String.duplicate("m", 255),
            byte_size: n,
            sha256: h,
            chunks: %{}
          }),
        k: pair.(n, h)
      }
    end

    def sealed!(s, expected_temporary_bytes \\ 0) do
      assert is_integer(expected_temporary_bytes) and expected_temporary_bytes >= 0

      keys!(
        s,
        ~w(capture_id accounting _phase _generation _clock _deadline _write _secret _identity _sizes _selected _collections _texts _documents _bindings _drafts _versions text_refs render_refs binary_refs sealed?)a
      )

      assert s.sealed? == true
      keys!(s._collections, @collections)
      keys!(s.accounting, ~w(spool_bytes metadata_records selected_keys original_bytes)a)
      assert Map.keys(Map.from_struct(s._selected)) == [:map], "installed MapSet schema boundary"

      for {{kind, resource, version}, marker} <- s._selected.map do
        assert kind in ~w(asset note document) and marker in [[], true]
        uuid!(resource)
        if version, do: uuid!(version)
      end

      for {collection, rows} <- s._collections, {key, frame} <- rows do
        collection_key!(collection, key)
        frame!(frame)
      end

      for {key, summary} <- s._versions do
        pair_uuid!(key)
        keys!(summary, ~w(kind state availability extracted_digest))
        assert summary["kind"] in ~w(asset note document)
        assert summary["state"] in [nil | ~w(pending extracting ready failed unsupported)]

        assert summary["availability"] in ~w(included metadata_only_deleted metadata_only_unselected)

        if summary["extracted_digest"], do: sha!(summary["extracted_digest"])
      end

      assert MapSet.new(Map.keys(s._versions)) == MapSet.new(Map.keys(s._collections.versions)),
             "version summary count boundary"

      for {key, size} <- s._drafts,
          do:
            (
              pair_uuid!(key)
              count!(size, 68_719_476_736)
            )

      for {selector, size} <- s._bindings do
        assert elem(selector, 0) == :binary_binding
        selector!(selector)
        count!(size, 68_719_476_736)
      end

      refs = Map.merge(s.text_refs, s.render_refs) |> Map.merge(s.binary_refs)

      for {selector, _} <- s.text_refs,
          do:
            assert(
              elem(selector, 0) in [:note_markdown, :fragment_text],
              "text ref family boundary"
            )

      for {selector, _} <- s.render_refs,
          do: assert(elem(selector, 0) == :render_descriptions, "render ref family boundary")

      for {selector, _} <- s.binary_refs,
          do: assert(elem(selector, 0) == :binary_binding, "binding ref family boundary")

      assert MapSet.new(Map.keys(s._bindings)) == MapSet.new(Map.keys(s.binary_refs)),
             "binding count boundary"

      assert map_size(refs) ==
               map_size(s.text_refs) + map_size(s.render_refs) + map_size(s.binary_refs)

      assert MapSet.new(Map.keys(refs)) == MapSet.new(Map.keys(s._texts)),
             "selector count boundary"

      for {selector, text} <- s._texts do
        selector!(selector)
        keys!(text, [:byte_size, :frames])
        count!(text.byte_size, 1_073_741_824)
        assert text.frames != []
        Enum.each(text.frames, &frame!/1)
        ref = Map.fetch!(refs, selector)
        keys!(ref, [:capture_id, :selector, :offset, :byte_size, :sha256])

        assert ref.capture_id == s.capture_id and ref.selector == selector and
                 ref.byte_size == text.byte_size,
               "typed ref boundary"

        assert ref.offset == hd(text.frames).offset + 40
        sha!(ref.sha256)
      end

      for {pair, document} <- s._documents do
        pair_uuid!(pair)
        keys!(document, [:ordinals, :bytes])
        count!(document.bytes, 16_777_216)

        for {ordinal, selector} <- document.ordinals do
          count!(ordinal, 4095)
          selector!(selector)

          assert elem(selector, 0) == :fragment_text and
                   {elem(selector, 1), elem(selector, 2)} == pair and elem(selector, 3) == ordinal

          assert Map.has_key?(s._texts, selector), "document selector boundary"
        end

        assert document.bytes ==
                 Enum.reduce(document.ordinals, 0, fn {_, selector}, n ->
                   n + Map.fetch!(s._texts, selector).byte_size
                 end),
               "document byte count boundary"

        ordinals = Enum.sort(Map.keys(document.ordinals))

        assert ordinals != [] and
                 Enum.all?(Enum.with_index(ordinals), fn {ordinal, index} -> ordinal == index end),
               "document ordinal count boundary"
      end

      counts = %{
        s: MapSet.size(s._selected),
        c: sum_maps(s._collections),
        v: map_size(s._versions),
        a: map_size(s._drafts),
        b: map_size(s._bindings),
        t: map_size(s._texts),
        d: map_size(s._documents),
        q: Enum.reduce(s._documents, 0, fn {_, d}, n -> n + map_size(d.ordinals) end),
        j:
          sum_maps(s._collections) +
            Enum.reduce(s._texts, 0, fn {_, t}, n -> n + length(t.frames) end)
      }

      charge =
        counts.s + counts.c + counts.v + counts.a + counts.b + 3 * counts.t + counts.d + counts.q +
          4 * counts.j

      assert charge <= s.accounting.metadata_records and
               s.accounting.metadata_records <= 1_000_000,
             "retained charge boundary"

      assert counts.s == s.accounting.selected_keys and counts.s <= 100_000,
             "selected count boundary"

      assert s.accounting.spool_bytes ==
               s._sizes.payload + s._sizes.index + expected_temporary_bytes,
             "temporary plaintext accounting boundary"

      directory = Path.join(s._identity.root, s.capture_id)
      assert File.stat!(Path.join(directory, "payload")).size == s._sizes.payload
      assert File.stat!(Path.join(directory, "index")).size == s._sizes.index

      assert {:ok, original_bytes} =
               Spool.reduce_metadata(s, :versions, 0, fn row, n ->
                 {:ok,
                  n +
                    if(row["availability"] == "included",
                      do: row["original_byte_size"] || 0,
                      else: 0
                    )}
               end)

      assert original_bytes == s.accounting.original_bytes
      content = Map.take(s, @indexes)
      fixed = s |> Map.drop(@indexes)

      empty =
        Map.merge(fixed, %{
          _selected: MapSet.new(),
          _collections: Map.new(@collections, &{&1, %{}}),
          _versions: %{},
          _drafts: %{},
          _bindings: %{},
          _texts: %{},
          _documents: %{},
          text_refs: %{},
          render_refs: %{},
          binary_refs: %{}
        })

      c = coefficients()

      bound =
        logical(empty) +
          Enum.reduce(counts, 0, fn {family, n}, total -> total + n * Map.fetch!(c, family) end)

      measured = logical(s)
      assert measured <= bound, "sealed logical bound boundary"

      assert Enum.all?(
               binaries(content),
               &(byte_size(&1) <= 64 and :binary.referenced_byte_size(&1) <= 64)
             ),
             "sealed backing boundary"

      %{
        counts: counts,
        coefficients: c,
        logical: measured,
        bound: bound,
        fixed_logical: logical(fixed),
        fixed_max_backing: max_backing(fixed),
        metadata_records: s.accounting.metadata_records,
        selected_keys: counts.s,
        spool_bytes: s.accounting.spool_bytes,
        original_bytes: original_bytes
      }
    end

    def writer_build!(w) do
      sealed = sealed!(w._capture)
      c = coefficients()
      keys!(w._captured, @collections)
      keys!(w._records, @collections)
      keys!(w._source_keys, [:attachments, :citations])

      for {collection, rows} <- w._captured,
          {key, true} <- rows,
          do: collection_key!(collection, key)

      for {collection, rows} <- w._records, {key, ref} <- rows do
        collection_key!(collection, key)
        keys!(ref, [:offset, :byte_size, :sha256])
        sha!(ref.sha256)
      end

      for {key, count} <- w._fragment_counts,
          do:
            (
              pair_uuid!(key)
              count!(count, 4096)
            )

      for {{resource, version, id}, key} <- w._fragment_identities do
        uuid!(resource)
        uuid!(version)
        sha!(id)
        if key != :ambiguous, do: collection_key!(:fragments, key)
      end

      groups =
        Enum.reduce(w._source_keys, 0, fn {collection, entries}, total ->
          for {pair, keys} <- entries do
            pair_uuid!(pair)
            Enum.each(keys, &collection_key!(collection, &1))
          end

          total + map_size(entries)
        end)

      members =
        Enum.reduce(w._source_keys, 0, fn {_, entries}, total ->
          total + Enum.reduce(entries, 0, fn {_, keys}, n -> n + length(keys) end)
        end)

      for {key, progress} <- w._documents do
        pair_uuid!(key)
        keys!(progress, [:count, :byte_size, :hash])
        assert e(progress.hash) <= e(:crypto.hash_init(:sha256)), "opaque hash context boundary"
      end

      for selector <- w._seen do
        case selector do
          {:original, kind, resource, version} ->
            assert kind in [:asset, :document]
            uuid!(resource)
            uuid!(version)

          _ ->
            selector!(selector)
        end
      end

      counts = %{
        captured: sum_maps(w._captured),
        record: sum_maps(w._records),
        fragment_count: map_size(w._fragment_counts),
        fragment_identity: map_size(w._fragment_identities),
        source_group: groups,
        source_member: members,
        progress: map_size(w._documents),
        seen: MapSet.size(w._seen)
      }

      assert counts.captured == sealed.counts.c and counts.record <= sealed.counts.c
      assert counts.fragment_count <= sealed.counts.v and counts.progress <= sealed.counts.v

      assert counts.fragment_identity <= sealed.counts.c and groups <= sealed.counts.c and
               members <= sealed.counts.c

      assert counts.seen <= sealed.counts.t + sealed.counts.v

      build_keys =
        ~w(_captured _records _fragment_counts _fragment_identities _source_keys _documents _seen)a

      # The original-fold closure is an independently bounded working closure;
      # it references the capture again. It is not a content-index family and
      # encoding its environment would duplicate the capture in this measure.
      measured_state = Map.delete(w, :_fold)
      fixed = measured_state |> Map.drop([:_capture, :_outputs | build_keys])

      empty =
        Map.merge(fixed, %{
          _captured: Map.new(@collections, &{&1, %{}}),
          _records: Map.new(@collections, &{&1, %{}}),
          _fragment_counts: %{},
          _fragment_identities: %{},
          _source_keys: %{attachments: %{}, citations: %{}},
          _documents: %{},
          _seen: MapSet.new(),
          _outputs: %{}
        })

      output = outputs!(w._outputs)

      bound =
        sealed.bound + logical(empty) +
          Enum.reduce(counts, 0, fn {family, n}, total -> total + n * Map.fetch!(c, family) end) +
          output.o * c.o + output.k * c.k

      assert logical(measured_state) <= bound, "Writer build logical boundary"
      assert is_function(w._fold, 3)

      %{
        counts: counts,
        logical: logical(measured_state),
        bound: bound,
        opaque_hash_bytes: e(:crypto.hash_init(:sha256)),
        original_fold_arity: 3
      }
    end

    def published!(w) do
      forbidden =
        ~w(_capture _captured _fragment_counts _fragment_identities _source_keys _records _fold _write _documents _seen _journal_size _options _manifest_hash)a

      refute Enum.any?(forbidden, &Map.has_key?(w, &1)), "published build field boundary"
      output = outputs!(w._outputs)
      c = coefficients()
      fixed = Map.put(w, :_outputs, %{})
      bound = logical(fixed) + output.o * c.o + output.k * c.k
      assert logical(w) <= bound, "published logical boundary"

      assert output.o + output.k <= w.accounting.metadata_records and
               w.accounting.metadata_records <= 1_000_000

      rows = :ets.tab2list(w._ledger)
      assert :ets.info(w._ledger, :owner) == self()
      files = Enum.filter(rows, &match?({{:file, _}, _}, &1))
      directories = Enum.filter(rows, &match?({{:directory, _}, _}, &1))
      assert length(files) == output.o + 2 and length(directories) <= 5

      assert MapSet.new(Enum.map(files, fn {{:file, path}, _} -> path end)) ==
               MapSet.new(Map.keys(w._outputs) ++ [".records", ".index"])

      for {{:file, path}, row} <- files do
        keys!(row, [:identity, :size])
        identity!(row.identity)
        count!(row.size, 68_719_476_736)

        assert byte_size(path) <= 100 and :binary.referenced_byte_size(path) <= @vmax,
               "ledger backing boundary"
      end

      for {{:directory, prefix}, identity} <- directories do
        assert prefix in [
                 "notes",
                 "assets",
                 "documents",
                 "documents/originals",
                 "documents/extracted"
               ]

        identity!(identity)
      end

      assert Enum.sort(Enum.map(rows -- (files ++ directories), &elem(&1, 0))) == [
               :accounting,
               :binding,
               :location
             ]

      assert [{:accounting, accounting}] = :ets.lookup(w._ledger, :accounting)
      assert accounting == w.accounting
      assert [{:location, :complete}] = :ets.lookup(w._ledger, :location)
      assert [{:binding, binding}] = :ets.lookup(w._ledger, :binding)
      keys!(binding, [:identity, :deadline, :clock, :phase])
      n = @integer

      identities =
        Enum.map(files, fn {_, row} -> row.identity end) ++ Enum.map(directories, &elem(&1, 1))

      identity_skeleton = Enum.max_by(identities, &e/1, fn -> Tuple.duplicate(n, 4) end)
      c_file = e({{:file, String.duplicate("p", 100)}, %{identity: identity_skeleton, size: n}})
      c_directory = e({{:directory, "documents/originals"}, identity_skeleton})
      admin = e({:accounting, accounting}) + e({:location, :complete}) + e({:binding, binding})
      ledger_bound = e([]) + (output.o + 2) * c_file + 5 * c_directory + admin + 5 * length(rows)
      assert logical(rows) <= ledger_bound, "real ETS logical boundary"

      %{
        o: output.o,
        k: output.k,
        logical: logical(w),
        bound: bound,
        ledger_rows: length(rows),
        ledger_logical: logical(rows),
        ledger_bound: ledger_bound,
        c_file: c_file,
        c_directory: c_directory,
        fixed_max_backing: max_backing(fixed),
        backing_allowance: 3 * output.o * @vmax,
        version_parent_bound: @vmax
      }
    end

    defp outputs!(outputs) do
      k =
        Enum.reduce(outputs, 0, fn {path, row}, total ->
          assert byte_size(path) <= 100 and :binary.referenced_byte_size(path) <= @vmax,
                 "output backing boundary"

          keys!(row, [:media_type, :byte_size, :sha256, :chunks])

          assert byte_size(row.media_type) <= 255 and
                   :binary.referenced_byte_size(row.media_type) <= @vmax

          sha!(row.sha256)

          for {ordinal, digest} <- row.chunks,
              do:
                (
                  count!(ordinal, 1_048_575)
                  sha!(digest)
                )

          assert map_size(row.chunks) == max(1, div(row.byte_size + 65_535, 65_536))
          total + map_size(row.chunks)
        end)

      %{o: map_size(outputs), k: k}
    end

    defp collection_key!(collection, key) when collection in [:resources, :tags, :relationships],
      do: uuid!(key)

    defp collection_key!(collection, key) when collection in [:versions, :tag_assignments],
      do: pair_uuid!(key)

    defp collection_key!(:fragments, {u, v, n, h}),
      do:
        (
          uuid!(u)
          uuid!(v)
          count!(n, 4095)
          sha!(h)
        )

    defp collection_key!(collection, {u, v, n, id}) when collection in [:attachments, :citations],
      do:
        (
          uuid!(u)
          uuid!(v)
          count!(n, 99)
          uuid!(id)
        )

    defp collection_key!(_, _), do: flunk("collection key boundary")

    defp selector!({kind, u, v}) when kind in [:note_markdown, :render_descriptions],
      do:
        (
          uuid!(u)
          uuid!(v)
        )

    defp selector!({:binary_binding, :asset, u, v}),
      do:
        (
          uuid!(u)
          uuid!(v)
        )

    defp selector!({:fragment_text, u, v, n, h}),
      do:
        (
          uuid!(u)
          uuid!(v)
          count!(n, 4095)
          sha!(h)
        )

    defp selector!(_), do: flunk("typed selector boundary")

    defp frame!(frame) do
      keys!(frame, [:offset, :length, :hash, :index])
      keys!(frame.index, [:offset, :length, :hash])

      for f <- [frame, frame.index] do
        count!(f.offset, 1_073_741_824)
        count!(f.length, 1_073_741_824)
        assert is_binary(f.hash) and byte_size(f.hash) == 32
      end
    end

    defp keys!(value, keys),
      do:
        assert(
          is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys),
          "retained schema boundary"
        )

    defp pair_uuid!({u, v}),
      do:
        (
          uuid!(u)
          uuid!(v)
        )

    defp pair_uuid!(_), do: flunk("UUID pair boundary")
    defp uuid!(v), do: assert(is_binary(v) and v =~ @uuid, "retained UUID boundary")

    defp sha!(v) do
      binary? = is_binary(v)
      assert binary?, "retained digest boundary: binary"
      size = byte_size(v)
      assert size == 64, "retained digest boundary: bytes=#{size}"
      lowercase_hex? = Regex.match?(@sha, v)
      assert lowercase_hex?, "retained digest boundary: lowercase hex"
      referenced_bytes = :binary.referenced_byte_size(v)

      assert referenced_bytes <= 64,
             "retained digest boundary: referenced_bytes=#{referenced_bytes}"
    end

    def known_digest!(digest, bytes) do
      sha!(digest)

      assert digest == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
             "retained known-byte digest boundary"
    end

    defp count!(n, max),
      do: assert(is_integer(n) and n >= 0 and n <= max, "retained count boundary")

    defp identity!(identity),
      do:
        assert(
          is_tuple(identity) and tuple_size(identity) == 4 and
            Enum.all?(Tuple.to_list(identity), &is_integer/1)
        )

    defp max_of(values), do: Enum.max(values)
    defp sum_maps(m), do: Enum.reduce(m, 0, fn {_, rows}, n -> n + map_size(rows) end)
    def binaries(v) when is_binary(v), do: [v]

    def binaries(v) when is_map(v),
      do: :maps.fold(fn k, value, acc -> binaries(k) ++ binaries(value) ++ acc end, [], v)

    def binaries(v) when is_tuple(v), do: v |> Tuple.to_list() |> binaries()
    def binaries(v) when is_list(v), do: Enum.flat_map(v, &binaries/1)
    def binaries(_), do: []

    defp max_backing(v),
      do: Enum.reduce(binaries(v), 0, &max(:binary.referenced_byte_size(&1), &2))
  end

  test "injected ENOSPC through genuine Api and real Writer after native delivery is sanitized" do
    rich_fixture(fn f ->
      parent = self()

      {:ok, state} =
        Agent.start_link(fn -> %{armed: false, successful: 0, injected: 0, ownership: nil} end)

      {:ok, trace} = CleanupTrace.start_link()

      write = fn device, bytes ->
        assert byte_size(bytes) <= @chunk

        inject? =
          Agent.get_and_update(state, fn s ->
            if s.armed, do: {true, %{s | injected: s.injected + 1}}, else: {false, s}
          end)

        if inject? do
          send(parent, {:task17_enospc, self()})
          {:error, :enospc}
        else
          result = IO.binwrite(device, bytes)
          if result == :ok, do: Agent.update(state, &%{&1 | successful: &1.successful + 1})
          result
        end
      end

      ownership_context = %{supervisor: f.supervisor, roots: %{artifact: f.roots.artifact}}

      on_event = fn point, _values ->
        if point == :task_first_clock, do: CleanupTrace.task(trace, self())

        if point == :native_piece do
          CleanupTrace.owner(trace, self())

          if Agent.get(state, &is_nil(&1.ownership)) do
            owned = ownership!(ownership_context, self())
            Agent.update(state, &%{&1 | armed: true, ownership: owned})
          end
        end
      end

      config = Live.export_config(f, %{write: write, on_event: on_event})
      {requester, monitor} = requester!(f, config, trace)
      result = await_result!(requester)

      try do
        stats = Agent.get(state, & &1)

        native_pieces =
          Enum.count(Observer.events(f), &(&1.point == :native_piece and &1.byte_size > 0))

        assert native_pieces > 0
        assert stats.armed and is_pid(stats.ownership.owner) and stats.ownership.ledgers != []

        IO.puts(
          "Task17 actual Api ENOSPC prerequisites: " <>
            inspect(%{
              positive_native_pieces: native_pieces,
              writer_owner_observed: true,
              successful_writes: stats.successful,
              injected_writes: stats.injected,
              unexpected_success: match?({:ok, _}, result)
            })
        )

        # This assertion is intentionally the causal RED on the accepted source:
        # Export currently ignores the trusted Writer callback and returns a handle.
        assert result == {:error, :storage_unavailable}
        assert_receive {:task17_enospc, owner}, 5_000
        assert stats.successful > 0 and stats.injected == 1
        assert stats.ownership.owner == owner
        stop_requester!(requester, monitor)
        assert_terminal!(f, stats.ownership, trace)
      after
        close_unexpected!(f, config, result)
        finish_requester!(requester, monitor)
        GenServer.stop(trace)
        Agent.stop(state)
      end
    end)
  end

  for tombstones <- [false, true] do
    test "real public publication export has independent portable bytes and tombstones=#{tombstones}" do
      rich_fixture(fn f ->
        config = Live.export_config(f, %{})

        assert {:ok, handle} =
                 Api.export_knowledge(config, f.session, %{
                   include_tombstones: unquote(tombstones)
                 })

        materialized = Live.materialize!(f, config, handle)

        manifest =
          Offline.verify!(
            materialized.root,
            expectation(f, materialized.entries, unquote(tombstones))
          )

        assert length(manifest["versions"]) > 10
        assert Enum.any?(Observer.events(f), &(&1.point == :native_piece and &1.kind == :asset))

        assert Enum.any?(
                 Observer.events(f),
                 &(&1.point == :native_piece and &1.kind == :document)
               )

        assert Enum.any?(Observer.events(f), &(&1.point == :public_page))
        assert Enum.any?(Observer.events(f), &(&1.point == :public_chunk))
        Live.assert_quiescent!(f)
      end)
    end
  end

  test "default production Api wires all four operations and closes the global real owner" do
    rich_fixture(fn f ->
      :ok = IssuedLeases.enable(f.lease_tracker)
      assert Task.Supervisor.children(Singularity.Runtime.UploadRecoveryTaskSupervisor) == []
      assert {:ok, handle} = Api.export_knowledge(f.session, %{})

      try do
        assert {:ok, %{entries: entries}} = Api.knowledge_export_entries(f.session, handle, nil)
        assert Enum.any?(entries, &(&1["path"] == "manifest.json"))

        assert {:ok, bytes} =
                 Api.read_knowledge_export_chunk(f.session, handle, "manifest.json", 0)

        assert byte_size(bytes) > 0 and byte_size(bytes) <= @chunk
      after
        assert :ok = Api.close_knowledge_export(f.session, handle)
      end

      assert Task.Supervisor.children(Singularity.Runtime.UploadRecoveryTaskSupervisor) == []
      Live.assert_quiescent!(f)
    end)
  end

  test "captured immutable graph survives real head and tag mutations after capture COMMIT" do
    rich_fixture(fn f ->
      config = Live.export_config(f, %{barriers: [:capture_committed]})
      {requester, monitor} = requester!(f, config)
      owner = barrier!(f, :capture_committed)

      f.permission_scope.(%{purpose: :graph}, fn ->
        note = f.graph.note

        assert {:ok, %{outcome: :saved}} =
                 Api.save_note(f.session, note.resource_id, %{
                   mutation_id: Ecto.UUID.generate(),
                   base_version_id: note.resource_version_id,
                   title: "Later head",
                   markdown: "LATER_HEAD_NOT_IN_CAPTURE"
                 })

        assert {:ok, _} =
                 Api.attach_tag(f.session, note.resource_id, %{name: "LATER_TAG_NOT_IN_CAPTURE"})
      end)

      continue!(f, :capture_committed, owner)
      assert {:ok, handle} = await_result!(requester)
      result = Live.materialize!(f, config, handle)
      Offline.verify!(result.root, expectation(f, result.entries, false))
      stop_requester!(requester, monitor)
      Live.assert_quiescent!(f)
    end)
  end

  test "selected source deletion after committed capture fails before native transfer" do
    rich_fixture(fn f ->
      asset_id = f.sources.pdf.asset.asset_id
      {:ok, trace} = CleanupTrace.start_link(asset_id)

      config =
        Live.export_config(f, %{barriers: [:capture_committed], on_event: trace_callback(trace)})

      {requester, monitor} = requester!(f, config, trace)
      owner = barrier!(f, :capture_committed)
      CleanupTrace.owner(trace, owner)
      owned = ownership!(f, owner, false)
      assert {:ok, summary} = Api.asset_summary(f.session, asset_id)
      assert {:ok, _} = Api.delete_asset(f.session, asset_id, summary.state_revision)
      continue!(f, :capture_committed, owner)
      assert {:error, :integrity_failure} = await_result!(requester)
      stop_requester!(requester, monitor)
      assert_terminal!(f, owned, trace)
      events = CleanupTrace.events(trace)
      assert {:target_preflight_denied, owner, :integrity_failure} in events

      refute Enum.any?(events, &match?({:target_lease_request, ^owner, _}, &1)),
             "deleted target must fail preflight before its own native lease request"

      GenServer.stop(trace)
    end)
  end

  test "authority revocation after native bytes and before final completion denies publication" do
    rich_fixture(fn f ->
      parent = self()
      token = make_ref()
      {:ok, armed} = Agent.start_link(fn -> false end)
      {:ok, trace} = CleanupTrace.start_link()

      write = fn device, bytes ->
        if Agent.get(armed, & &1) and String.contains?(bytes, "singularity.portable-knowledge") and
             not Process.get({__MODULE__, token}, false) do
          Process.put({__MODULE__, token}, true)
          send(parent, {:task17_last_write, token, self()})

          receive do
            {:task17_continue_write, ^token} -> :ok
          after
            15_000 -> flunk("Writer barrier timeout")
          end
        end

        IO.binwrite(device, bytes)
      end

      on_event = fn point, values ->
        trace_callback(trace).(point, values)
        if point == :native_piece, do: Agent.update(armed, fn _ -> true end)
      end

      config = Live.export_config(f, %{write: write, on_event: on_event})
      {requester, monitor} = requester!(f, config, trace)
      assert_receive {:task17_last_write, ^token, owner}, 20_000
      CleanupTrace.owner(trace, owner)
      owned = ownership!(f, owner)
      assert [ledger] = owned.ledgers
      rows = :ets.tab2list(ledger)

      for prefix <- ["notes/", "assets/", "documents/originals/", "documents/extracted/"] do
        assert Enum.any?(rows, fn
                 {{:file, path}, %{size: size}} -> String.starts_with?(path, prefix) and size > 0
                 _ -> false
               end)
      end

      assert [{:location, :staging}] = :ets.lookup(ledger, :location)
      refute Enum.any?(Observer.events(f), &(&1.point == :completed))
      revoke_authority!(f)
      send(owner, {:task17_continue_write, token})
      assert {:error, code} = await_result!(requester)
      assert code in [:invalid, :forbidden, :storage_unavailable]
      stop_requester!(requester, monitor)
      assert_terminal!(f, owned, trace)
      GenServer.stop(trace)
      Agent.stop(armed)
    end)
  end

  test "native generation delivers a genuine first piece then next real native read denies" do
    large_fixture(fn f ->
      {:ok, trace} = CleanupTrace.start_link()
      parent = self()
      token = make_ref()

      on_event = fn point, values ->
        trace_callback(trace).(point, values)

        if point == :before_native_read and
             match?(%{kind: :document, ordinal: 1}, values) do
          send(parent, {:task17_next_native_read, token, self(), values.lease})

          receive do
            {:task17_continue_native_read, ^token} -> :ok
          after
            15_000 -> raise "next native read barrier timed out"
          end
        end
      end

      config = Live.export_config(f, %{on_event: on_event})

      {requester, monitor} = requester!(f, config, trace)
      assert_receive {:task17_next_native_read, ^token, owner, lease}, 30_000
      CleanupTrace.owner(trace, owner)
      owned = ownership!(f, owner)
      assert Enum.any?(Observer.events(f), &(&1.point == :native_piece and &1.byte_size > 0))

      assert Enum.any?(
               Observer.events(f),
               &(&1.point == :native_piece and &1.lease == lease and
                   &1.kind == :document and &1.byte_size == 4_194_304)
             )

      assert for(
               event <- Observer.events(f),
               event.point == :before_native_read and event.lease == lease,
               do: event.ordinal
             ) == [0, 1]

      revoke_authority!(f)
      send(owner, {:task17_continue_native_read, token})
      assert {:error, code} = await_result!(requester)
      assert code in [:invalid, :forbidden, :storage_unavailable]

      assert Enum.any?(
               Observer.events(f),
               &(&1.point == :native_read_result and &1.outcome != :ok)
             )

      assert Enum.any?(
               Observer.events(f),
               &(&1.point == :native_read_result and &1.lease == lease and
                   &1.kind == :document and &1.outcome != :ok)
             )

      assert Enum.count(
               Observer.events(f),
               &(&1.point == :native_piece and &1.lease == lease)
             ) == 1

      stop_requester!(requester, monitor)
      assert_terminal!(f, owned, trace)
      GenServer.stop(trace)
    end)
  end

  test "completed handle first public chunk succeeds and next ordinal denies after authority revocation" do
    large_fixture(fn f ->
      {:ok, trace} = CleanupTrace.start_link()
      config = Live.export_config(f, %{on_event: trace_callback(trace)})
      assert {:ok, handle} = Api.export_knowledge(config, f.session, %{})
      CleanupTrace.owner(trace, handle.owner)
      owned = ownership!(f, handle.owner)

      assert {:ok, %{entries: entries}} =
               Api.knowledge_export_entries(config, f.session, handle, nil)

      file = Enum.find(entries, &(&1["byte_size"] > @chunk))
      assert is_map(file)

      assert {:ok, first} =
               Api.read_knowledge_export_chunk(config, f.session, handle, file["path"], 0)

      assert byte_size(first) == @chunk
      revoke_authority!(f)

      assert {:error, code} =
               Api.read_knowledge_export_chunk(config, f.session, handle, file["path"], 1)

      assert code in [:invalid, :forbidden, :storage_unavailable]
      assert_terminal!(f, owned, trace)
      GenServer.stop(trace)
    end)
  end

  test "wrong session principal owner scope and authorization epoch expose no completed bytes" do
    rich_fixture(fn f ->
      config = Live.export_config(f, %{})

      for field <- [
            :session_id,
            :principal_id,
            :vault_id,
            :principal_authorization_epoch,
            :vault_authorization_epoch
          ] do
        assert {:ok, handle} = Api.export_knowledge(config, f.session, %{})

        wrong =
          Map.put(
            f.session,
            field,
            if(field in [:principal_authorization_epoch, :vault_authorization_epoch],
              do: Map.fetch!(f.session, field) + 1,
              else: Ecto.UUID.generate()
            )
          )

        try do
          assert {:error, _} = Api.knowledge_export_entries(config, wrong, handle, nil)

          assert {:error, _} =
                   Api.read_knowledge_export_chunk(config, wrong, handle, "manifest.json", 0)
        after
          assert :ok = Api.close_knowledge_export(config, f.session, handle)
        end
      end

      Live.assert_quiescent!(f)
    end)
  end

  for victim <- [:requester, :owner] do
    test "real #{victim} DOWN during generation cleans owned Writer and every issued native lease" do
      rich_fixture(fn f ->
        {:ok, trace} = CleanupTrace.start_link()

        config =
          Live.export_config(f, %{barriers: [:native_piece], on_event: trace_callback(trace)})

        {requester, monitor} = requester!(f, config, trace)
        owner = barrier!(f, :native_piece)
        CleanupTrace.owner(trace, owner)
        owned = ownership!(f, owner)
        target = if unquote(victim) == :requester, do: requester, else: owner
        down = Process.monitor(target)
        Process.exit(target, :kill)
        assert_receive {:DOWN, ^down, :process, ^target, :killed}, 5_000

        if unquote(victim) == :requester do
          assert_receive {:DOWN, ^monitor, :process, ^requester, :killed}, 5_000
        else
          assert {:error, :storage_unavailable} = await_result!(requester)
          stop_requester!(requester, monitor)
        end

        assert_terminal!(f, owned, trace)
        GenServer.stop(trace)
      end)
    end
  end

  for phase <- [:generation, :delivery] do
    test "fixed monotonic expiry during #{phase} uses real cancellation and terminal cleanup" do
      rich_fixture(fn f ->
        {:ok, now} = Agent.start_link(fn -> 10_000 end)
        {:ok, trace} = CleanupTrace.start_link()
        controls = %{clock: fn -> Agent.get(now, & &1) end, on_event: trace_callback(trace)}

        controls =
          if unquote(phase) == :generation,
            do: Map.put(controls, :barriers, [:native_piece]),
            else: controls

        config = Live.export_config(f, controls)
        {requester, monitor} = requester!(f, config, trace)

        if unquote(phase) == :generation do
          owner = barrier!(f, :native_piece)
          CleanupTrace.owner(trace, owner)
          owned = ownership!(f, owner)
          assert Enum.any?(Observer.events(f), &(&1.point == :native_piece and &1.byte_size > 0))
          Agent.update(now, fn _ -> 910_001 end)
          continue!(f, :native_piece, owner)
          assert {:error, _} = await_result!(requester)
          stop_requester!(requester, monitor)
          assert_terminal!(f, owned, trace)

          assert Enum.any?(
                   CleanupTrace.events(trace),
                   &match?({:request_cancel, ^requester, _}, &1)
                 )

          events = CleanupTrace.events(trace)

          assert Enum.any?(
                   events,
                   &match?(
                     {:request_cancel_send, ^requester, companion, outcome}
                     when companion == owned.companion and
                            outcome in [:live_pid_send, :dead_target_attempt],
                     &1
                   )
                 )

          down = Enum.find_index(events, &(&1 == {:owner_down, owned.companion, owner}))

          cleanup =
            Enum.find_index(events, &(&1 == {:cleanup, owned.companion, owned.path, false}))

          cancelled = Enum.find_index(events, &(&1 == {:cancel_completed, owned.companion}))

          assert is_integer(down) and is_integer(cleanup) and is_integer(cancelled) and
                   down < cleanup and cleanup < cancelled,
                 "real companion cancellation must return after owner DOWN and owned cleanup"
        else
          assert {:ok, handle} = await_result!(requester)
          CleanupTrace.owner(trace, handle.owner)
          owned = ownership!(f, handle.owner)
          Agent.update(now, fn _ -> 910_001 end)

          assert {:error, _} =
                   Api.read_knowledge_export_chunk(config, f.session, handle, "manifest.json", 0)

          stop_requester!(requester, monitor)
          assert_terminal!(f, owned, trace)
        end

        GenServer.stop(trace)
        Agent.stop(now)
      end)
    end
  end

  test "temporary fixture permissions restore exact ACL and identities on success and both exceptions" do
    Live.with_fixture(fn f ->
      before = f.permission_snapshot.()

      assert_raise RuntimeError, "partial permission setup", fn ->
        f.permission_scope.(%{after_grant: fn _ -> raise "partial permission setup" end}, fn ->
          flunk("partial setup must not enter callback")
        end)
      end

      assert f.permission_snapshot.() == before

      assert_raise RuntimeError, "permission callback", fn ->
        f.permission_scope.(%{}, fn -> raise "permission callback" end)
      end

      assert f.permission_snapshot.() == before
      published = Live.publish_sources!(f)
      assert published.repositories == f.repositories
      assert f.permission_snapshot.() == before
      Live.assert_quiescent!(published)
    end)
  end

  test "real companion pre-owner loss leaves recognized orphan until separate guarded startup" do
    Live.with_fixture(fn f ->
      config = Live.export_config(f, %{barriers: [:task_first_clock]})
      {requester, requester_monitor} = requester!(f, config)
      companion = barrier!(f, :task_first_clock)
      assert Task.Supervisor.children(f.supervisor) == [companion]

      assert [name] =
               Enum.filter(
                 File.ls!(f.roots.artifact),
                 &String.starts_with?(&1, "knowledge-export-")
               )

      orphan = Path.join(f.roots.artifact, name)
      marker = File.read!(Path.join(orphan, ".ownership"))
      assert is_map(Jason.decode!(marker))
      monitor = Process.monitor(companion)
      Process.exit(companion, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^companion, :killed}, 5_000
      assert {:error, :storage_unavailable} = await_result!(requester)
      stop_requester!(requester, requester_monitor)
      assert Task.Supervisor.children(f.supervisor) == []
      assert Observer.issued(f) == %{}
      refute Enum.any?(Observer.events(f), &(&1.point == :before_native_lease))
      assert File.read!(Path.join(orphan, ".ownership")) == marker

      f.with_preowner_recovery.(__MODULE__.GuardedStartup, fn starter ->
        refute Process.alive?(f.supervisor)
        refute Process.alive?(f.infrastructure)
        assert Process.whereis(Singularity.Runtime.UploadRecoveryTaskSupervisor) == nil
        assert File.read!(Path.join(orphan, ".ownership")) == marker
        assert {:ok, startup} = starter.()
        assert Process.alive?(startup)
        assert {:error, :enoent} = File.lstat(orphan)
        assert File.read!(Path.join(f.roots.artifact, "foreign-neighbor")) == "foreign unchanged"

        assert File.read!(Path.join([f.roots.artifact, "malformed-neighbor", "sentinel"])) ==
                 "malformed unchanged"
      end)

      assert Process.whereis(__MODULE__.GuardedStartup) == nil
      Live.assert_quiescent!(f)
    end)
  end

  @tag :tmp_dir
  test "independent offline oracle rejects each causal corruption after a passing positive", %{
    tmp_dir: tmp
  } do
    mutations = [
      {:missing_file, "file inventory boundary",
       fn root, e, _ ->
         File.rm!(Path.join(root, note_path(1)))
         e
       end},
      {:extra_file, "file inventory boundary",
       fn root, e, _ ->
         File.write!(Path.join(root, "extra"), "extra")
         e
       end},
      {:bytes, "file hash boundary",
       fn root, e, _ ->
         File.write!(
           Path.join(root, note_path(1)),
           String.duplicate("x", File.stat!(Path.join(root, note_path(1))).size)
         )

         e
       end},
      {:hash, "file hash boundary",
       fn root, e, m ->
         files =
           Enum.map(m["files"], fn r ->
             if r["path"] == note_path(1),
               do: Map.put(r, "sha256", String.duplicate("0", 64)),
               else: r
           end)

         rewrite_manifest!(root, e, Map.put(m, "files", files))
       end},
      {:size, "file size boundary",
       fn root, e, m ->
         files =
           Enum.map(m["files"], fn r ->
             if r["path"] == note_path(1), do: Map.update!(r, "byte_size", &(&1 + 1)), else: r
           end)

         rewrite_manifest!(root, e, Map.put(m, "files", files))
       end},
      {:reference, "citation fragment boundary",
       fn root, e, m ->
         citations =
           Enum.map(m["citations"], &Map.put(&1, "fragment_id", String.duplicate("f", 64)))

         rewrite_manifest!(root, e, Map.put(m, "citations", citations))
       end},
      {:wrong_existing_source_file, "exact source link boundary",
       fn root, e, m ->
         path = note_path(1)

         bytes =
           File.read!(Path.join(root, path))
           |> String.replace("../documents/extracted/", "../documents/originals/")

         File.write!(Path.join(root, path), bytes)
         refresh_file!(root, e, m, path)
       end},
      {:link, "relative link boundary",
       fn root, e, m ->
         path = note_path(1)

         bytes =
           File.read!(Path.join(root, path))
           |> String.replace("../documents/extracted/", "../../outside/")

         File.write!(Path.join(root, path), bytes)
         refresh_file!(root, e, m, path)
       end},
      {:footnote, "footnote definition boundary",
       fn root, e, m ->
         path = note_path(1)

         bytes =
           File.read!(Path.join(root, path))
           |> String.replace("[^singularity-source-#{uuid(99)}]: ", "[missing-definition]: ")

         File.write!(Path.join(root, path), bytes)
         refresh_file!(root, e, m, path)
       end},
      {:multibyte_offset, "fragment byte offset boundary",
       fn root, e, m ->
         fragments =
           Enum.map(m["fragments"], fn r ->
             if r["ordinal"] == 1, do: Map.put(r, "start_byte", String.length("界😀")), else: r
           end)

         rewrite_manifest!(root, e, Map.put(m, "fragments", fragments))
       end}
    ]

    for {name, boundary, mutate} <- mutations do
      root = Path.join(tmp, to_string(name))
      {expected, manifest} = offline_positive!(root)
      Offline.verify!(root, expected)
      expected = mutate.(root, expected, manifest)
      error = assert_raise ExUnit.AssertionError, fn -> Offline.verify!(root, expected) end
      assert error.message =~ boundary
    end
  end

  for count <- [1, 501] do
    test "same schema model checks small and >500-entry genuine Api captures and exact deterministic bytes (count=#{count})" do
      count = unquote(count)
      model_started_at = System.monotonic_time(:millisecond)

      model_phase = fn phase, ordinal ->
        elapsed = System.monotonic_time(:millisecond) - model_started_at

        IO.puts(
          "Task17 model phase=#{phase} count=#{count} ordinal=#{ordinal} elapsed_ms=#{elapsed}"
        )
      end

      model_phase.(:fixture_start, 0)

      large_fixture(fn f ->
        model_phase.(:fixture_ready, 0)
        # The pending Document has no extracted fragments or citations. Charge
        # the companion Note and each actual Note input, independently of the
        # observed counter or journal lengths; retain only the numeric sum.
        model_phase.(:notes_begin, 0)

        expected_temporary_bytes =
          Enum.reduce(1..count, byte_size("Large source"), fn n, temporary_bytes ->
            body = if n == 1, do: String.duplicate("x", 1_048_576), else: "Bounded note #{n}"
            assert byte_size(body) <= 1_048_576

            assert {:ok, _} =
                     Api.create_note(f.session, %{
                       mutation_id: Ecto.UUID.generate(),
                       title: "Bounded #{n}",
                       markdown: body
                     })

            temporary_bytes + byte_size(body)
          end)

        assert expected_temporary_bytes == if(count == 1, do: 1_048_588, else: 1_056_482)
        model_phase.(:notes_done, 0)

        parent = self()
        token = make_ref()

        summarize = fn capture ->
          try do
            summary = RetainedModel.sealed!(capture, expected_temporary_bytes)

            for wrong_charge <- [expected_temporary_bytes - 1, expected_temporary_bytes + 1] do
              RetainedModel.sealed!(capture, expected_temporary_bytes)

              error =
                assert_raise ExUnit.AssertionError, fn ->
                  RetainedModel.sealed!(capture, wrong_charge)
                end

              assert error.message =~ "temporary plaintext accounting boundary"
            end

            send(parent, {:task17_model, token, summary})
          rescue
            error ->
              classifier =
                if match?(%ExUnit.AssertionError{}, error), do: :assertion, else: :exception

              model_source_line =
                Enum.find_value(__STACKTRACE__, 0, fn
                  {RetainedModel, _, _, location} -> Keyword.get(location, :line)
                  _ -> nil
                end)

              IO.puts(
                "Task17 actual Api model failure classifier=#{classifier} model_source_line=#{model_source_line}"
              )

              reraise error, __STACKTRACE__
          end
        end

        {:ok, writes} = Agent.start_link(fn -> %{count: 0, largest: 0} end)

        write = fn device, bytes ->
          Agent.update(
            writes,
            &%{count: &1.count + 1, largest: max(&1.largest, byte_size(bytes))}
          )

          IO.binwrite(device, bytes)
        end

        config = Live.export_config(f, %{summarize_capture: summarize, write: write})
        model_phase.(:export_begin, 1)
        assert {:ok, first_handle} = Api.export_knowledge(config, f.session, %{})
        model_phase.(:export_done, 1)
        assert_receive {:task17_model, ^token, first_summary}, 5_000
        model_phase.(:materialize_begin, 1)
        first = Live.materialize!(f, config, first_handle)
        model_phase.(:materialize_done, 1)
        model_phase.(:export_begin, 2)
        assert {:ok, second_handle} = Api.export_knowledge(config, f.session, %{})
        model_phase.(:export_done, 2)
        refute first_handle.operation_ref == second_handle.operation_ref
        assert_receive {:task17_model, ^token, second_summary}, 5_000
        model_phase.(:materialize_begin, 2)
        second = Live.materialize!(f, config, second_handle)
        model_phase.(:materialize_done, 2)
        model_phase.(:comparison_begin, 0)
        refute first.root == second.root
        assert first.entries == second.entries
        assert Offline.inventory(first.root) == Offline.inventory(second.root)

        for path <- Offline.inventory(first.root),
            do:
              assert(
                File.read!(Path.join(first.root, path)) ==
                  File.read!(Path.join(second.root, path))
              )

        assert first_summary.counts == second_summary.counts
        assert first_summary.coefficients == RetainedModel.coefficients()

        IO.puts(
          "Task17 actual Api retained model #{count}: " <>
            inspect(Map.drop(first_summary, [:coefficients]), limit: :infinity)
        )

        assert first_summary.original_bytes >= byte_size(f.large_original)
        assert first_summary.selected_keys > count
        if count > 500, do: assert(map_size(first.entries) > 500)

        for event <- Observer.events(f),
            event.point == :public_page,
            do: assert(event.count <= 500)

        for event <- Observer.events(f),
            event.point == :public_chunk,
            do: assert(event.byte_size <= @chunk)

        for event <- Observer.events(f), event.point == :native_piece do
          assert event.byte_size <= if(event.kind == :document, do: 4_194_304, else: @chunk)
        end

        assert Enum.any?(
                 Observer.events(f),
                 &(&1.point == :native_piece and &1.kind == :document and
                     &1.byte_size == 4_194_304)
               )

        assert Enum.any?(
                 Observer.events(f),
                 &(&1.point == :native_piece and &1.kind == :document and
                     &1.byte_size == byte_size(f.large_original) - 4_194_304)
               )

        observed_writes = Agent.get(writes, & &1)
        assert observed_writes.count > 0 and observed_writes.largest <= @chunk
        Agent.stop(writes)
        model_phase.(:comparison_done, 0)
        model_phase.(:quiescence_begin, 0)
        Live.assert_quiescent!(f)
        model_phase.(:quiescence_done, 0)
      end)

      model_phase.(:fixture_return, 0)
    end
  end

  @tag :tmp_dir
  test "real Spool and Writer use the same executable family bounds with long locator and MIME backing",
       %{tmp_dir: tmp} do
    assert 19 * (2 + 6 * 23 + 1 + (2 + 6 * 255)) + 18 + 2 == 31_807
    coefficients = RetainedModel.coefficients()
    IO.puts("Task17 retained-index coefficients: " <> inspect(coefficients, limit: :infinity))
    assert Enum.all?(coefficients, fn {_, value} -> is_integer(value) and value > 0 end)

    for count <- [1, 501] do
      f = model_fixture!(Path.join(tmp, "model-#{count}"), count)

      try do
        summary = RetainedModel.sealed!(f.capture)
        assert summary.coefficients == coefficients
        assert model_capture_digests!(f) == %{text: count, render: count, binary: 1}
        # Causal model mutations use copies that are never consumed by Writer.
        for {mutant, boundary} <- [
              {put_in(
                 f.capture,
                 [:_versions, {uuid(1), uuid(1001)}, "body"],
                 "forbidden content"
               ), "retained schema boundary"},
              {Map.put(
                 f.capture,
                 :text_refs,
                 Map.put(f.capture.text_refs, {:unknown, uuid(1), uuid(1001)}, %{})
               ), "text ref family boundary"},
              {put_in(
                 f.capture,
                 [:text_refs, {:note_markdown, uuid(1), uuid(1001)}, :selector],
                 {:note_markdown, uuid(2), uuid(1002)}
               ), "typed ref boundary"},
              {put_in(
                 f.capture,
                 [:_versions, {uuid(1), uuid(1001)}, "extracted_digest"],
                 String.duplicate("a", 65)
               ), "retained digest boundary"},
              {put_in(f.capture, [:accounting, :selected_keys], 0), "selected count boundary"}
            ] do
          RetainedModel.sealed!(f.capture)
          error = assert_raise ExUnit.AssertionError, fn -> RetainedModel.sealed!(mutant) end
          assert error.message =~ boundary
        end

        assert {:ok, writer} =
                 Writer.open(%{
                   root: f.roots.writer,
                   storage_root: f.roots.storage,
                   backup_root: f.roots.backup,
                   capture: f.capture,
                   options: %{include_tombstones: false},
                   original_fold: fn selector, acc, emit ->
                     assert selector == {:original, :asset, uuid(900), uuid(1900)}
                     emit.("original", acc)
                   end
                 })

        RetainedModel.writer_build!(writer)

        writer =
          Enum.reduce(@collections, writer, fn collection, current ->
            Enum.reduce(Map.fetch!(f.records, collection), current, fn record, acc ->
              assert {:ok, next} = Writer.append_manifest_record(acc, collection, record)
              next
            end)
          end)

        assert {:ok, writer} =
                 Writer.append_file(
                   writer,
                   {:original, :asset, uuid(900), uuid(1900)},
                   :authenticated
                 )

        writer =
          Enum.reduce(1..count, writer, fn n, current ->
            selector = {:note_markdown, uuid(n), uuid(n + 1000)}

            assert {:ok, next} =
                     Writer.append_file(
                       current,
                       selector,
                       Map.fetch!(f.capture.text_refs, selector)
                     )

            next
          end)

        build = RetainedModel.writer_build!(writer)
        assert build.counts.captured == summary.counts.c
        assert model_record_digests!(writer, f.records) == 2 * count + 5

        assert model_output_digests!(writer, f, :staging) ==
                 %{output: count + 1, nonempty_chunk: count + 1, empty_chunk: 0}

        assert {:ok, artifact} = Writer.finish(writer)

        try do
          published = RetainedModel.published!(artifact)
          reservation = Agent.get(f.clock_observer, & &1)
          assert reservation.observations > 0 and reservation.maximum_rows == 1
          assert reservation.maximum_bytes > 0

          IO.puts(
            "Task17 real Writer retained model #{count}: " <>
              inspect(%{build: build, published: published, reservation: reservation},
                limit: :infinity
              )
          )

          assert published.o == count + 2
          assert published.backing_allowance == 3 * published.o * 31_807
          assert Enum.any?(RetainedModel.binaries(artifact._outputs), &(byte_size(&1) > 64))
          digests = model_output_digests!(artifact, f, :complete)
          assert digests.output == count + 2

          assert digests.nonempty_chunk ==
                   count + 1 +
                     max(1, div(artifact.manifest["byte_size"] + @chunk - 1, @chunk))

          assert digests.empty_chunk == 0

          IO.puts(
            "Task17 compiled Writer digest families: " <>
              inspect(%{
                text: count,
                render: count,
                binary: 1,
                record: 2 * count + 5,
                output: digests.output,
                nonempty_chunk: digests.nonempty_chunk,
                empty_chunk: digests.empty_chunk
              })
          )

          assert Enum.any?(:ets.tab2list(artifact._ledger), fn
                   {{:file, "assets/" <> _}, _} -> true
                   _ -> false
                 end)
        after
          assert :ok = Writer.abort(artifact)
        end
      after
        assert :ok = Spool.abort(f.capture)
        Agent.stop(f.clock_observer)
        assert {:ok, _} = File.rm_rf(f.root)
      end
    end
  end

  @tag :tmp_dir
  test "real Writer retains the known empty-original output and canonical empty chunk digest",
       %{tmp_dir: tmp} do
    f = model_fixture!(Path.join(tmp, "empty-digests"), 1, "")

    try do
      RetainedModel.sealed!(f.capture)
      assert model_capture_digests!(f) == %{text: 1, render: 1, binary: 1}

      assert {:ok, writer} =
               Writer.open(%{
                 root: f.roots.writer,
                 storage_root: f.roots.storage,
                 backup_root: f.roots.backup,
                 capture: f.capture,
                 options: %{include_tombstones: false},
                 original_fold: fn selector, acc, _emit ->
                   assert selector == {:original, :asset, uuid(900), uuid(1900)}
                   {:ok, acc}
                 end
               })

      writer =
        Enum.reduce(@collections, writer, fn collection, current ->
          Enum.reduce(Map.fetch!(f.records, collection), current, fn record, acc ->
            assert {:ok, next} = Writer.append_manifest_record(acc, collection, record)
            next
          end)
        end)

      assert model_record_digests!(writer, f.records) == 7

      assert {:ok, writer} =
               Writer.append_file(
                 writer,
                 {:original, :asset, uuid(900), uuid(1900)},
                 :authenticated
               )

      selector = {:note_markdown, uuid(1), uuid(1001)}

      assert {:ok, writer} =
               Writer.append_file(writer, selector, Map.fetch!(f.capture.text_refs, selector))

      RetainedModel.writer_build!(writer)

      assert model_output_digests!(writer, f, :staging) ==
               %{output: 2, nonempty_chunk: 1, empty_chunk: 1}

      assert {:ok, artifact} = Writer.finish(writer)

      try do
        RetainedModel.published!(artifact)
        digests = model_output_digests!(artifact, f, :complete)
        assert digests == %{output: 3, nonempty_chunk: 2, empty_chunk: 1}

        IO.puts(
          "Task17 compiled Writer empty digest families: " <>
            inspect(Map.merge(digests, %{text: 1, render: 1, binary: 1, record: 7}))
        )
      after
        assert :ok = Writer.abort(artifact)
      end
    after
      assert :ok = Spool.abort(f.capture)
      Agent.stop(f.clock_observer)
      assert {:ok, _} = File.rm_rf(f.root)
    end
  end

  test "source confines internal pages framing streaming and separate one-Note working sets" do
    source = Path.expand("../../../lib/singularity/runtime/knowledge/export.ex", __DIR__)
    assert File.read!(source) =~ "Spool.reduce_metadata"

    for relative <- [
          "knowledge_export/spool.ex",
          "knowledge_export/writer.ex",
          "knowledge_export/repository.ex"
        ] do
      path =
        Path.expand(
          "../../../../singularity_storage/lib/singularity/storage/" <> relative,
          __DIR__
        )

      bytes = File.read!(path)

      for [_, expression] <- Regex.scan(~r/Enum\.to_list\(([^\n]*)/, bytes),
          do: assert(expression == "0..(count - 1))")

      refute bytes =~ ~r/read\([^\n]*:all/
    end

    # Explicit separate working-set ceilings, not a heap/RSS/GC assertion.
    limits = %{
      canonical_note: 1_048_576,
      rendered_note: 16_777_216,
      attachments: 100,
      citations: 100,
      combined_targets: 100,
      aggregate_source_titles: 16_777_216,
      label_bytes: 255,
      markdown_headings: 64,
      heading_bytes: 255,
      native_document_record: 4_194_304,
      consumer_piece: 65_536,
      selected_sort_members: 100_000,
      metadata_records: 1_000_000
    }

    assert limits.attachments + limits.citations == 200
    # Sixfold escaping is per raw byte. IDs/hrefs/reference labels and their
    # punctuation are separately finite, bounded by 200 typed references.
    descriptions =
      6 *
        (limits.aggregate_source_titles + 100 * limits.label_bytes +
           limits.citations * limits.markdown_headings * limits.heading_bytes) +
        200 * (6 * 255 + 8 * 36 + 64 + 128)

    assert descriptions > limits.aggregate_source_titles
    assert limits.native_document_record > limits.consumer_piece
  end

  # TASK17_ABORT_LIFECYCLE_REGRESSIONS_BEGIN
  test "fixture caller kill restores native traces settings helpers and exact qualified child" do
    controller = self()
    token = make_ref()
    apps = [:singularity_runtime, :singularity_storage]
    original_env = Map.new(apps, &{&1, Map.new(Application.get_all_env(&1))})
    configured_root = System.fetch_env("SINGULARITY_TASK16_FIXTURE_ROOT")
    identity_keys = [:major_device, :minor_device, :inode, :uid, :gid, :mode, :type]

    identity = fn path ->
      case File.lstat(path) do
        {:ok, stat} -> {:ok, Map.take(stat, identity_keys)}
        error -> error
      end
    end

    targets = [
      {Singularity.Runtime.KeyLeaseSupervisor, :start_download_lease, 2},
      {Singularity.Runtime.DownloadLease, :revoke, 1}
    ]

    trace_state = fn target ->
      {:erlang.trace_info(target, :match_spec), :erlang.trace_info(target, :traced)}
    end

    expected_installed = %{
      Enum.at(targets, 0) =>
        {{:match_spec, [{:_, [], [{:message, false}, {:return_trace}]}]}, {:traced, :local}},
      Enum.at(targets, 1) => {{:match_spec, [{:_, [], [{:return_trace}]}]}, {:traced, :local}}
    }

    caller =
      spawn(fn ->
        try do
          refute match?({:ok, _}, ExUnit.fetch_test_supervisor()),
                 "abort caller unexpectedly owns an ExUnit supervisor"

          Live.with_fixture(fn f ->
            # Publish identities before import/graph/export; never send the Session or fixture.
            resources = %{
              owner: f.owner,
              infrastructure: f.infrastructure,
              private: f.supervisor,
              collector: f.lease_tracker,
              control: f.observer.control,
              custodian: Process.whereis(Singularity.Runtime.KeyCustodian),
              qualified: f.roots.qualified,
              native_root: Path.dirname(f.destination.object_root)
            }

            send(controller, {token, :resources, self(), resources})

            receive do
              {^token, :bound} -> :ok
            after
              5_000 -> flunk("abort controller did not bind identities")
            end

            f = f |> Live.publish_sources!() |> Live.build_graph!()
            originals = Map.new(targets, &{&1, trace_state.(&1)})

            original_custodian = {
              :erlang.trace_info(resources.custodian, :flags),
              :erlang.trace_info(resources.custodian, :tracer)
            }

            pristine_patterns? =
              Enum.all?(originals, fn {_, state} ->
                state == {{:match_spec, false}, {:traced, false}}
              end)

            pristine_custodian? = original_custodian == {{:flags, []}, {:tracer, []}}

            assert pristine_patterns? and pristine_custodian?,
                   "abort original trace state is not pristine"

            config = Live.export_config(f, %{})
            assert {:ok, handle} = Api.export_knowledge(config, f.session, %{})

            companions =
              f
              |> Observer.events()
              |> Enum.filter(&(&1.point == :before_native_lease))
              |> Enum.map(& &1.companion)
              |> Enum.uniq()

            assert [companion] = companions
            operation_owner = handle.owner

            assert Process.alive?(operation_owner) and Process.alive?(companion),
                   "abort operation identities were not live before materialization"

            operation_monitors =
              Enum.map([operation_owner, companion], fn pid ->
                {pid, Process.monitor(pid)}
              end)

            materialized = Live.materialize!(f, config, handle)
            Offline.verify!(materialized.root, expectation(f, materialized.entries, false))
            Live.assert_quiescent!(f)
            :ok = IssuedLeases.sync(f.lease_tracker)
            operation_deadline = System.monotonic_time(:millisecond) + 5_000

            operation_down =
              Enum.map(operation_monitors, fn {pid, monitor} ->
                receive do
                  {:DOWN, ^monitor, :process, ^pid, reason} -> reason not in [:noproc, :missing]
                after
                  max(0, operation_deadline - System.monotonic_time(:millisecond)) -> false
                end
              end)

            operation_terminal? = operation_down == [true, true]
            assert operation_terminal?, "abort exact live-monitored owner/companion DOWN absent"

            positive_witnesses = fn ->
              events = Observer.events(f)
              leases = Map.keys(Observer.issued(f))

              down? = fn lease ->
                Enum.any?(events, &(&1.point == :native_down and &1.lease == lease))
              end

              ack? = fn lease ->
                Enum.any?(
                  events,
                  &(&1.point == :native_revoke_ack and
                      &1.lease == lease and &1.outcome == :ok)
                )
              end

              %{
                positives: %{
                  issued: leases != [],
                  native_bytes:
                    Enum.any?(events, &(&1.point == :native_piece and &1.byte_size > 0)),
                  public_files: map_size(materialized.entries) > 1,
                  public_pages: Enum.any?(events, &(&1.point == :public_page and &1.count > 0)),
                  public_bytes:
                    Enum.any?(events, &(&1.point == :public_chunk and &1.byte_size > 0)),
                  actual_revoke_ack: Enum.any?(leases, ack?),
                  terminal:
                    Enum.all?(leases, &(down?.(&1) and (ack?.(&1) or operation_terminal?)))
                },
                terminal_counts: %{
                  issued: length(leases),
                  native_issued: Enum.count(events, &(&1.point == :native_issued)),
                  missing_down: Enum.count(leases, &(not down?.(&1))),
                  missing_ack: Enum.count(leases, &(not ack?.(&1)))
                }
              }
            end

            readiness_deadline = System.monotonic_time(:millisecond) + 5_000

            await_witnesses = fn await_witnesses ->
              actual = positive_witnesses.()
              remaining = max(0, readiness_deadline - System.monotonic_time(:millisecond))

              if Enum.all?(actual.positives, fn {_, value} -> value == true end) or remaining == 0 do
                actual
              else
                receive do
                  {:knowledge_export, event_token, point, _, _}
                  when event_token == f.observer.token and
                         point in [:native_issued, :native_down, :native_revoke_ack] ->
                    await_witnesses.(await_witnesses)
                after
                  remaining -> positive_witnesses.()
                end
              end
            end

            actual_witnesses = await_witnesses.(await_witnesses)
            positives = actual_witnesses.positives
            IO.puts("Task17 abort actual positive witnesses: " <> inspect(positives))

            IO.puts(
              "Task17 abort actual terminal counts: " <> inspect(actual_witnesses.terminal_counts)
            )

            send(
              controller,
              {token, :ready, self(),
               %{
                 originals: originals,
                 original_custodian: original_custodian,
                 installed: Map.new(targets, &{&1, trace_state.(&1)}),
                 tracer:
                   {:erlang.trace_info(resources.custodian, :flags),
                    :erlang.trace_info(resources.custodian, :tracer)},
                 positives: positives
               }}
            )

            # This callback must never return normally; the controller really kills it.
            receive do
              {^token, :unexpected_release} -> flunk("abort caller unexpectedly released")
            end
          end)
        rescue
          _ -> send(controller, {token, :setup_failed, self(), :exception})
        catch
          _, _ -> send(controller, {token, :setup_failed, self(), :exit})
        end
      end)

    stop_caller = fn ->
      monitor = Process.monitor(caller)
      if Process.alive?(caller), do: Process.exit(caller, :kill)

      receive do
        {:DOWN, ^monitor, :process, ^caller, _} -> :ok
      after
        5_000 -> flunk("exact abort caller did not stop")
      end
    end

    on_exit(stop_caller)
    caller_monitor = Process.monitor(caller)

    resources =
      receive do
        {^token, :resources, ^caller, resources} ->
          resources

        {^token, :setup_failed, ^caller, _} ->
          flunk("abort fixture acquisition failed")

        {:DOWN, ^caller_monitor, :process, ^caller, _} ->
          flunk("abort fixture caller exited during setup")
      after
        60_000 -> flunk("abort fixture identities not published; setup failure")
      end

    owner = resources.owner

    on_exit(fn ->
      stop_caller.()
      monitor = Process.monitor(owner)

      receive do
        {:DOWN, ^monitor, :process, ^owner, _} -> :ok
      after
        5_000 -> flunk("exact abort resource owner did not finish")
      end
    end)

    helpers =
      Map.take(resources, [:owner, :infrastructure, :private, :collector, :control, :custodian])

    assert Enum.all?(helpers, fn {_, pid} -> is_pid(pid) and Process.alive?(pid) end)
    monitors = Map.new(helpers, fn {kind, pid} -> {kind, {pid, Process.monitor(pid)}} end)
    qualified = resources.qualified
    parent = Path.dirname(qualified)
    external? = match?({:ok, _}, configured_root)

    expected_parent =
      case configured_root do
        {:ok, root} -> root
        :error -> resources.native_root
      end

    canonical? =
      Enum.all?([qualified, parent, resources.native_root], fn path ->
        Path.type(path) == :absolute and Path.expand(path) == path
      end)

    expected_child? =
      if external? do
        Regex.match?(~r/\A[0-9a-f]{32}\z/, Path.basename(qualified))
      else
        qualified == Path.join(resources.native_root, "task17")
      end

    assert canonical? and parent == expected_parent and expected_child?,
           "abort qualified child is not bound to its actual native/external parent"

    chain_paths = parent |> Path.split() |> Enum.scan(&Path.join(&2, &1))
    chain = Enum.map(chain_paths, &{&1, identity.(&1)})
    assert Enum.all?(chain, fn {_, result} -> match?({:ok, %{type: :directory}}, result) end)
    parent_identity = identity.(parent)
    child_identity = identity.(qualified)
    assert match?({:ok, %{type: :directory}}, child_identity)
    # Native cleanup owns/removes the fallback parent. Its foreign siblings and
    # stable ancestors remain protected; fallback containment never removes it.
    boundary = if external?, do: parent, else: Path.dirname(parent)
    excluded_name = Path.basename(if external?, do: qualified, else: parent)
    stable_chain = if external?, do: chain, else: Enum.drop(chain, -1)

    same_chain? = fn ->
      Enum.all?(stable_chain, fn {path, before} -> identity.(path) == before end)
    end

    parent_owned? = fn ->
      identity.(parent) == parent_identity or
        (not external? and identity.(parent) == {:error, :enoent})
    end

    # lstat immediate foreign entries only: no recursive listing or content reads.
    siblings_state = fn ->
      case File.ls(boundary) do
        {:ok, names} ->
          entries =
            Map.new(names -- [excluded_name], fn name ->
              {name, identity.(Path.join(boundary, name))}
            end)

          if Enum.all?(entries, fn {_, state} -> match?({:ok, _}, state) end),
            do: {:ok, entries},
            else: {:error, :entry_changed}

        _ ->
          {:error, :inspection_failed}
      end
    end

    sibling = Path.join(boundary, ".task17-abort-sibling-" <> Ecto.UUID.generate())
    assert same_chain?.() and identity.(parent) == parent_identity
    File.write!(sibling, "abort sibling unchanged", [:exclusive])
    File.chmod!(sibling, 0o600)
    sibling_identity = identity.(sibling)

    sentinel_state = fn ->
      if identity.(sibling) == sibling_identity,
        do: File.read(sibling),
        else: {:error, :identity_changed}
    end

    on_exit(fn ->
      intact? =
        same_chain?.() and identity.(sibling) == sibling_identity and
          sentinel_state.() == {:ok, "abort sibling unchanged"}

      assert intact?, "abort owned sibling identity/bytes changed; retained"
      File.rm!(sibling)
    end)

    siblings = siblings_state.()
    assert match?({:ok, _}, siblings), "abort immediate sibling snapshot failed"
    assert sentinel_state.() == {:ok, "abort sibling unchanged"}
    send(caller, {token, :bound})

    ready =
      receive do
        {^token, :ready, ^caller, ready} ->
          ready

        {^token, :setup_failed, ^caller, _} ->
          flunk("abort positive operations failed; not behavioral RED")

        {:DOWN, ^caller_monitor, :process, ^caller, _} ->
          flunk("abort caller exited before READY")
      after
        60_000 -> flunk("abort positive witnesses absent; not behavioral RED")
      end

    assert Enum.all?(ready.positives, fn {_, value} -> value == true end),
           "abort genuine Api/native terminal prerequisites missing"

    installed_owned? = ready.installed == expected_installed
    tracer_owned? = ready.tracer == {{:flags, [:call]}, {:tracer, resources.collector}}
    assert installed_owned? and tracer_owned?, "abort trace ownership prerequisites missing"

    Process.exit(caller, :kill)
    deadline = System.monotonic_time(:millisecond) + 5_000

    caller_reason =
      receive do
        {:DOWN, ^caller_monitor, :process, ^caller, reason} -> reason
      after
        max(0, deadline - System.monotonic_time(:millisecond)) -> :missing
      end

    downs =
      Map.new(monitors, fn {kind, {pid, monitor}} ->
        reason =
          receive do
            {:DOWN, ^monitor, :process, ^pid, reason} -> reason
          after
            max(0, deadline - System.monotonic_time(:millisecond)) -> :missing
          end

        {kind, reason}
      end)

    # Collect ALL real post-state before a fixed-boolean assertion or containment.
    post_env = Map.new(apps, &{&1, Map.new(Application.get_all_env(&1))})
    post_patterns = Map.new(targets, &{&1, trace_state.(&1)})

    post_custodian = {
      :erlang.trace_info(resources.custodian, :flags),
      :erlang.trace_info(resources.custodian, :tracer)
    }

    post_child = File.lstat(qualified)
    post_parent = identity.(parent)
    post_sentinel = sentinel_state.()
    post_chain = same_chain?.()
    post_siblings = siblings_state.()

    facts = %{
      caller_killed: caller_reason == :killed,
      owner_down: downs.owner not in [:missing, :noproc],
      owner_clean: downs.owner == :normal,
      helpers_down: Enum.all?(downs, fn {_, reason} -> reason not in [:missing, :noproc] end),
      exact_environments: post_env == original_env,
      exact_patterns: post_patterns == ready.originals,
      dead_custodian_untraced: post_custodian == {:undefined, :undefined},
      child_absent: post_child == {:error, :enoent},
      parent_chain: post_chain,
      native_parent_removed: external? or post_parent == {:error, :enoent},
      siblings_unchanged: post_siblings == siblings,
      owned_sentinel_unchanged: post_sentinel == {:ok, "abort sibling unchanged"}
    }

    IO.puts("Task17 abort actual post-state: " <> inspect(facts))

    try do
      assert Enum.all?(facts, fn {_, value} -> value == true end),
             "fixture caller abort left residue; all fixed post-state facts collected"
    after
      # Containment AFTER failed evaluation earns no cleanup credit. Preflight every
      # target and the exact path before making ANY trace or filesystem mutation.
      if Enum.any?(facts, fn {_, value} -> value != true end) do
        current_patterns = Map.new(targets, &{&1, trace_state.(&1)})

        dead_owned =
          Enum.all?(helpers, fn {kind, pid} ->
            downs[kind] not in [:missing, :noproc] and not Process.alive?(pid)
          end)

        owned_patterns =
          Enum.all?(targets, fn target ->
            current_patterns[target] in [ready.originals[target], expected_installed[target]]
          end)

        owned_child = identity.(qualified) in [child_identity, {:error, :enoent}]

        safe =
          caller_reason == :killed and dead_owned and owned_patterns and
            same_chain?.() and parent_owned?.() and owned_child and
            siblings_state.() == siblings and
            sentinel_state.() == {:ok, "abort sibling unchanged"}

        if safe do
          for target <- targets, current_patterns[target] == expected_installed[target] do
            :erlang.trace_pattern(target, false, [:local])
          end

          if identity.(parent) == parent_identity and identity.(qualified) == child_identity do
            case File.rm_rf(qualified) do
              {:ok, _} -> :ok
              _ -> flunk("abort fallback exact child removal failed")
            end
          end

          contained? = File.lstat(qualified) == {:error, :enoent}
          assert contained?, "abort fallback exact child remains"
          restored? = Map.new(targets, &{&1, trace_state.(&1)}) == ready.originals
          assert restored?, "abort fallback did not restore exact owned patterns"

          intact? =
            same_chain?.() and parent_owned?.() and siblings_state.() == siblings and
              sentinel_state.() == {:ok, "abort sibling unchanged"}

          assert intact?, "abort fallback changed parent or siblings"
          IO.puts("Task17 abort owned fallback containment completed; no acceptance credit")
        else
          flunk("abort fallback ownership not proved; foreign state retained")
        end
      end
    end
  end

  for route <- [:configured_native, :default_admission, :partial_grant] do
    test "fixture caller abort owns actual cleanup for #{route}" do
      abort_extra_case!(unquote(route))
    end
  end

  test "native trace acquisition preflight preserves exact foreign patterns and custodian tracer" do
    Live.with_fixture(fn f ->
      custodian = Process.whereis(Singularity.Runtime.KeyCustodian)

      targets = [
        {Singularity.Runtime.KeyLeaseSupervisor, :start_download_lease, 2},
        {Singularity.Runtime.DownloadLease, :revoke, 1}
      ]

      state = fn ->
        %{
          patterns:
            Map.new(targets, fn target ->
              {target,
               {:erlang.trace_info(target, :match_spec), :erlang.trace_info(target, :traced)}}
            end),
          flags: :erlang.trace_info(custodian, :flags),
          tracer: :erlang.trace_info(custodian, :tracer)
        }
      end

      baseline = state.()

      originals =
        Map.new(baseline.patterns, fn {target, {match_spec, traced}} ->
          {target, %{match_spec: match_spec, traced: traced}}
        end)

      assert IssuedLeases.assert_unowned!(custodian) == originals
      foreign = [{:_, [], [{:message, false}]}]

      for target <- targets do
        :erlang.trace_pattern(target, foreign, [:local])
        installed = state.()

        try do
          assert_raise ExUnit.AssertionError, fn ->
            IssuedLeases.assert_unowned!(custodian)
          end

          assert state.() == installed

          for other <- targets -- [target] do
            assert installed.patterns[other] == baseline.patterns[other]
          end

          assert installed.flags == baseline.flags and installed.tracer == baseline.tracer
        after
          assert state.() == installed, "foreign preflight changed ownership; retained"
          :erlang.trace_pattern(target, false, [:local])
          assert state.() == baseline
        end
      end

      tracer =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      tracer_monitor = Process.monitor(tracer)

      try do
        assert 1 = :erlang.trace(custodian, true, [:procs, {:tracer, tracer}])
        installed = state.()
        assert installed.flags == {:flags, [:procs]}
        assert installed.tracer == {:tracer, tracer}

        assert_raise ExUnit.AssertionError, fn ->
          IssuedLeases.assert_unowned!(custodian)
        end

        assert state.() == installed
        assert installed.patterns == baseline.patterns
      after
        assert :erlang.trace_info(custodian, :flags) == {:flags, [:procs]}
        assert :erlang.trace_info(custodian, :tracer) == {:tracer, tracer}
        assert 1 = :erlang.trace(custodian, false, [:procs])
        send(tracer, :stop)
        assert_receive {:DOWN, ^tracer_monitor, :process, ^tracer, :normal}, 5_000
        assert state.() == baseline
      end

      Live.assert_quiescent!(f)
    end)
  end

  test "ordinary native collector sync folds real queued issuance ACK and already-monitored DOWN" do
    abort_extra_queued_fixture!(fn f ->
      :ok = IssuedLeases.enable(f.lease_tracker)
      caller = self()
      native_gate = make_ref()

      config =
        Live.export_config(f, %{
          on_event: fn point, values ->
            if point == :native_piece and values.kind == :document and
                 values.byte_size > 0 and
                 not Process.get({__MODULE__, native_gate, :native_gate}, false) do
              Process.put({__MODULE__, native_gate, :native_gate}, true)
              send(caller, {:task17_queued_document_piece, native_gate, self(), values.lease})

              receive do
                {:task17_queued_document_continue, ^native_gate, ^caller} -> :ok
              after
                5_000 -> flunk("queued Document native controller did not release actual read")
              end
            end
          end
        })

      {requester, requester_monitor} = requester!(f, config)

      {operation, held_lease} =
        receive do
          {:task17_queued_document_piece, ^native_gate, operation, lease} ->
            assert is_pid(operation) and is_pid(lease)
            {operation, lease}
        after
          5_000 -> flunk("real queued Document native piece gate missing")
        end

      owned = ownership!(f, operation)
      :ok = IssuedLeases.sync(f.lease_tracker)

      [piece | _] =
        Enum.filter(
          Observer.events(f),
          &(&1.point == :native_piece and &1.pid == operation and &1.lease == held_lease and
              &1.kind == :document and &1.byte_size > 0)
        )

      lease = piece.lease
      assert lease == held_lease
      assert piece.kind == :document and piece.byte_size > 0 and piece.byte_size <= 4_194_304
      assert Process.alive?(lease)

      assert Enum.any?(
               Observer.events(f),
               &(&1.point == :native_issued and &1.lease == lease)
             )

      refute Enum.any?(
               Observer.events(f),
               &(&1.point == :native_down and &1.lease == lease)
             )

      lease_monitor = Process.monitor(lease)

      controller =
        spawn(fn ->
          receive do
            {:task17_collector_sync_ready, reference, collector, binding} ->
              send(caller, {:task17_extra_sync_ready, reference, self(), collector, binding})

              receive do
                {:task17_extra_sync_closed, ^reference, ^caller} ->
                  send(collector, {:task17_collector_sync_continue, reference, self()})
              after
                5_000 -> exit(:sync_controller_timeout)
              end
          after
            5_000 -> exit(:sync_gate_missing)
          end
        end)

      controller_monitor = Process.monitor(controller)
      reference = Observer.register_sync_probe(f, controller)
      deadline = System.monotonic_time(:millisecond) + 5_000

      {worker, worker_monitor} =
        spawn_monitor(fn ->
          result = IssuedLeases.sync(f.lease_tracker)
          send(caller, {:task17_extra_sync_result, reference, self(), result})
        end)

      try do
        binding =
          receive do
            {:task17_extra_sync_ready, ^reference, ^controller, collector, binding} ->
              assert collector == f.lease_tracker
              binding
          after
            abort_extra_remaining(deadline) -> flunk("real ordinary collector sync gate missing")
          end

        send(operation, {:task17_queued_document_continue, native_gate, caller})

        result =
          receive do
            {:task17_export_result, ^requester, result} -> result
          after
            abort_extra_remaining(deadline) -> flunk("held actual export did not finish")
          end

        assert {:ok, held_handle} = result
        assert held_handle.owner == operation
        assert :ok = Api.close_knowledge_export(config, f.session, held_handle)

        assert [held_record] =
                 Enum.filter(Observer.companion_records(f), &(&1.lease == lease))

        assert held_record.source == :companion and held_record.outcome == :ok
        assert held_record.producer == owned.companion
        assert held_record.supervisor == f.supervisor
        assert :ok = Observer.assert_companion_record!(binding, held_record)
        issued = abort_extra_collector_issued(f)
        assert MapSet.member?(issued, lease)
        assert :ok = IssuedLeases.assert_companion_ack!(binding, held_record, issued)
        # This PID was actually monitored by the collector BEFORE its gate.
        # Its real death therefore queues DOWN before trace_delivered is requested.
        reason =
          receive do
            {:DOWN, ^lease_monitor, :process, ^lease, reason} -> reason
          after
            abort_extra_remaining(deadline) -> :missing
          end

        assert reason not in [:missing, :noproc]

        for {pid, monitor} <- [
              {owned.owner, owned.owner_monitor},
              {owned.companion, owned.companion_monitor}
            ] do
          reason =
            receive do
              {:DOWN, ^monitor, :process, ^pid, reason} -> reason
            after
              abort_extra_remaining(deadline) -> :missing
            end

          assert reason not in [:missing, :noproc]
        end

        send(requester, :task17_stop_requester)

        assert_receive {:DOWN, ^requester_monitor, :process, ^requester, :normal},
                       abort_extra_remaining(deadline)

        # No configured callback here: genuine default facade issuance/read/close
        # runs while the SAME ordinary collector drain is paused.
        assert {:ok, handle} = Api.export_knowledge(f.session, %{})

        try do
          assert {:ok, %{entries: entries}} =
                   Api.knowledge_export_entries(f.session, handle, nil)

          assert Enum.any?(entries, &(&1["path"] == "manifest.json"))

          assert {:ok, bytes} =
                   Api.read_knowledge_export_chunk(f.session, handle, "manifest.json", 0)

          assert byte_size(bytes) > 0 and byte_size(bytes) <= @chunk
        after
          assert :ok = Api.close_knowledge_export(f.session, handle)
        end

        assert abort_extra_remaining(deadline) > 0
        send(controller, {:task17_extra_sync_closed, reference, caller})

        assert_receive {:task17_extra_sync_result, ^reference, ^worker, :ok},
                       abort_extra_remaining(deadline)

        assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal},
                       abort_extra_remaining(deadline)

        assert_receive {:DOWN, ^controller_monitor, :process, ^controller, :normal},
                       abort_extra_remaining(deadline)

        receipt = Agent.get(f.observer.control, & &1.lifecycle.sync_receipt)
        assert :ok = Observer.assert_sync_receipt!(binding, receipt, true)
        assert receipt.consumed.native_issued > 0
        assert receipt.consumed.native_revoke_ack > 0
        assert receipt.consumed.native_down > 0
        progress = Observer.companion_progress(f)
        assert progress.binding == binding
        assert MapSet.member?(progress.applied, held_record.id)

        assert Enum.any?(
                 Observer.events(f),
                 &(&1.point == :native_down and &1.lease == lease and &1.pid == f.lease_tracker)
               )

        for kind <- [:native_issued, :native_revoke_ack, :native_down] do
          assert_raise ExUnit.AssertionError, fn ->
            Observer.assert_sync_receipt!(
              binding,
              %{receipt | consumed: Map.put(receipt.consumed, kind, 0)},
              true
            )
          end
        end

        assert_raise ExUnit.AssertionError, fn ->
          Observer.assert_sync_receipt!(binding, nil, true)
        end

        Live.assert_quiescent!(f)
      after
        send(operation, {:task17_queued_document_continue, native_gate, caller})
        send(controller, {:task17_extra_sync_closed, reference, caller})

        if Process.alive?(controller) do
          receive do
            {:DOWN, ^controller_monitor, :process, ^controller, _} -> :ok
          after
            5_000 -> abort_extra_stop!(controller)
          end
        end

        abort_extra_stop!(worker)
        abort_extra_stop!(controller)
        finish_requester!(requester, requester_monitor)
      end
    end)
  end

  test "configured actual ACK is pending before native issuance and duplicate replay is idempotent" do
    abort_extra_queued_fixture!(fn f ->
      caller = self()
      native_gate = make_ref()

      config =
        Live.export_config(f, %{
          on_event: fn point, values ->
            if point == :before_native_lease and
                 not Process.get({__MODULE__, native_gate, :acquisition_gate}, false) do
              Process.put({__MODULE__, native_gate, :acquisition_gate}, true)
              assert values.kind == :document
              send(caller, {:task17_real_acquisition_held, native_gate, self()})

              receive do
                {:task17_real_acquisition_continue, ^native_gate, ^caller} -> :ok
              after
                5_000 -> flunk("actual pending-first acquisition was not released")
              end
            end
          end
        })

      {requester, requester_monitor} = requester!(f, config)

      companion =
        receive do
          {:task17_real_acquisition_held, ^native_gate, companion} -> companion
        after
          5_000 -> flunk("actual pending-first companion gate missing")
        end

      assert [operation] = Task.Supervisor.children(f.supervisor) -- [companion]
      owned = ownership!(f, operation)
      assert owned.companion == companion
      assert Process.alive?(operation) and Process.alive?(companion)
      assert :ok = IssuedLeases.sync(f.lease_tracker)
      issued_before = abort_extra_collector_issued(f)
      assert MapSet.size(issued_before) == 0
      assert Observer.companion_records(f) == []

      controller =
        spawn(fn ->
          receive do
            {:task17_collector_sync_ready, reference, collector, binding} ->
              send(caller, {:task17_pending_sync_ready, reference, self(), collector, binding})

              receive do
                {:task17_pending_sync_closed, ^reference, ^caller} ->
                  send(collector, {:task17_collector_sync_continue, reference, self()})
              after
                5_000 -> exit(:pending_sync_controller_timeout)
              end
          after
            5_000 -> exit(:pending_sync_gate_missing)
          end
        end)

      controller_monitor = Process.monitor(controller)
      reference = Observer.register_sync_probe(f, controller)
      deadline = System.monotonic_time(:millisecond) + 5_000

      {worker, worker_monitor} =
        spawn_monitor(fn ->
          result = IssuedLeases.sync(f.lease_tracker)
          send(caller, {:task17_pending_sync_result, reference, self(), result})
        end)

      try do
        binding =
          receive do
            {:task17_pending_sync_ready, ^reference, ^controller, collector, binding} ->
              assert collector == f.lease_tracker
              binding
          after
            abort_extra_remaining(deadline) -> flunk("real pending-first sync gate missing")
          end

        send(companion, {:task17_real_acquisition_continue, native_gate, caller})

        result =
          receive do
            {:task17_export_result, ^requester, result} -> result
          after
            abort_extra_remaining(deadline) -> flunk("pending-first real export did not finish")
          end

        assert {:ok, handle} = result
        assert handle.owner == operation
        assert :ok = Api.close_knowledge_export(config, f.session, handle)
        # descriptor/3 authenticates once, then its reduce closure reads again
        # for the real Writer. Each pass acquires and revokes its own lease.
        records = Observer.companion_records(f)
        assert length(records) == 2
        record_ids = MapSet.new(records, & &1.id)
        record_leases = MapSet.new(records, & &1.lease)
        assert MapSet.size(record_ids) == 2
        assert MapSet.size(record_leases) == 2

        returned_leases =
          for event <- Observer.events(f),
              event.point == :native_lease and event.kind == :document and
                event.pid == companion,
              do: event.lease

        assert length(returned_leases) == 2
        assert MapSet.new(returned_leases) == record_leases

        pieces =
          Enum.filter(
            Observer.events(f),
            &(&1.point == :native_piece and &1.kind == :document and &1.pid == operation)
          )

        assert length(pieces) == 2
        assert MapSet.new(pieces, & &1.lease) == record_leases

        for piece <- pieces do
          assert piece.byte_size == f.inputs.plain.byte_size
          assert piece.byte_size > 0 and piece.byte_size <= 4_194_304
        end

        assert abort_extra_collector_issued(f) == issued_before

        for record <- records do
          assert record.source == :companion and record.outcome == :ok
          assert record.producer == companion and record.supervisor == f.supervisor
          assert :ok = Observer.assert_companion_record!(binding, record)

          assert_raise ExUnit.AssertionError, fn ->
            IssuedLeases.assert_companion_ack!(binding, record, issued_before)
          end

          for copy <- [
                %{record | binding: %{record.binding | token: make_ref()}},
                %{record | producer: self()},
                %{record | lease: self()},
                %{record | id: make_ref()}
              ] do
            assert_raise ExUnit.AssertionError, fn ->
              Observer.assert_companion_record!(binding, copy)
            end
          end
        end

        for {pid, monitor} <- [
              {owned.owner, owned.owner_monitor},
              {owned.companion, owned.companion_monitor}
            ] do
          reason =
            receive do
              {:DOWN, ^monitor, :process, ^pid, reason} -> reason
            after
              abort_extra_remaining(deadline) -> :missing
            end

          assert reason not in [:missing, :noproc]
        end

        send(requester, :task17_stop_requester)

        assert_receive {:DOWN, ^requester_monitor, :process, ^requester, :normal},
                       abort_extra_remaining(deadline)

        assert abort_extra_remaining(deadline) > 0
        send(controller, {:task17_pending_sync_closed, reference, caller})

        assert_receive {:task17_pending_sync_result, ^reference, ^worker, :ok},
                       abort_extra_remaining(deadline)

        assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal},
                       abort_extra_remaining(deadline)

        assert_receive {:DOWN, ^controller_monitor, :process, ^controller, :normal},
                       abort_extra_remaining(deadline)

        receipt = Agent.get(f.observer.control, & &1.lifecycle.sync_receipt)
        assert :ok = Observer.assert_sync_receipt!(binding, receipt, false)
        assert receipt.consumed.native_issued == 2
        assert receipt.consumed.native_revoke_ack == 2
        issued = abort_extra_collector_issued(f)
        assert issued == record_leases

        for record <- records do
          assert :ok = IssuedLeases.assert_companion_ack!(binding, record, issued)
        end

        progress = Observer.companion_progress(f)
        assert progress.binding == binding
        assert progress.pending_before_issuance == record_ids
        assert progress.applied == record_ids

        for record <- records do
          assert :ok = IssuedLeases.notify_companion_record(binding, record.id)
        end

        assert :ok = IssuedLeases.sync(f.lease_tracker)
        replay = Agent.get(f.observer.control, & &1.lifecycle.sync_receipt)
        assert :ok = Observer.assert_sync_receipt!(binding, replay, false)
        assert replay.consumed.native_issued == 0
        assert replay.consumed.native_revoke_ack == 0
        assert Observer.companion_progress(f) == progress
        assert abort_extra_remaining(deadline) > 0
        Live.assert_quiescent!(f)
      after
        send(companion, {:task17_real_acquisition_continue, native_gate, caller})
        send(controller, {:task17_pending_sync_closed, reference, caller})

        if Process.alive?(controller) do
          receive do
            {:DOWN, ^controller_monitor, :process, ^controller, _} -> :ok
          after
            5_000 -> abort_extra_stop!(controller)
          end
        end

        abort_extra_stop!(worker)
        abort_extra_stop!(controller)
        finish_requester!(requester, requester_monitor)
      end
    end)
  end

  defp abort_extra_collector_issued(f) do
    for event <- Observer.events(f),
        event.point == :native_issued and event.pid == f.lease_tracker,
        into: MapSet.new(),
        do: event.lease
  end

  defp abort_extra_queued_fixture!(callback) do
    Live.with_fixture(fn f ->
      input = f.inputs.plain

      f.permission_scope.(%{purpose: :import}, fn ->
        asset = NativeAssetFixture.upload!(f, input.media_type, chunks(input.bytes), "queued.txt")
        NativeAssetFixture.verify_and_finalize!()

        assert {:ok, document} =
                 Api.import_document(f.session, %{
                   asset_id: asset.asset_id,
                   title: "Queued native source",
                   mutation_id: Ecto.UUID.generate()
                 })

        assert document.source.digest == :crypto.hash(:sha256, input.bytes)
        assert document.source.byte_size == input.byte_size
        NativeAssetFixture.dispatch!()

        assert %{failure: 0, success: 1} =
                 Oban.drain_queue(Singularity.Oban, queue: :document_extract)

        assert {:ok, ready} = Api.get_document(f.session, document.resource_id)
        assert ready.resource_version_id == document.resource_version_id
        assert ready.state == :ready
        assert ready.source == document.source
        assert {:ok, fragments} = Api.document_fragments(f.session, document.resource_id)
        assert Enum.map(fragments, & &1.text) == input.fragments
        assert Enum.map(fragments, & &1.ordinal) == Enum.to_list(0..(length(input.fragments) - 1))

        for fragment <- fragments do
          assert fragment.resource_id == ready.resource_id
          assert fragment.resource_version_id == ready.resource_version_id
          assert fragment.digest == :crypto.hash(:sha256, fragment.text)
        end
      end)

      snapshots = Map.new([:storage, :backup], &{&1, retained_inventory(Map.fetch!(f.roots, &1))})
      callback.(Map.put(f, :root_snapshots, snapshots))
    end)
  end

  for point <- [
        :initial_registered,
        :native_registered,
        :private_start_returned,
        :tracker_start_returned
      ] do
    test "fixture caller abort retires exact partial acquisition at #{point}" do
      abort_extra_partial!(unquote(point))
    end
  end

  defp abort_extra_partial!(point) do
    controller = self()
    runtime_baseline = abort_extra_runtime_baseline!()
    environments = abort_extra_environments()

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        Observer.with_acquisition_probe(point, controller, fn _reference ->
          Live.with_fixture(fn _f -> flunk("partial acquisition reached its user callback") end)
        end)
      end)

    on_exit(fn -> abort_extra_stop!(caller) end)

    {reference, checkpoint, values} =
      receive do
        {:task17_acquisition_checkpoint, reference, ^point, checkpoint, values} ->
          {reference, checkpoint, values}

        {:DOWN, ^caller_monitor, :process, ^caller, _} ->
          flunk("partial acquisition exited before its actual checkpoint")
      after
        60_000 -> flunk("actual partial acquisition checkpoint missing")
      end

    owner = values.owner
    assert values.caller == caller and owner != caller
    assert checkpoint == if(point == :initial_registered, do: owner, else: caller)
    assert is_reference(values.token)
    neighbors = abort_extra_neighbor_snapshot!(values.roots)
    assert File.dir?(values.roots.qualified)
    assert {:ok, root_stat} = File.lstat(values.roots.qualified)
    assert root_stat.type == :directory and Bitwise.band(root_stat.mode, 0o7777) == 0o700
    assert Agent.get(values.control, & &1.lifecycle.child_specs) == values.child_specs

    children =
      if point == :initial_registered do
        assert values.child_specs == %{}
        %{}
      else
        assert Enum.sort(Map.keys(values.child_specs)) == [:private, :tracker]
        actual = Supervisor.which_children(values.infrastructure)

        Map.new(values.child_specs, fn {kind, journal} ->
          expected_id =
            if kind == :private,
              do: {Task.Supervisor, values.token},
              else: {IssuedLeases, values.token}

          assert journal.id == expected_id
          found = Enum.filter(actual, fn {id, _, _, _} -> id == expected_id end)

          expected_status =
            case {point, kind} do
              {:native_registered, _} -> :planned
              {:private_start_returned, :private} -> :starting
              {:private_start_returned, :tracker} -> :planned
              {:tracker_start_returned, :private} -> :started
              {:tracker_start_returned, :tracker} -> :starting
            end

          assert journal.status == expected_status

          pid =
            if expected_status == :planned do
              assert found == [] and journal.pid == nil
              nil
            else
              assert [{^expected_id, pid, _, _}] = found
              assert Process.alive?(pid)

              if expected_status == :starting do
                assert journal.pid == nil
                assert values.returned_child == %{kind: kind, id: expected_id, pid: pid}
              else
                assert journal.pid == pid
              end

              pid
            end

          {kind, pid}
        end)
      end

    resources = %{owner: owner, control: values.control}

    resources =
      if point == :initial_registered,
        do: resources,
        else:
          Map.merge(resources, %{
            infrastructure: values.infrastructure,
            custodian: values.custodian,
            global: values.global_supervisor
          })

    resources = Map.merge(resources, Map.reject(children, fn {_, pid} -> pid == nil end))

    monitors =
      Map.new(resources, fn {kind, pid} ->
        assert is_pid(pid) and Process.alive?(pid)
        {kind, {pid, Process.monitor(pid)}}
      end)

    on_exit(fn ->
      abort_extra_stop!(caller)

      if Process.alive?(owner) do
        monitor = Process.monitor(owner)
        send(checkpoint, {:task17_acquisition_continue, reference, controller})
        assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 5_000
      end
    end)

    # Setup has its own existing checkpoint gate. Every receipt and exact DOWN
    # below shares ONE 5000ms post-kill deadline, never a per-resource budget.
    deadline = System.monotonic_time(:millisecond) + 5_000
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed},
                   abort_extra_remaining(deadline)

    if point == :initial_registered do
      send(checkpoint, {:task17_acquisition_continue, reference, controller})
    else
      restored =
        receive do
          {:task17_fixture_restored, ^reference, ^owner, restored} -> restored
        after
          abort_extra_remaining(deadline) -> flunk("partial restoration receipt missing")
        end

      expected_binding = %{
        token: values.token,
        owner: owner,
        caller: caller,
        control: values.control,
        collector: Map.get(children, :tracker),
        custodian: values.custodian
      }

      assert restored.binding == expected_binding
      assert restored.retirement.binding == expected_binding
      assert restored.retirement.result == :ok
      assert restored.retirement.fence.binding == expected_binding
      assert is_boolean(restored.retirement.fence.result)
      assert restored.retirement.private == Map.get(children, :private)
      assert restored.retirement.global == values.global_supervisor
      assert restored.stopped.global == values.global_supervisor

      assert :ok =
               abort_extra_admissions_retired!(%{
                 infrastructure: values.infrastructure,
                 global: values.global_supervisor,
                 private: Map.get(children, :private),
                 collector: Map.get(children, :tracker)
               })

      for kind <- [:private, :tracker], pid = Map.get(children, kind), is_pid(pid) do
        assert Map.fetch!(restored.stopped, kind) == pid
        refute Process.alive?(pid)
      end

      if is_pid(Map.get(children, :tracker)) do
        assert :ok = Observer.assert_collector_receipt!(expected_binding, restored.collector)
        assert :ok = IssuedLeases.assert_restored!(restored.collector)
        assert restored.collector.enabled? == false
        assert restored.collector.issued == MapSet.new()

        assert_raise ExUnit.AssertionError, fn ->
          Observer.assert_collector_receipt!(expected_binding, nil)
        end
      else
        assert restored.collector == nil
        assert Agent.get(values.control, & &1.lifecycle.collector_receipt) == nil
      end

      send(owner, {:task17_fixture_restored_checked, reference, controller})
    end

    completion =
      receive do
        {:task17_fixture_completed, ^reference, ^owner, completion} -> completion
      after
        abort_extra_remaining(deadline) -> flunk("partial completion receipt missing")
      end

    assert Enum.sort(Map.keys(completion)) ==
             [
               :begin,
               :caller,
               :collector,
               :control,
               :control_down,
               :copy,
               :environments,
               :owner,
               :paths,
               :retirement,
               :stopped,
               :token
             ]

    assert completion.token == values.token and completion.owner == owner
    assert completion.caller == caller and completion.control == values.control
    assert completion.begin == :ok and completion.environments == :ok
    assert completion.control_down == :ok and completion.copy == :ok

    if is_pid(Map.get(children, :tracker)) do
      assert :ok = Observer.assert_completion_receipt!(completion.collector.binding, completion)

      assert_raise ExUnit.AssertionError, fn ->
        Observer.assert_completion_receipt!(
          completion.collector.binding,
          %{completion | collector: nil}
        )
      end
    else
      assert completion.collector == nil

      if point == :initial_registered do
        assert completion.retirement == nil and completion.stopped == %{}
      else
        assert completion.retirement.result == :ok
      end
    end

    for {kind, {pid, monitor}} <- monitors do
      reason =
        receive do
          {:DOWN, ^monitor, :process, ^pid, reason} -> reason
        after
          abort_extra_remaining(deadline) -> :missing
        end

      assert reason not in [:missing, :noproc, :killed]
      if kind == :owner, do: assert(reason == :normal)
      refute Process.alive?(pid)
    end

    assert completion.paths != []
    for path <- completion.paths, do: assert(File.lstat(path) == {:error, :enoent})
    assert File.lstat(values.roots.qualified) == {:error, :enoent}
    assert :ok = abort_extra_assert_neighbors!(neighbors)
    assert abort_extra_environments() == environments

    assert :ok =
             abort_extra_runtime_restored!(
               runtime_baseline,
               Map.get(values, :infrastructure),
               Map.get(values, :global_supervisor)
             )
  end

  defp abort_extra_neighbor_snapshot!(roots) do
    native_root = Path.dirname(roots.storage)
    parent = Path.dirname(roots.qualified)

    {stable, excluded} =
      if parent == native_root,
        do: {Path.dirname(native_root), Path.basename(native_root)},
        else: {parent, Path.basename(roots.qualified)}

    path =
      Path.join(
        stable,
        "task17-abort-owned-neighbor-#{System.unique_integer([:positive])}"
      )

    bytes = "task17 independent owned neighbor"
    File.write!(path, bytes, [:write, :exclusive, :binary])
    File.chmod!(path, 0o600)
    identity = abort_extra_file_identity!(path)

    snapshot = %{
      stable: stable,
      excluded: excluded,
      path: path,
      bytes: bytes,
      identity: identity,
      chain: abort_extra_parent_chain!(stable),
      siblings: abort_extra_siblings!(stable, excluded)
    }

    on_exit(fn ->
      assert abort_extra_file_identity!(path) == identity
      assert File.read!(path) == bytes
      assert :ok = File.rm(path)
    end)

    snapshot
  end

  defp abort_extra_assert_neighbors!(snapshot) do
    assert abort_extra_parent_chain!(snapshot.stable) == snapshot.chain
    assert abort_extra_file_identity!(snapshot.path) == snapshot.identity
    assert File.read!(snapshot.path) == snapshot.bytes
    current = abort_extra_siblings!(snapshot.stable, snapshot.excluded)
    assert current == snapshot.siblings
    :ok
  end

  defp abort_extra_file_identity!(path) do
    assert {:ok, stat} = File.lstat(path)
    Map.take(stat, [:major_device, :minor_device, :inode, :uid, :gid, :mode, :type])
  end

  defp abort_extra_parent_chain!("/"),
    do: [{"/", abort_extra_file_identity!("/")}]

  defp abort_extra_parent_chain!(path),
    do:
      abort_extra_parent_chain!(Path.dirname(path)) ++
        [{path, abort_extra_file_identity!(path)}]

  defp abort_extra_siblings!(parent, excluded),
    do:
      Map.new(File.ls!(parent) -- [excluded], fn name ->
        {name, abort_extra_file_identity!(Path.join(parent, name))}
      end)

  defp abort_extra_environments,
    do:
      Map.new(
        [:singularity_runtime, :singularity_storage],
        &{&1, Map.new(Application.get_all_env(&1))}
      )

  defp abort_extra_restoration_controls!(receipt, deadline) do
    if receipt.enabled? do
      custodian = receipt.binding.custodian
      assert Process.alive?(custodian)
      assert :ok = IssuedLeases.assert_restored!(receipt)
      # The real collector is already DOWN and admissions are retired. Install
      # only our exact known pattern, exercise the SAME live-state validator,
      # then restore only that still-identical owned state before owner resumes.
      target = {Singularity.Runtime.KeyLeaseSupervisor, :start_download_lease, 2}
      foreign = [{:_, [], [{:message, false}]}]
      baseline = abort_extra_trace_snapshot(custodian)
      assert baseline.patterns[target] == {{:match_spec, false}, {:traced, false}}
      :erlang.trace_pattern(target, foreign, [:local])
      installed = abort_extra_trace_snapshot(custodian)

      try do
        assert_raise ExUnit.AssertionError, fn ->
          IssuedLeases.assert_restored!(receipt)
        end

        assert abort_extra_trace_snapshot(custodian) == installed
      after
        assert abort_extra_trace_snapshot(custodian) == installed,
               "restoration control ownership changed; retained"

        :erlang.trace_pattern(target, false, [:local])
        assert abort_extra_trace_snapshot(custodian) == baseline
      end

      assert :ok = IssuedLeases.assert_restored!(receipt)

      tracer =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      tracer_monitor = Process.monitor(tracer)

      try do
        assert 1 = :erlang.trace(custodian, true, [:procs, {:tracer, tracer}])
        installed = abort_extra_trace_snapshot(custodian)

        assert_raise ExUnit.AssertionError, fn ->
          IssuedLeases.assert_restored!(receipt)
        end

        assert abort_extra_trace_snapshot(custodian) == installed
      after
        assert :erlang.trace_info(custodian, :flags) == {:flags, [:procs]}
        assert :erlang.trace_info(custodian, :tracer) == {:tracer, tracer}
        assert 1 = :erlang.trace(custodian, false, [:procs])
        send(tracer, :stop)

        assert_receive {:DOWN, ^tracer_monitor, :process, ^tracer, :normal},
                       abort_extra_remaining(deadline)

        assert abort_extra_trace_snapshot(custodian) == baseline
      end

      assert :ok = IssuedLeases.assert_restored!(receipt)
    end

    :ok
  end

  defp abort_extra_trace_snapshot(custodian) do
    targets = [
      {Singularity.Runtime.KeyLeaseSupervisor, :start_download_lease, 2},
      {Singularity.Runtime.DownloadLease, :revoke, 1}
    ]

    %{
      patterns:
        Map.new(targets, fn target ->
          {target, {:erlang.trace_info(target, :match_spec), :erlang.trace_info(target, :traced)}}
        end),
      flags: :erlang.trace_info(custodian, :flags),
      tracer: :erlang.trace_info(custodian, :tracer)
    }
  end

  defp abort_extra_case!(route) do
    controller = self()
    reference = make_ref()
    runtime_baseline = abort_extra_runtime_baseline!()

    environments =
      Map.new(
        [:singularity_runtime, :singularity_storage],
        &{&1, Map.new(Application.get_all_env(&1))}
      )

    caller =
      spawn(fn ->
        Live.with_fixture(fn f ->
          f =
            if route == :partial_grant,
              do: f,
              else: f |> Live.publish_sources!() |> Live.build_graph!()

          if route == :default_admission do
            try do
              abort_extra_default_warm!(f)
            catch
              kind, reason ->
                stacktrace = __STACKTRACE__

                classification =
                  case {kind, reason} do
                    {:error, %ExUnit.AssertionError{}} -> :assertion
                    {:error, _} -> :error
                    {:exit, _} -> :exit
                    {:throw, _} -> :throw
                  end

                line =
                  Enum.find_value(stacktrace, 0, fn
                    {__MODULE__, :abort_extra_default_warm!, _, location} ->
                      Keyword.get(location, :line, 0)

                    _ ->
                      nil
                  end)

                IO.puts(
                  "Task17 default warm failure: " <>
                    inspect(%{classification: classification, source_line: line})
                )

                :erlang.raise(kind, reason, stacktrace)
            end
          end

          probe = Observer.register_cleanup_probe(f, controller)

          binding = %{
            token: f.observer.token,
            owner: f.owner,
            caller: self(),
            control: f.observer.control,
            collector: f.lease_tracker,
            custodian: Process.whereis(Singularity.Runtime.KeyCustodian)
          }

          resources = %{
            owner: f.owner,
            infrastructure: f.infrastructure,
            private: f.supervisor,
            global: Process.whereis(Singularity.Runtime.UploadRecoveryTaskSupervisor),
            collector: f.lease_tracker,
            control: f.observer.control,
            custodian: binding.custodian,
            qualified: f.roots.qualified,
            roots: f.roots
          }

          send(controller, {reference, :prepared, self(), probe, binding, resources})

          receive do
            {^reference, :begin} -> :ok
          after
            5_000 -> flunk("actual abort operation was not released")
          end

          case route do
            :configured_native ->
              config =
                Live.export_config(f, %{
                  on_event: fn point, values ->
                    if point == :native_piece and values.kind == :document and
                         values.byte_size > 0 and
                         not Process.get({__MODULE__, reference, :native_gate}, false) do
                      Process.put({__MODULE__, reference, :native_gate}, true)

                      send(
                        controller,
                        {reference, :native_piece, self(), values.lease, values.kind,
                         values.byte_size}
                      )

                      receive do
                        {^reference, :unexpected_continue} ->
                          flunk("native abort barrier unexpectedly released")
                      after
                        5_000 -> flunk("native abort controller did not kill actual caller")
                      end
                    end
                  end
                })

              result = Api.export_knowledge(config, f.session, %{})
              close_unexpected!(f, config, result)
              flunk("configured native Api unexpectedly completed instead of caller abort")

            :default_admission ->
              result = Api.export_knowledge(f.session, %{})

              if match?({:ok, _}, result) do
                {:ok, handle} = result
                :ok = Api.close_knowledge_export(f.session, handle)
              end

              flunk("default admission Api unexpectedly returned before caller abort")

            :partial_grant ->
              f.permission_scope.(
                %{
                  purpose: :import,
                  after_grant: fn count ->
                    assert count == 1
                    send(controller, {reference, :partial_grant_registered, self(), count})

                    receive do
                      {^reference, :unexpected_continue} ->
                        flunk("partial-GRANT abort unexpectedly released")
                    after
                      5_000 -> flunk("partial-GRANT controller did not kill actual caller")
                    end
                  end
                },
                fn -> flunk("partial-GRANT setup entered its user callback") end
              )
          end
        end)
      end)

    caller_monitor = Process.monitor(caller)
    on_exit(fn -> abort_extra_stop!(caller) end)

    {probe, binding, resources} =
      receive do
        {^reference, :prepared, ^caller, probe, binding, resources} ->
          {probe, binding, resources}

        {:DOWN, ^caller_monitor, :process, ^caller, _} ->
          flunk("actual abort setup failed before preparation")
      after
        60_000 -> flunk("actual abort preparation missing")
      end

    neighbors = abort_extra_neighbor_snapshot!(resources.roots)

    monitors =
      Map.new(Map.drop(resources, [:qualified, :roots]), fn {kind, pid} ->
        assert is_pid(pid) and Process.alive?(pid)
        {kind, {pid, Process.monitor(pid)}}
      end)

    owner = resources.owner

    on_exit(fn ->
      abort_extra_stop!(caller)
      monitor = Process.monitor(owner)

      receive do
        {:DOWN, ^monitor, :process, ^owner, _} -> :ok
      after
        5_000 -> flunk("actual abort native owner did not finish")
      end
    end)

    setup_deadline = System.monotonic_time(:millisecond) + 5_000

    {deadline, caller_down_seen?} =
      case route do
        :configured_native ->
          send(caller, {reference, :begin})

          {operation, held_lease} =
            receive do
              {^reference, :native_piece, operation, lease, kind, bytes} ->
                ceiling = if kind == :document, do: 4_194_304, else: @chunk
                assert kind in [:asset, :document] and bytes > 0 and bytes <= ceiling
                assert kind == :document
                assert is_pid(lease)
                {operation, lease}
            after
              abort_extra_remaining(setup_deadline) -> flunk("real native piece gate missing")
            end

          assert operation in Task.Supervisor.children(resources.private)
          assert :ok = IssuedLeases.sync(resources.collector)
          issued = Agent.get(resources.control, & &1.issued)
          assert map_size(issued) > 0
          assert Enum.any?(Map.keys(issued), &Process.alive?/1)
          assert Map.has_key?(issued, held_lease)
          assert Process.alive?(held_lease)
          events = Agent.get(resources.control, & &1.events)
          assert Enum.any?(events, &(&1.point == :native_issued))
          assert Enum.any?(events, &(&1.point == :native_issued and &1.lease == held_lease))
          assert abort_extra_remaining(setup_deadline) > 0
          post_kill_deadline = System.monotonic_time(:millisecond) + 5_000
          Process.exit(caller, :kill)
          {post_kill_deadline, false}

        :default_admission ->
          global = resources.global

          try do
            assert Process.whereis(Singularity.Runtime.UploadRecoveryTaskSupervisor) == global
            assert :ok = :sys.suspend(global, abort_extra_remaining(setup_deadline))
            send(caller, {reference, :begin})
            assert abort_extra_blocked_default?(caller, setup_deadline)
          catch
            kind, reason ->
              stacktrace = __STACKTRACE__
              abort_extra_resume!(resources, setup_deadline)
              :erlang.raise(kind, reason, stacktrace)
          end

          post_kill_deadline = System.monotonic_time(:millisecond) + 5_000

          try do
            Process.exit(caller, :kill)

            assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed},
                           abort_extra_remaining(post_kill_deadline)

            {post_kill_deadline, true}
          after
            # Exact PID only, never its replacement. The post-kill cleanup
            # deadline also bounds normal resume; failure containment stays FAIL.
            abort_extra_resume!(resources, post_kill_deadline)
          end

        :partial_grant ->
          send(caller, {reference, :begin})

          assert_receive {^reference, :partial_grant_registered, ^caller, 1},
                         abort_extra_remaining(setup_deadline)

          post_kill_deadline = System.monotonic_time(:millisecond) + 5_000
          Process.exit(caller, :kill)
          {post_kill_deadline, false}
      end

    unless caller_down_seen? do
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed},
                     abort_extra_remaining(deadline)
    end

    restored =
      receive do
        {:task17_fixture_restored, ^probe, ^owner, restored} -> restored
      after
        abort_extra_remaining(deadline) ->
          flunk("actual pre-shutdown restoration receipt missing")
      end

    assert restored.binding == binding
    assert :ok = Observer.assert_collector_receipt!(binding, restored.collector)
    assert :ok = IssuedLeases.assert_restored!(restored.collector)
    assert :ok = abort_extra_admissions_retired!(resources)
    abort_extra_restoration_controls!(restored.collector, deadline)
    refute Process.alive?(resources.private)
    refute Process.alive?(resources.global)
    refute Process.alive?(resources.collector)

    assert_raise ExUnit.AssertionError, fn ->
      Observer.assert_collector_receipt!(binding, nil)
    end

    assert_raise ExUnit.AssertionError, fn ->
      Observer.assert_collector_receipt!(
        binding,
        %{restored.collector | restoration: {:error, :missing}}
      )
    end

    assert_raise ExUnit.AssertionError, fn ->
      Observer.assert_collector_receipt!(%{binding | token: make_ref()}, restored.collector)
    end

    send(owner, {:task17_fixture_restored_checked, probe, self()})

    completion =
      receive do
        {:task17_fixture_completed, ^probe, ^owner, completion} -> completion
      after
        abort_extra_remaining(deadline) -> flunk("actual post-native completion receipt missing")
      end

    assert :ok = Observer.assert_completion_receipt!(binding, completion)

    assert_raise ExUnit.AssertionError, fn ->
      Observer.assert_completion_receipt!(binding, nil)
    end

    assert_raise ExUnit.AssertionError, fn ->
      Observer.assert_completion_receipt!(binding, %{
        completion
        | control_down: {:error, :missing}
      })
    end

    reasons =
      Map.new(monitors, fn {kind, {pid, monitor}} ->
        reason =
          receive do
            {:DOWN, ^monitor, :process, ^pid, reason} -> reason
          after
            abort_extra_remaining(deadline) -> :missing
          end

        {kind, reason}
      end)

    post_environments =
      Map.new(
        [:singularity_runtime, :singularity_storage],
        &{&1, Map.new(Application.get_all_env(&1))}
      )

    facts = %{
      owner_normal: reasons.owner == :normal,
      actual_helpers_down:
        Enum.all?(reasons, fn {_, reason} ->
          reason not in [:missing, :noproc]
        end),
      exact_environments: post_environments == environments,
      neighbors_unchanged: abort_extra_assert_neighbors!(neighbors) == :ok,
      qualified_absent: File.lstat(resources.qualified) == {:error, :enoent},
      runtime_restored:
        abort_extra_runtime_restored!(
          runtime_baseline,
          resources.infrastructure,
          resources.global
        ) == :ok
    }

    IO.puts("Task17 actual abort additional control: " <> inspect(%{route: route, facts: facts}))
    assert Enum.all?(facts, fn {_, value} -> value == true end)
  end

  defp abort_extra_runtime_baseline! do
    started? =
      Enum.any?(
        Application.started_applications(),
        fn {app, _, _} -> app == :singularity_runtime end
      )

    runtime = Process.whereis(Singularity.Runtime.Supervisor)
    global = Process.whereis(Singularity.Runtime.UploadRecoveryTaskSupervisor)
    assert started? == is_pid(runtime)
    children = if started?, do: Supervisor.which_children(runtime), else: []

    composition =
      Enum.sort(
        Enum.map(children, fn {id, _, type, modules} ->
          {id, type, modules}
        end)
      )

    if is_pid(global) do
      assert started? and Process.alive?(global)

      assert Enum.count(children, fn
               {Singularity.Runtime.UploadRecoveryTaskSupervisor, ^global, :supervisor, _} -> true
               _ -> false
             end) == 1
    else
      refute Enum.any?(children, fn
               {Singularity.Runtime.UploadRecoveryTaskSupervisor, pid, _, _} when is_pid(pid) ->
                 true

               _ ->
                 false
             end)
    end

    %{started?: started?, runtime: runtime, global: global, composition: composition}
  end

  defp abort_extra_admissions_retired!(resources) do
    assert Process.alive?(resources.infrastructure)
    assert Process.whereis(Singularity.Runtime.UploadRecoveryTaskSupervisor) == nil

    refute Enum.any?(Supervisor.which_children(resources.infrastructure), fn
             {Singularity.Runtime.UploadRecoveryTaskSupervisor, pid, _, _} when is_pid(pid) ->
               true

             _ ->
               false
           end)

    for pid <- [resources.global, resources.private, resources.collector], is_pid(pid) do
      refute Process.alive?(pid)
    end

    :ok
  end

  defp abort_extra_runtime_restored!(baseline, owned_infrastructure, owned_global) do
    actual = abort_extra_runtime_baseline!()
    assert actual.started? == baseline.started?
    assert actual.composition == baseline.composition

    if baseline.started? do
      assert is_pid(actual.runtime) and Process.alive?(actual.runtime)
      assert actual.runtime != baseline.runtime and actual.runtime != owned_infrastructure
    else
      assert actual.runtime == nil
    end

    if is_pid(baseline.global) do
      assert is_pid(actual.global) and Process.alive?(actual.global)
      assert actual.global != baseline.global and actual.global != owned_global
      assert actual.global != owned_infrastructure
      # baseline! independently binds this exact registered global to the
      # exact restored Runtime.Supervisor using public which_children.
    else
      assert actual.global == nil
    end

    :ok
  end

  defp abort_extra_default_warm!(f) do
    global = Process.whereis(Singularity.Runtime.UploadRecoveryTaskSupervisor)
    assert global == f.global_supervisor
    assert is_pid(global) and Process.alive?(global)

    assert [
             {Singularity.Runtime.UploadRecoveryTaskSupervisor, ^global, :supervisor, _modules}
           ] =
             Enum.filter(
               Supervisor.which_children(f.infrastructure),
               fn {id, _pid, _type, _modules} ->
                 id == Singularity.Runtime.UploadRecoveryTaskSupervisor
               end
             )

    assert Task.Supervisor.children(global) == []
    :ok = IssuedLeases.enable(f.lease_tracker)
    :ok = IssuedLeases.sync(f.lease_tracker)
    issued_before = MapSet.new(Map.keys(Observer.issued(f)))
    assert {:ok, handle} = Api.export_knowledge(f.session, %{})
    assert Process.whereis(Singularity.Runtime.UploadRecoveryTaskSupervisor) == global
    children = Task.Supervisor.children(global)
    assert handle.owner in children
    assert [companion] = children -- [handle.owner]
    assert Process.alive?(handle.owner) and Process.alive?(companion)
    owner = handle.owner
    owner_monitor = Process.monitor(owner)
    companion_monitor = Process.monitor(companion)
    # Only forwarding closures to the actual default facade, not Export/runtime
    # replacements. Live materializer retains its exact public-chunk contract.
    facade = %{
      knowledge_export_entries: fn _context, h, cursor ->
        Api.knowledge_export_entries(f.session, h, cursor)
      end,
      read_knowledge_export_chunk: fn _context, h, path, ordinal ->
        Api.read_knowledge_export_chunk(f.session, h, path, ordinal)
      end,
      close_knowledge_export: fn _context, h ->
        Api.close_knowledge_export(f.session, h)
      end
    }

    materialized = Live.materialize!(f, facade, handle)
    terminal_deadline = System.monotonic_time(:millisecond) + 5_000

    owner_reason =
      receive do
        {:DOWN, ^owner_monitor, :process, ^owner, reason} -> reason
      after
        abort_extra_remaining(terminal_deadline) -> :missing
      end

    companion_reason =
      receive do
        {:DOWN, ^companion_monitor, :process, ^companion, reason} -> reason
      after
        abort_extra_remaining(terminal_deadline) -> :missing
      end

    owner_loss =
      owner_reason not in [:missing, :noproc] and
        companion_reason not in [:missing, :noproc]

    assert owner_loss
    :ok = IssuedLeases.sync(f.lease_tracker)

    leases =
      Observer.issued(f)
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.difference(issued_before)
      |> MapSet.to_list()

    assert leases != []
    events = abort_extra_await_native_down!(f, leases, terminal_deadline)

    for lease <- leases do
      assert Enum.any?(
               events,
               &(&1.point == :native_issued and &1.lease == lease and &1.pid == f.lease_tracker)
             )

      assert Enum.any?(
               events,
               &(&1.point == :native_down and &1.lease == lease and &1.pid == f.lease_tracker)
             )

      monitor = Process.monitor(lease)

      assert {:error, %Singularity.Core.Error{code: :storage_unavailable}} =
               Singularity.Runtime.DownloadLease.read_document_chunk(lease, 0)

      assert_receive {:DOWN, ^monitor, :process, ^lease, _},
                     abort_extra_remaining(terminal_deadline)
    end

    assert Process.whereis(Singularity.Runtime.UploadRecoveryTaskSupervisor) == global
    assert Task.Supervisor.children(global) == []
    Offline.verify!(materialized.root, expectation(f, materialized.entries, false))
    Live.assert_quiescent!(f)
    :ok
  end

  defp abort_extra_await_native_down!(f, leases, deadline) do
    events = Observer.events(f)

    if Enum.all?(leases, fn lease ->
         Enum.any?(
           events,
           &(&1.point == :native_down and &1.lease == lease and &1.pid == f.lease_tracker)
         )
       end) do
      events
    else
      token = f.observer.token

      receive do
        {:knowledge_export, ^token, :native_down, collector, _}
        when collector == f.lease_tracker ->
          abort_extra_await_native_down!(f, leases, deadline)
      after
        abort_extra_remaining(deadline) -> flunk("default operation native DOWN evidence missing")
      end
    end
  end

  defp abort_extra_blocked_default?(caller, deadline) do
    assert abort_extra_remaining(deadline) > 0, "actual default Api stack gate timed out"

    case Process.info(caller, :current_stacktrace) do
      {:current_stacktrace, frames} ->
        mfas =
          Enum.map(frames, fn {module, function, arity, _location} ->
            {module, function, arity}
          end)

        api? =
          Enum.any?(mfas, fn {module, function, _} ->
            module == Api and function == :knowledge_export_call
          end)

        generation? =
          Enum.any?(mfas, fn {module, function, _} ->
            module == Singularity.Runtime.Knowledge.ExportArtifact and
              String.contains?(Atom.to_string(function), "generate")
          end)

        task_call? =
          Enum.any?(mfas, fn {module, function, _} ->
            module in [Task.Supervisor, GenServer, :gen] and
              function in [:start_child, :call, :do_call]
          end)

        if api? and generation? and task_call? do
          true
        else
          :erlang.yield()
          abort_extra_blocked_default?(caller, deadline)
        end

      nil ->
        flunk("actual default Api caller exited before admission stack witness")
    end
  end

  defp abort_extra_remaining(deadline),
    do: max(0, deadline - System.monotonic_time(:millisecond))

  defp abort_extra_resume!(resources, deadline) do
    global = resources.global

    owned = fn ->
      Process.alive?(global) and Process.alive?(resources.infrastructure) and
        Process.whereis(Singularity.Runtime.UploadRecoveryTaskSupervisor) == global
    end

    if Process.alive?(global) do
      assert owned.(), "default admission supervisor ownership became ambiguous; retained"
      remaining = abort_extra_remaining(deadline)

      normal =
        if remaining > 0 do
          try do
            :sys.resume(global, remaining)
          catch
            kind, _ -> {:error, kind}
          end
        else
          {:error, :deadline}
        end

      if normal != :ok do
        # Failure is recorded BEFORE containment. This second bounded call
        # never extends acceptance or produces an admission/cleanup PASS.
        IO.puts("Task17 default admission control failed before owned resume containment")

        result =
          if owned.() do
            try do
              case :sys.resume(global, 5_000) do
                :ok -> :ok
                _ -> :error
              end
            catch
              _, _ -> :error
            end
          else
            :ownership_ambiguous
          end

        IO.puts(
          "Task17 default admission failure containment: " <>
            inspect(%{
              actual_result: result,
              acceptance_credit: false
            })
        )

        flunk("default admission resume did not complete within original control deadline")
      end
    else
      # A real native-owner shutdown may already have stopped it. No resume
      # is attempted and no credit is awarded; later fresh exact DOWN is required.
      assert Process.whereis(Singularity.Runtime.UploadRecoveryTaskSupervisor) == nil
    end

    :ok
  end

  defp abort_extra_stop!(pid) do
    if Process.alive?(pid) do
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
    end

    :ok
  end

  # TASK17_ABORT_LIFECYCLE_REGRESSIONS_END

  defp rich_fixture(callback),
    do:
      Live.with_fixture(fn f ->
        f |> Live.publish_sources!() |> Live.build_graph!() |> callback.()
      end)

  defp expectation(f, entries, tombstones) do
    relationship = f.graph.relationship

    e =
      Map.merge(f.graph.expected, %{
        inputs: f.inputs,
        entries: entries,
        include_tombstones: tombstones,
        tag_records: [
          %{
            "id" => f.graph.tag.tag_id,
            "display_value" => "../资料/[source](escape) 🧪",
            "normalized_key" => "../资料/[source](escape) 🧪"
          }
        ],
        relationship_records: [
          %{
            "id" => relationship.relationship_id,
            "source_resource_id" => relationship.source_resource_id,
            "target_resource_id" => relationship.target_resource_id,
            "target_version_id" => relationship.target_resource_version_id,
            "type" => "related_to"
          }
        ],
        rendered_snippets: %{
          f.graph.note.resource_version_id => [
            "[ordinary URL](https://example.test/knowledge)",
            "; label: \\.\\.\\/资料\\/\\[source\\]\\(escape\\) 🧪"
          ],
          f.graph.retained.resource_version_id => [
            "; Deleted source; attachment: ",
            "; deleted historical source"
          ]
        }
      })

    if tombstones do
      e
      |> Map.update!(:resource_ids, &MapSet.put(&1, f.graph.tombstone.resource_id))
      |> Map.update!(:metadata_versions, &MapSet.put(&1, f.graph.tombstone.resource_version_id))
    else
      e
    end
  end

  defp requester!(f, config, trace \\ nil) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          :task17_begin_requester -> :ok
        end

        if trace, do: CleanupTrace.task(trace, self())
        result = Api.export_knowledge(config, f.session, %{})
        send(parent, {:task17_export_result, self(), result})

        receive do
          :task17_stop_requester -> :ok
        after
          60_000 -> exit(:requester_not_released)
        end
      end)

    on_exit(fn ->
      if Process.alive?(pid) do
        cleanup_monitor = Process.monitor(pid)
        send(pid, :task17_stop_requester)

        receive do
          {:DOWN, ^cleanup_monitor, :process, ^pid, _} -> :ok
        after
          5_000 ->
            # Emergency teardown of this test-owned requester is never credited
            # as an autonomous export lifecycle witness.
            Process.exit(pid, :kill)
            assert_receive {:DOWN, ^cleanup_monitor, :process, ^pid, _}, 5_000
        end
      end
    end)

    send(pid, :task17_begin_requester)
    {pid, monitor}
  end

  defp await_result!(requester) do
    assert_receive {:task17_export_result, ^requester, result}, 60_000
    result
  end

  defp stop_requester!(requester, monitor) do
    send(requester, :task17_stop_requester)
    assert_receive {:DOWN, ^monitor, :process, ^requester, :normal}, 5_000
  end

  defp finish_requester!(requester, monitor) do
    if Process.alive?(requester), do: stop_requester!(requester, monitor)
  end

  defp close_unexpected!(f, config, {:ok, handle}),
    do: assert(:ok = Api.close_knowledge_export(config, f.session, handle))

  defp close_unexpected!(_f, _config, _result), do: :ok

  defp barrier!(f, point) do
    token = f.observer.token
    assert_receive {:knowledge_export_barrier, ^token, ^point, pid}, 30_000
    refute_receive {:task17_export_result, _, {:ok, _}}, 0
    pid
  end

  defp continue!(f, point, pid),
    do: send(pid, {:knowledge_export_continue, f.observer.token, point})

  defp trace_callback(trace),
    do: fn point, _ -> if point == :task_first_clock, do: CleanupTrace.task(trace, self()) end

  defp ownership!(f, owner, writer? \\ true) do
    assert [companion] = Task.Supervisor.children(f.supervisor) -- [owner]

    ledgers =
      for table <- :ets.all(),
          :ets.info(table, :owner) == owner,
          :ets.info(table, :name) == Writer,
          do: table

    if writer?, do: assert(ledgers != [])

    assert [name] =
             Enum.filter(
               File.ls!(f.roots.artifact),
               &String.starts_with?(&1, "knowledge-export-")
             )

    path = Path.join(f.roots.artifact, name)
    assert File.regular?(Path.join(path, ".ownership"))

    %{
      owner: owner,
      companion: companion,
      ledgers: ledgers,
      path: path,
      monitor_owner: self(),
      owner_monitor: Process.monitor(owner),
      companion_monitor: Process.monitor(companion)
    }
  end

  defp assert_terminal!(f, owned, trace) do
    owned =
      if owned.monitor_owner == self() do
        owned
      else
        %{
          owned
          | monitor_owner: self(),
            owner_monitor: Process.monitor(owned.owner),
            companion_monitor: Process.monitor(owned.companion)
        }
      end

    # Fresh late monitors confirm termination only. The separate real companion
    # receive trace below still proves owner DOWN preceded owned cleanup.
    try do
      assert_receive {:DOWN, ref, :process, owner, _}
                     when ref == owned.owner_monitor and owner == owned.owner,
                     10_000

      assert_receive {:DOWN, ref, :process, companion, _}
                     when ref == owned.companion_monitor and companion == owned.companion,
                     10_000

      for table <- owned.ledgers, do: assert(:ets.info(table) == :undefined)
      assert {:error, :enoent} = File.lstat(owned.path)
      :ok = IssuedLeases.sync(f.lease_tracker)
      Observer.assert_issued_terminal!(f)
      :ok = IssuedLeases.sync(f.lease_tracker)
      events = CleanupTrace.events(trace)
      down_index = Enum.find_index(events, &(&1 == {:owner_down, owned.companion, owned.owner}))

      cleanup_index =
        Enum.find_index(events, &(&1 == {:cleanup, owned.companion, owned.path, false}))

      assert is_integer(down_index) and is_integer(cleanup_index) and down_index < cleanup_index,
             "exact owner DOWN must precede companion owned-directory cleanup"

      for {lease, _} <- Observer.issued(f) do
        observed = Observer.events(f)
        assert Enum.any?(observed, &(&1.point == :native_down and &1.lease == lease))

        ack =
          Enum.any?(
            observed,
            &(&1.point == :native_revoke_ack and &1.lease == lease and &1.outcome == :ok)
          )

        assert ack or (not Process.alive?(owned.owner) and not Process.alive?(owned.companion))
      end

      Live.assert_quiescent!(f)
    after
      Process.demonitor(owned.owner_monitor, [:flush])
      Process.demonitor(owned.companion_monitor, [:flush])
    end
  end

  defp revoke_authority!(f) do
    %{num_rows: 1} =
      NativeAssetFixture.observe!(
        "UPDATE identity.principals SET authorization_epoch=authorization_epoch+1 WHERE id=$1",
        [Ecto.UUID.dump!(f.session.principal_id)]
      )
  end

  defp large_fixture(callback) do
    Live.with_fixture(fn f ->
      bytes = :binary.copy("界", div(4_194_304, 3)) <> "tail🌍"
      asset = NativeAssetFixture.upload!(f, "text/plain", chunks(bytes), "large.txt")
      NativeAssetFixture.verify_and_finalize!()

      f.permission_scope.(%{purpose: :import}, fn ->
        assert {:ok, document} =
                 Api.import_document(f.session, %{
                   asset_id: asset.asset_id,
                   title: "Large source",
                   mutation_id: Ecto.UUID.generate()
                 })

        assert {:ok, pending} = Api.get_document(f.session, document.resource_id)
        assert pending.resource_version_id == document.resource_version_id
        assert pending.state == :pending
        assert pending.source.digest == :crypto.hash(:sha256, bytes)
        assert pending.source.byte_size == byte_size(bytes)
      end)

      f.permission_scope.(%{purpose: :graph}, fn ->
        # Pending is valid and retains a genuine original. Extraction of a
        # >64KiB single fragment is deliberately not manufactured as ready.
        # Pending live heads export directly; only ready Documents may be pinned
        # by a newly created Note attachment.
        assert {:ok, _} =
                 Api.create_note(f.session, %{
                   mutation_id: Ecto.UUID.generate(),
                   title: "Large source companion",
                   markdown: "Large source"
                 })
      end)

      snapshots = Map.new([:storage, :backup], &{&1, retained_inventory(Map.fetch!(f.roots, &1))})
      callback.(f |> Map.put(:large_original, bytes) |> Map.put(:root_snapshots, snapshots))
    end)
  end

  defp retained_inventory(root, relative \\ "", acc \\ %{}) do
    Enum.reduce(File.ls!(Path.join(root, relative)), acc, fn name, result ->
      path = Path.join(relative, name)

      case File.lstat!(Path.join(root, path)) do
        %{type: :directory} ->
          retained_inventory(root, path, Map.put(result, path, :directory))

        %{type: :regular, size: size} ->
          Map.put(result, path, {size, Offline.sha(File.read!(Path.join(root, path)))})

        _ ->
          flunk("owned storage inventory contains an unsupported entry")
      end
    end)
  end

  defp chunks(<<>>), do: []
  defp chunks(bytes) when byte_size(bytes) <= @chunk, do: [bytes]
  defp chunks(<<head::binary-size(@chunk), tail::binary>>), do: [head | chunks(tail)]

  defp uuid(n),
    do:
      "00000000-0000-4000-8000-" <>
        (n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0"))

  defp note_path(n), do: "notes/#{uuid(n)}--#{uuid(n + 1000)}.md"
  defp extracted_path(n), do: "documents/extracted/#{uuid(n)}--#{uuid(n + 1000)}.txt"

  defp version(n, kind, availability) do
    ~w(resource_id version_id revision kind inserted_at availability body_path original_path extracted_path body_digest original_digest original_byte_size extracted_digest media_type state extraction_adapter extraction_format parent_version_id merge_parent_version_id)
    |> Map.new(&{&1, nil})
    |> Map.merge(%{
      "resource_id" => uuid(n),
      "version_id" => uuid(n + 1000),
      "revision" => 0,
      "kind" => kind,
      "inserted_at" => "2026-10-19T01:02:03.123456Z",
      "availability" => availability
    })
  end

  defp resource(v),
    do: %{
      "id" => v["resource_id"],
      "kind" => v["kind"],
      "title" => "Bounded title",
      "current_version_id" => v["version_id"],
      "deleted_at" => nil,
      "selection_reason" =>
        if(v["kind"] == "asset",
          do: "source",
          else: if(v["availability"] == "included", do: "head", else: "relationship_endpoint")
        )
    }

  defp offline_positive!(root) do
    File.mkdir_p!(Path.join(root, "notes"))
    File.mkdir_p!(Path.join(root, "documents/extracted"))
    File.mkdir_p!(Path.join(root, "documents/originals"))
    canonical = "# Offline 笔记\n\n[ordinary URL](https://example.test/knowledge)"
    texts = ["界😀", "tail"]
    extracted = Enum.join(texts)
    original = "Original 界😀"
    locator = %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 2}
    ids = [String.duplicate("a", 64), String.duplicate("b", 64)]

    citation = %{
      "note_resource_id" => uuid(1),
      "note_version_id" => uuid(1001),
      "id" => uuid(99),
      "ordinal" => 0,
      "source_resource_id" => uuid(2),
      "source_version_id" => uuid(1002),
      "fragment_id" => hd(ids),
      "locator" => locator
    }

    link = "../" <> extracted_path(2)

    rendered =
      canonical <>
        "\n\n## Sources\n\nPortable source inventory; links identify included exact-version files.\n\n" <>
        "- [Source](#{link}) — document; resource: #{uuid(2)}; version: #{uuid(1002)} [^singularity-source-#{uuid(99)}]; citation: #{uuid(99)}\n\n" <>
        "[^singularity-source-#{uuid(99)}]: Source; citation: #{uuid(99)}; resource: #{uuid(2)}; version: #{uuid(1002)}; fragment: #{hd(ids)}; text lines: 1–2\n"

    note =
      version(1, "note", "included")
      |> Map.merge(%{"body_path" => note_path(1), "body_digest" => Offline.sha(canonical)})

    document =
      version(2, "document", "included")
      |> Map.merge(%{
        "original_path" => "documents/originals/#{uuid(2)}--#{uuid(1002)}.txt",
        "original_digest" => Offline.sha(original),
        "original_byte_size" => byte_size(original),
        "media_type" => "text/plain",
        "state" => "ready",
        "extraction_adapter" => "plain_text",
        "extraction_format" => 1,
        "extracted_path" => extracted_path(2),
        "extracted_digest" => Offline.sha(extracted)
      })

    fragments =
      Enum.zip(texts, ids)
      |> Enum.with_index()
      |> Enum.map(fn {{text, id}, ordinal} ->
        %{
          "id" => id,
          "resource_id" => uuid(2),
          "version_id" => uuid(1002),
          "ordinal" => ordinal,
          "digest" => Offline.sha(text),
          "locator" => locator,
          "extracted_path" => extracted_path(2),
          "start_byte" => if(ordinal == 0, do: 0, else: byte_size(hd(texts))),
          "byte_size" => byte_size(text)
        }
      end)

    bodies = %{
      note_path(1) => rendered,
      document["original_path"] => original,
      extracted_path(2) => extracted
    }

    for {path, bytes} <- bodies, do: File.write!(Path.join(root, path), bytes)

    files =
      bodies
      |> Enum.map(fn {path, bytes} ->
        %{
          "path" => path,
          "media_type" => if(path == note_path(1), do: "text/markdown", else: "text/plain"),
          "byte_size" => byte_size(bytes),
          "sha256" => Offline.sha(bytes)
        }
      end)
      |> Enum.sort_by(& &1["path"])

    manifest = %{
      "format" => "singularity.portable-knowledge",
      "version" => 1,
      "selection" => %{"mode" => "live_heads_with_source_closure", "include_tombstones" => false},
      "resources" => [resource(note), resource(document)],
      "versions" => [note, document],
      "fragments" => fragments,
      "tags" => [],
      "tag_assignments" => [],
      "relationships" => [],
      "attachments" => [],
      "citations" => [citation],
      "files" => files
    }

    expected = %{
      include_tombstones: false,
      notes: %{uuid(1001) => canonical},
      fragments: %{uuid(1002) => texts},
      included_versions: MapSet.new([uuid(1001), uuid(1002)]),
      metadata_versions: MapSet.new(),
      resource_ids: MapSet.new([uuid(1), uuid(2)]),
      tags: [],
      relationships: [],
      historical_pins: [],
      deleted_sources: [],
      absent_bodies: ["ABSENT_HISTORY"],
      memberships: %{
        uuid(1001) => %{
          attachments: [],
          citations: [
            %{
              citation_id: uuid(99),
              source_resource_id: uuid(2),
              source_resource_version_id: uuid(1002),
              fragment_id: hd(ids),
              locator: locator
            }
          ]
        }
      },
      original_inputs: %{uuid(1002) => :plain},
      asset_inputs: %{},
      inputs: %{
        plain: %{
          bytes: original,
          sha256: Offline.sha(original),
          byte_size: byte_size(original),
          media_type: "text/plain"
        }
      }
    }

    {rewrite_manifest!(root, expected, manifest), manifest}
  end

  defp rewrite_manifest!(root, expected, manifest) do
    ordered = %Jason.OrderedObject{
      values:
        Enum.map(@offline_top, fn key ->
          value = manifest[key]

          value =
            if fields = @offline_fields[key],
              do:
                Enum.map(value, fn row ->
                  %Jason.OrderedObject{values: Enum.map(fields, &{&1, row[&1]})}
                end),
              else: value

          {key, value}
        end)
    }

    bytes = Jason.encode!(ordered)
    File.write!(Path.join(root, "manifest.json"), bytes)

    entries =
      Map.new(manifest["files"], &{&1["path"], &1})
      |> Map.put("manifest.json", %{
        "path" => "manifest.json",
        "media_type" => "application/json",
        "byte_size" => byte_size(bytes),
        "sha256" => Offline.sha(bytes)
      })

    Map.put(expected, :entries, entries)
  end

  defp refresh_file!(root, expected, manifest, path) do
    bytes = File.read!(Path.join(root, path))

    files =
      Enum.map(manifest["files"], fn row ->
        if row["path"] == path,
          do: Map.merge(row, %{"byte_size" => byte_size(bytes), "sha256" => Offline.sha(bytes)}),
          else: row
      end)

    rewrite_manifest!(root, expected, Map.put(manifest, "files", files))
  end

  defp model_capture_digests!(f) do
    Map.new(
      [{:text, :text_refs}, {:render, :render_refs}, {:binary, :binary_refs}],
      fn {family, field} ->
        refs = Map.fetch!(f.capture, field)
        expected = Map.fetch!(f.known_refs, field)
        assert MapSet.new(Map.keys(refs)) == MapSet.new(Map.keys(expected))

        for {selector, reference} <- refs do
          bytes = Map.fetch!(expected, selector)
          assert reference.byte_size == byte_size(bytes)
          RetainedModel.known_digest!(reference.sha256, bytes)
          assert {:ok, ^bytes} = Spool.read_chunk(f.capture, reference, 0)
        end

        {family, map_size(refs)}
      end
    )
  end

  defp model_record_digests!(writer, records) do
    path = Path.join([writer._identity.root, writer.operation_id <> ".staging", ".records"])
    assert {:ok, journal} = File.open(path, [:read, :binary])

    try do
      Enum.reduce(@collections, 0, fn collection, total ->
        refs = Map.fetch!(writer._records, collection)
        expected = Map.fetch!(records, collection)
        assert map_size(refs) == length(expected)

        observed =
          for {_key, reference} <- refs do
            assert {:ok, bytes} = :file.pread(journal, reference.offset, reference.byte_size)
            record = JSON.decode!(bytes)
            assert record in expected
            assert bytes == JSON.encode!(Enum.find(expected, &(&1 == record)))
            RetainedModel.known_digest!(reference.sha256, bytes)
            record
          end

        assert MapSet.new(observed) == MapSet.new(expected)
        total + map_size(refs)
      end)
    after
      assert :ok = File.close(journal)
    end
  end

  defp model_output_digests!(writer, f, location) do
    expected_paths =
      Map.keys(f.known_outputs) ++ if(location == :complete, do: ["manifest.json"], else: [])

    assert MapSet.new(Map.keys(writer._outputs)) == MapSet.new(expected_paths)
    directory = Path.join(writer._identity.root, writer.operation_id <> ".#{location}")

    Enum.reduce(writer._outputs, %{output: 0, nonempty_chunk: 0, empty_chunk: 0}, fn {path,
                                                                                      output},
                                                                                     counts ->
      bytes = File.read!(Path.join(directory, path))
      assert output.byte_size == byte_size(bytes)

      if path == "manifest.json" do
        manifest = JSON.decode!(bytes)
        assert Enum.sort(Map.keys(manifest)) == Enum.sort(@offline_top)
        assert manifest["format"] == "singularity.portable-knowledge" and manifest["version"] == 1

        assert manifest["selection"] == %{
                 "mode" => "live_heads_with_source_closure",
                 "include_tombstones" => false
               }

        for collection <- @collections do
          expected =
            Enum.map(Map.fetch!(f.records, collection), fn record ->
              if collection == :versions and record["kind"] == "asset",
                do: Map.put(record, "original_digest", Offline.sha(f.original)),
                else: record
            end)

          assert MapSet.new(manifest[to_string(collection)]) == MapSet.new(expected)
          assert length(manifest[to_string(collection)]) == length(expected)
        end

        files =
          Enum.map(f.known_outputs, fn {known_path, known_bytes} ->
            %{
              "path" => known_path,
              "media_type" => Map.fetch!(f.output_media, known_path),
              "byte_size" => byte_size(known_bytes),
              "sha256" => Offline.sha(known_bytes)
            }
          end)

        assert MapSet.new(manifest["files"]) == MapSet.new(files)
        assert length(manifest["files"]) == length(files)
      else
        assert bytes == Map.fetch!(f.known_outputs, path)
      end

      RetainedModel.known_digest!(output.sha256, bytes)
      chunk_count = max(1, div(byte_size(bytes) + @chunk - 1, @chunk))
      assert Enum.sort(Map.keys(output.chunks)) == Enum.to_list(0..(chunk_count - 1))

      Enum.reduce(output.chunks, %{counts | output: counts.output + 1}, fn {ordinal, digest},
                                                                           current ->
        offset = ordinal * @chunk
        chunk = binary_part(bytes, offset, min(@chunk, byte_size(bytes) - offset))
        RetainedModel.known_digest!(digest, chunk)
        family = if chunk == "", do: :empty_chunk, else: :nonempty_chunk
        Map.update!(current, family, &(&1 + 1))
      end)
    end)
  end

  defp model_fixture!(fallback, count, original \\ "original") do
    File.mkdir_p!(fallback)
    File.chmod!(fallback, 0o700)
    root = Singularity.Runtime.KnowledgeExportQualificationRoot.allocate!(fallback)
    roots = Map.new([:capture, :writer, :storage, :backup], &{&1, Path.join(root, to_string(&1))})

    for path <- Map.values(roots),
        do:
          (
            File.mkdir!(path)
            File.chmod!(path, 0o700)
          )

    {:ok, clock_observer} =
      Agent.start_link(fn -> %{observations: 0, maximum_rows: 0, maximum_bytes: 0} end)

    clock = fn ->
      for ledger <- :ets.all(),
          :ets.info(ledger, :owner) == self(),
          :ets.info(ledger, :name) == Writer do
        rows = :ets.lookup(ledger, :reservation)

        for {:reservation, identity} <- rows do
          assert is_tuple(identity) and tuple_size(identity) == 4

          Agent.update(
            clock_observer,
            &%{
              observations: &1.observations + 1,
              maximum_rows: max(&1.maximum_rows, length(rows)),
              maximum_bytes: max(&1.maximum_bytes, RetainedModel.e({:reservation, identity}))
            }
          )
        end
      end

      1_000
    end

    assert {:ok, spool} =
             Spool.open(%{
               root: roots.capture,
               storage_root: roots.storage,
               backup_root: roots.backup,
               clock: clock
             })

    versions =
      Enum.map(1..count, fn n ->
        version(n, "note", "included")
        |> Map.merge(%{"body_path" => note_path(n), "body_digest" => Offline.sha("Model #{n} 界")})
      end)

    mime = "application/" <> String.duplicate("m", 243)
    assert byte_size(mime) == 255

    asset =
      version(900, "asset", "included")
      |> Map.merge(%{
        "original_path" => "assets/#{uuid(900)}--#{uuid(1900)}.bin",
        "original_byte_size" => byte_size(original),
        "media_type" => mime
      })

    document = version(901, "document", "metadata_only_unselected")

    locator = %{
      "version" => 1,
      "kind" => "markdown",
      "heading_path" => List.duplicate(String.duplicate("界", 85), 64),
      "start_line" => 1,
      "end_line" => 2
    }

    assert {:ok, validated_locator} = Singularity.Core.SourceLocator.new(locator)
    assert Singularity.Core.SourceLocator.to_map(validated_locator) == locator

    fragment_id =
      Singularity.Core.DocumentFragment.id(
        uuid(1901),
        validated_locator,
        0,
        :crypto.hash(:sha256, "hidden")
      )

    assert is_binary(fragment_id) and fragment_id =~ ~r/\A[0-9a-f]{64}\z/

    fragment = %{
      "id" => fragment_id,
      "resource_id" => uuid(901),
      "version_id" => uuid(1901),
      "ordinal" => 0,
      "digest" => Offline.sha("hidden"),
      "locator" => locator,
      "extracted_path" => nil,
      "start_byte" => nil,
      "byte_size" => nil
    }

    assert byte_size(JSON.encode!(fragment)) > 16_000

    binding = %{
      "kind" => "asset",
      "resource_id" => uuid(900),
      "version_id" => uuid(1900),
      "asset_id" => uuid(2900),
      "object_id" => uuid(3900),
      "owner_scope_id" => uuid(4000),
      "classification" => "private",
      "key_domain_id" => uuid(5000),
      "domain_key_version_id" => uuid(6000),
      "domain_key_generation" => 1,
      "object_generation" => 1,
      "lookup_digest" => Offline.sha("lookup"),
      "ciphertext_hash" => Offline.sha("ciphertext"),
      "plaintext_byte_size" => byte_size(original),
      "ciphertext_byte_size" => 134 + byte_size(original),
      "storage_ref" => uuid(3900),
      "format_version" => 1,
      "plaintext_sha256" => nil
    }

    assert {:ok, spool} =
             Spool.append(spool, {:binary_binding, :asset, uuid(900), uuid(1900)}, binding)

    all_versions = versions ++ [asset, document]

    records = %{
      resources: Enum.map(all_versions, &resource/1),
      versions: all_versions,
      fragments: [fragment],
      tags: [],
      tag_assignments: [],
      relationships: [],
      attachments: [],
      citations: []
    }

    spool =
      Enum.reduce(@collections, spool, fn collection, current ->
        Enum.reduce(Map.fetch!(records, collection), current, fn row, acc ->
          assert {:ok, next} = Spool.append(acc, {:metadata, collection}, row)
          next
        end)
      end)

    spool =
      Enum.reduce(1..count, spool, fn n, current ->
        assert {:ok, current} =
                 Spool.append(current, {:note_markdown, uuid(n), uuid(n + 1000)}, "Model #{n} 界")

        assert {:ok, current} =
                 Spool.append(current, {:render_descriptions, uuid(n), uuid(n + 1000)}, %{
                   attachments: [],
                   citations: []
                 })

        current
      end)

    assert {:ok, capture} = Spool.seal(spool)

    known_notes =
      Map.new(1..count, fn n ->
        {{:note_markdown, uuid(n), uuid(n + 1000)}, "Model #{n} 界"}
      end)

    known_renders =
      Map.new(1..count, fn n ->
        {{:render_descriptions, uuid(n), uuid(n + 1000)},
         JSON.encode!(%{"attachments" => [], "citations" => []})}
      end)

    original_path = asset["original_path"]

    known_outputs =
      Map.new(1..count, fn n -> {note_path(n), "Model #{n} 界"} end)
      |> Map.put(original_path, original)

    %{
      capture: capture,
      roots: roots,
      records: records,
      known_refs: %{
        text_refs: known_notes,
        render_refs: known_renders,
        binary_refs: %{{:binary_binding, :asset, uuid(900), uuid(1900)} => JSON.encode!(binding)}
      },
      known_outputs: known_outputs,
      output_media:
        Map.new(known_outputs, fn {path, _} ->
          {path, if(path == original_path, do: mime, else: "text/markdown")}
        end),
      original: original,
      root: root,
      clock_observer: clock_observer
    }
  end
end
