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
    def utc_now(context), do: CustodyReader.utc_now(context)
    def revalidate(context, binding), do: CustodyReader.revalidate(context, binding)

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

    def read_range(context, handle, range) do
      send(context.parent, {:live_read, :ciphertext_range, range})
      LocalFilesystemAdapter.read_range(context, handle, range)
    end

    defp result_kind({:ok, _}), do: :ok
    defp result_kind({:error, _}), do: :error
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

  setup context do
    fixture =
      fixture!(
        context.tmp_dir,
        plaintext(Map.get(context, :plaintext, :zero)),
        Map.get(context, :barrier)
      )

    %{fixture: fixture}
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

    document = KnowledgeFixtures.document!(source_binary)
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
