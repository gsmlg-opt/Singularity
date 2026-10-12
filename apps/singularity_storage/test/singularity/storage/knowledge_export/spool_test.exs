defmodule Singularity.Storage.KnowledgeExport.SpoolTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error

  @moduletag :tmp_dir
  @spool Singularity.Storage.KnowledgeExport.Spool
  @collections ~w(resources versions fragments tags tag_assignments relationships attachments citations)a
  @resource "00000000-0000-4000-8000-000000000001"
  @version "00000000-0000-4000-8000-000000000002"
  @time "2026-10-11T01:02:03.123456Z"

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "export")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    sentinel = Path.join(root, "neighbor-sentinel")
    File.write!(sentinel, "neighbor")
    %{root: root, sentinel: sentinel, context: trusted_context(tmp_dir, root)}
  end

  test "open creates a distinct private operation with exclusive files and exact cleanup", c do
    {:ok, one} = call(:open, [c.context])
    {:ok, two} = call(:open, [c.context])
    refute one.capture_id == two.capture_id
    one_dir = operation_dir(c.root, one)
    two_dir = operation_dir(c.root, two)
    refute one_dir == two_dir
    assert_mode(one_dir, 0o700)
    assert_private_tree(one_dir)
    assert :ok = call(:abort, [one])
    assert :ok = call(:abort, [one])
    refute File.exists?(one_dir)
    assert File.dir?(two_dir)
    assert File.read!(c.sentinel) == "neighbor"
    assert :ok = call(:abort, [two])
    assert File.read!(c.sentinel) == "neighbor"
  end

  test "trusted root rejects relative roots insecure permissions aliases and symlink parents",
       c do
    for root <- [
          "relative",
          c.context.storage_root,
          c.context.backup_root,
          Path.join(c.context.storage_root, "nested"),
          Path.dirname(c.context.storage_root)
        ] do
      assert_error(call(:open, [%{c.context | root: root}]))
    end

    File.chmod!(c.root, 0o755)
    assert_error(call(:open, [c.context]))
    File.chmod!(c.root, 0o700)
    link = Path.join(Path.dirname(c.root), "export-link")
    File.ln_s!(c.root, link)
    assert_error(call(:open, [%{c.context | root: link}]))
    assert File.read!(c.sentinel) == "neighbor"
  end

  test "fixed limits have no trusted-context public or test quota override", c do
    for key <- [
          :limits,
          :quota,
          :max_bytes,
          :metadata_bytes,
          :file_bytes,
          :selected_keys,
          :metadata_records,
          :execution_ms
        ] do
      assert_error(call(:open, [Map.put(c.context, key, 1)]))
    end
  end

  test "unsealed content is unreadable and sealed content rejects stale append", c do
    {:ok, open} = call(:open, [c.context])
    assert_error(call(:read_page, [open, cursor(open, :resources), 500]))
    {:ok, appended} = call(:append, [open, {:metadata, :resources}, resource(1)])
    {:ok, sealed} = call(:seal, [appended])
    assert_error(call(:append, [open, {:metadata, :resources}, resource(2)]))
    assert_error(call(:append, [appended, {:metadata, :resources}, resource(2)]))
    assert_error(call(:append, [sealed, {:metadata, :resources}, resource(2)]))
    assert :ok = call(:abort, [sealed])
  end

  test "metadata uses stable fixed collections with capture-bound keyset pages", c do
    {:ok, spool} = call(:open, [c.context])

    spool =
      Enum.reduce(501..1//-1, spool, fn n, acc ->
        {:ok, next} = call(:append, [acc, {:metadata, :resources}, resource(n)])
        next
      end)

    {:ok, sealed} = call(:seal, [spool])
    {records, pages} = pages(sealed, cursor(sealed, :resources), [], [])
    assert records == Enum.map(1..501, &resource/1)
    assert Enum.all?(pages, &(length(&1) in 1..500))
    assert length(pages) >= 2

    assert {:ok, %{records: [_], next_cursor: next}} =
             call(:read_page, [sealed, cursor(sealed, :resources), 1])

    refute is_nil(next)
    assert_error(call(:read_page, [sealed, Map.put(next, :collection, :tags), 500]))
    assert_error(call(:read_page, [sealed, Map.put(next, :after, uuid(501)), 500]))

    for collection <- @collections -- [:resources] do
      assert {:ok, %{records: [], next_cursor: nil}} =
               call(:read_page, [sealed, cursor(sealed, collection), 500])
    end

    assert :ok = call(:abort, [sealed])
  end

  test "cursors reject capture selector extra-field and serialized-term substitution", c do
    {:ok, first} = call(:open, [c.context])
    {:ok, second} = call(:open, [c.context])
    {:ok, first} = call(:seal, [first])
    {:ok, second} = call(:seal, [second])

    for invalid <- [
          nil,
          "resources",
          :erlang.term_to_binary(cursor(first, :resources)),
          cursor(second, :resources),
          cursor(first, :files),
          cursor(first, :note_markdown),
          Map.put(cursor(first, :resources), :sql, "SELECT markdown"),
          %{cursor(first, :resources) | after: "../../secret"}
        ] do
      assert_error(call(:read_page, [first, invalid, 500]))
    end

    for limit <- [0, -1, 501, 1.0, nil] do
      assert_error(call(:read_page, [first, cursor(first, :resources), limit]))
    end

    assert :ok = call(:abort, [first])
    assert :ok = call(:abort, [second])
  end

  test "metadata selectors reject arbitrary fields SQL paths terms and file channels", c do
    for selector <- [
          :resources,
          {:metadata, :unknown},
          {:metadata, "resources"},
          {:metadata, :files},
          {:sql, "SELECT * FROM content.note_versions"},
          {:path, "/tmp/private"}
        ] do
      {:ok, spool} = call(:open, [c.context])
      assert_error(call(:append, [spool, selector, resource(1)]))
      assert :ok = call(:abort, [spool])
    end

    for record <- [
          Map.put(resource(1), "storage_ref", "private"),
          Map.put(resource(1), "vault_id", @resource),
          :erlang.term_to_binary(resource(1)),
          %{__struct__: Error}
        ] do
      {:ok, spool} = call(:open, [c.context])
      assert_error(call(:append, [spool, {:metadata, :resources}, record]))
      assert :ok = call(:abort, [spool])
    end
  end

  test "canonical Note chunks seal an exact identity length and SHA256 reference", c do
    body = "\uFEFF界\r\n" <> String.duplicate("a", 65_536)
    key = {:note_markdown, @resource, @version}
    {:ok, spool} = call(:open, [c.context])
    spool = append_chunks(spool, key, body)
    {:ok, sealed} = call(:seal, [spool])
    ref = Map.fetch!(sealed.text_refs, key)
    assert %{capture_id: capture, selector: ^key, byte_size: size, sha256: digest} = ref
    assert capture == sealed.capture_id
    assert size == byte_size(body)
    assert digest == sha(body)
    assert read_text(sealed, ref) == body
    assert :ok = call(:abort, [sealed])
  end

  test "empty Note and fragment text retain their actual empty digest", c do
    note = {:note_markdown, @resource, @version}
    fragment = {:fragment_text, @resource, @version, 0, String.duplicate("a1", 32)}
    {:ok, spool} = call(:open, [c.context])
    {:ok, spool} = call(:append, [spool, note, ""])
    {:ok, spool} = call(:append, [spool, fragment, ""])
    {:ok, sealed} = call(:seal, [spool])

    for key <- [note, fragment] do
      ref = Map.fetch!(sealed.text_refs, key)
      assert ref.byte_size == 0
      assert ref.sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      assert {:ok, ""} = call(:read_chunk, [sealed, ref, 0])
      assert_error(call(:read_chunk, [sealed, ref, 1]))
    end

    assert :ok = call(:abort, [sealed])
  end

  test "exact sealed refs reject cross-capture identity offset length digest and selector changes",
       c do
    key = {:note_markdown, @resource, @version}
    {:ok, spool} = call(:open, [c.context])
    {:ok, spool} = call(:append, [spool, key, "canonical"])
    {:ok, sealed} = call(:seal, [spool])
    ref = Map.fetch!(sealed.text_refs, key)

    for bad <- [
          Map.put(ref, :capture_id, Ecto.UUID.generate()),
          Map.put(ref, :selector, {:note_markdown, @resource, uuid(3)}),
          Map.put(ref, :offset, ref.offset + 1),
          Map.put(ref, :byte_size, ref.byte_size + 1),
          Map.put(ref, :sha256, String.duplicate("0", 64)),
          Map.put(ref, :path, c.sentinel),
          :erlang.term_to_binary(ref)
        ] do
      assert_error(call(:read_chunk, [sealed, bad, 0]))
    end

    for index <- [-1, 1, 1.0, nil], do: assert_error(call(:read_chunk, [sealed, ref, index]))
    assert :ok = call(:abort, [sealed])
  end

  test "Note limit applies to accumulated canonical bytes rather than each chunk", c do
    key = {:note_markdown, @resource, @version}
    {:ok, spool} = call(:open, [c.context])
    spool = append_chunks(spool, key, String.duplicate("x", 1_048_576))
    assert_error(call(:append, [spool, key, "x"]))
    assert :ok = call(:abort, [spool])
  end

  test "fragment limit applies across repeated appends and chunks never exceed 64KiB", c do
    key = {:fragment_text, @resource, @version, 0, String.duplicate("a1", 32)}
    {:ok, spool} = call(:open, [c.context])
    {:ok, spool} = call(:append, [spool, key, String.duplicate("x", 65_536)])
    assert_error(call(:append, [spool, key, "x"]))

    assert_error(
      call(:append, [spool, {:note_markdown, @resource, @version}, String.duplicate("x", 65_537)])
    )

    assert :ok = call(:abort, [spool])
  end

  test "UTF8 validation handles split codepoints and refuses incomplete NUL or malformed text",
       c do
    key = {:note_markdown, @resource, @version}
    {:ok, spool} = call(:open, [c.context])
    {:ok, spool} = call(:append, [spool, key, <<0xE7>>])
    {:ok, spool} = call(:append, [spool, key, <<0x95, 0x8C>>])
    {:ok, sealed} = call(:seal, [spool])
    assert read_text(sealed, Map.fetch!(sealed.text_refs, key)) == "界"
    assert :ok = call(:abort, [sealed])

    for text <- [<<0xE7>>, <<255>>, "private\0"] do
      {:ok, spool} = call(:open, [c.context])
      result = call(:append, [spool, key, text])

      case result do
        {:ok, next} -> assert_error(call(:seal, [next]))
        {:error, %Error{}} -> :ok
      end

      assert :ok = call(:abort, [spool])
    end
  end

  test "Document fragment aggregate allows exactly 16MiB and rejects a further byte", c do
    {:ok, spool} = call(:open, [c.context])

    spool =
      Enum.reduce(0..255, spool, fn ordinal, acc ->
        key = {:fragment_text, @resource, @version, ordinal, sha(Integer.to_string(ordinal))}
        {:ok, next} = call(:append, [acc, key, String.duplicate("x", 65_536)])
        next
      end)

    key = {:fragment_text, @resource, @version, 256, sha("256")}
    assert_error(call(:append, [spool, key, "x"]))
    assert :ok = call(:abort, [spool])
  end

  test "fragment ordinal count is fixed at 4096 even for empty text", c do
    {:ok, spool} = call(:open, [c.context])

    spool =
      Enum.reduce(0..4095, spool, fn ordinal, acc ->
        key = {:fragment_text, @resource, @version, ordinal, sha(Integer.to_string(ordinal))}
        {:ok, next} = call(:append, [acc, key, ""])
        next
      end)

    key = {:fragment_text, @resource, @version, 4096, sha("4096")}
    assert_error(call(:append, [spool, key, ""]))
    assert :ok = call(:abort, [spool])
  end

  test "sealed fragment sets reject ordinal gaps and conflicting identity at one ordinal", c do
    {:ok, spool} = call(:open, [c.context])

    {:ok, spool} =
      call(:append, [spool, {:fragment_text, @resource, @version, 1, sha("gap")}, "gap"])

    assert_error(call(:seal, [spool]))
    assert :ok = call(:abort, [spool])
    {:ok, spool} = call(:open, [c.context])

    {:ok, spool} =
      call(:append, [spool, {:fragment_text, @resource, @version, 0, sha("one")}, "one"])

    assert_error(
      call(:append, [spool, {:fragment_text, @resource, @version, 0, sha("other")}, "other"])
    )

    assert :ok = call(:abort, [spool])
  end

  test "pending Asset draft seals only with its exact private binary binding", c do
    key = {:binary_binding, :asset, uuid(1), uuid(1_001)}
    binding = asset_binding(1, 12)
    draft = Map.put(asset_version(1, 12), "original_digest", nil)

    assert {:error, %Error{code: :invalid}} =
             Singularity.Core.KnowledgeExportManifest.record(:versions, draft)

    {:ok, spool} = call(:open, [c.context])
    {:ok, spool} = call(:append, [spool, key, binding])
    {:ok, spool} = call(:append, [spool, {:metadata, :versions}, draft])
    {:ok, sealed} = call(:seal, [spool])
    ref = Map.fetch!(sealed.binary_refs, key)
    assert ref.capture_id == sealed.capture_id
    assert ref.selector == key
    assert JSON.decode!(read_text(sealed, ref)) == binding
    assert sealed.accounting.original_bytes == 12
    assert sealed.accounting.metadata_records >= 2
    assert sealed.accounting.spool_bytes >= disk_bytes(operation_dir(c.root, sealed))

    assert_error(
      call(:read_chunk, [
        sealed,
        Map.put(ref, :selector, {:note_markdown, uuid(1), uuid(1_001)}),
        0
      ])
    )

    assert {:ok, %{records: [^draft], next_cursor: nil}} =
             call(:read_page, [sealed, cursor(sealed, :versions), 500])

    assert_error(call(:read_page, [sealed, cursor(sealed, :binary_bindings), 500]))
    refute Map.has_key?(draft, "binary_ref")
    refute Map.has_key?(draft, "storage_ref")
    assert :ok = call(:abort, [sealed])
  end

  test "missing or retargeted private Asset binding cannot seal a pending draft", c do
    draft = Map.put(asset_version(1, 12), "original_digest", nil)

    for binding <- [nil, asset_binding(2, 12), asset_binding(1, 13)] do
      {:ok, spool} = call(:open, [c.context])

      spool =
        if binding do
          key = {:binary_binding, :asset, binding["resource_id"], binding["version_id"]}
          {:ok, next} = call(:append, [spool, key, binding])
          next
        else
          spool
        end

      case call(:append, [spool, {:metadata, :versions}, draft]) do
        {:ok, next} -> assert_error(call(:seal, [next]))
        {:error, %Error{}} -> :ok
      end

      assert :ok = call(:abort, [spool])
    end
  end

  test "ordinary finalized object UUID remains exact private binding evidence", c do
    key = {:binary_binding, :asset, uuid(1), uuid(1_001)}
    binding = asset_binding(1, 12)
    binding = Map.put(binding, "storage_ref", binding["object_id"])
    draft = Map.put(asset_version(1, 12), "original_digest", nil)

    {:ok, spool} = call(:open, [c.context])
    {:ok, spool} = call(:append, [spool, key, binding])
    {:ok, spool} = call(:append, [spool, {:metadata, :versions}, draft])
    {:ok, sealed} = call(:seal, [spool])
    ref = Map.fetch!(sealed.binary_refs, key)
    assert ref.capture_id == sealed.capture_id
    assert ref.selector == key
    assert JSON.decode!(read_text(sealed, ref)) == binding

    assert {:ok, %{records: [^draft], next_cursor: nil}} =
             call(:read_page, [sealed, cursor(sealed, :versions), 500])

    assert draft["original_digest"] == nil
    refute Map.has_key?(draft, "binary_ref")
    refute Map.has_key?(draft, "storage_ref")
    assert :ok = call(:abort, [sealed])
    assert File.read!(c.sentinel) == "neighbor"
  end

  test "private storage reference binds exact object owner domain and lookup without aliases",
       c do
    key = {:binary_binding, :asset, uuid(1), uuid(1_001)}
    binding = asset_binding(1, 12)
    canonical = binding["storage_ref"]
    digest = binding["lookup_digest"]
    other_digest = sha("different keyed lookup")
    wrong_prefix = if binary_part(digest, 0, 2) == "00", do: "01", else: "00"

    invalid_refs = [
      uuid(3_002),
      uuid(9_001),
      String.replace(canonical, uuid(4_000), uuid(4_001)),
      String.replace(canonical, uuid(5_000), uuid(5_001)),
      "objects/#{uuid(4_000)}/#{uuid(5_000)}/hmac-sha256/#{binary_part(other_digest, 0, 2)}/#{other_digest}",
      String.replace(canonical, "/hmac-sha256/", "/hmac-sha256//"),
      "./" <> canonical,
      "objects/#{uuid(3_001)}.bin",
      "objects/arbitrary.bin",
      "objects/../" <> canonical,
      "/" <> canonical
    ]

    invalid_bindings =
      Enum.map(invalid_refs, &Map.put(binding, "storage_ref", &1)) ++
        [
          Map.put(binding, "owner_scope_id", uuid(4_001)),
          Map.put(binding, "key_domain_id", uuid(5_001)),
          Map.put(binding, "lookup_digest", other_digest),
          Map.put(
            binding,
            "storage_ref",
            String.replace(
              canonical,
              binary_part(digest, 0, 2) <> "/" <> digest,
              wrong_prefix <> "/" <> digest
            )
          )
        ]

    for invalid <- invalid_bindings do
      {:ok, spool} = call(:open, [c.context])
      assert_error(call(:append, [spool, key, invalid]))
      assert_error(call(:seal, [spool]))
      assert :ok = call(:abort, [spool])
    end

    assert File.read!(c.sentinel) == "neighbor"
  end

  test "private binary binding rejects invented digest keys host paths and selector mismatch",
       c do
    key = {:binary_binding, :asset, uuid(1), uuid(1_001)}

    for binding <- [
          Map.put(asset_binding(1, 12), "plaintext_sha256", sha("invented")),
          Map.put(asset_binding(1, 12), "wrapped_dek", "key material"),
          Map.put(asset_binding(1, 12), "storage_ref", c.sentinel),
          Map.put(asset_binding(1, 12), "owner_scope_id", "caller-selected"),
          asset_binding(2, 12)
        ] do
      {:ok, spool} = call(:open, [c.context])
      assert_error(call(:append, [spool, key, binding]))
      assert :ok = call(:abort, [spool])
    end

    assert File.read!(c.sentinel) == "neighbor"
  end

  test "valid escaped locator record larger than a content chunk remains metadata", c do
    locator = %{
      "version" => 1,
      "kind" => "markdown",
      "heading_path" => List.duplicate(String.duplicate("\u0001", 255), 64)
    }

    record = %{
      "note_resource_id" => @resource,
      "note_version_id" => @version,
      "id" => uuid(3),
      "ordinal" => 0,
      "source_resource_id" => uuid(4),
      "source_version_id" => uuid(5),
      "fragment_id" => sha("fragment"),
      "locator" => locator
    }

    # JSON escaping, not a new record quota; this oracle does not use Spool's encoder.
    assert byte_size(JSON.encode!(record)) > 65_536
    {:ok, spool} = call(:open, [c.context])
    {:ok, spool} = call(:append, [spool, {:metadata, :citations}, record])
    {:ok, sealed} = call(:seal, [spool])

    assert {:ok, %{records: [^record], next_cursor: nil}} =
             call(:read_page, [sealed, cursor(sealed, :citations), 500])

    assert :ok = call(:abort, [sealed])
  end

  test "actual disk bytes framing superseded metadata and private render records remain counted",
       c do
    {:ok, spool} = call(:open, [c.context])
    {:ok, spool} = call(:append, [spool, {:metadata, :resources}, resource(1)])
    first = spool.accounting
    {:ok, spool} = call(:append, [spool, {:metadata, :resources}, resource(1, "promoted")])

    {:ok, spool} =
      call(:append, [
        spool,
        {:render_descriptions, @resource, @version},
        %{attachments: [], citations: []}
      ])

    {:ok, spool} = call(:append, [spool, {:note_markdown, @resource, @version}, "text"])
    {:ok, sealed} = call(:seal, [spool])
    assert sealed.accounting.metadata_records > first.metadata_records
    assert sealed.accounting.metadata_records >= 3
    assert sealed.accounting.spool_bytes > first.spool_bytes + 4
    assert sealed.accounting.spool_bytes >= disk_bytes(operation_dir(c.root, sealed))
    assert sealed.accounting.spool_bytes <= 1_073_741_824
    assert sealed.accounting.metadata_records <= 1_000_000
    assert sealed.accounting.selected_keys <= 100_000
    assert :erts_debug.flat_size(sealed) < 10_000
    assert :ok = call(:abort, [sealed])
  end

  test "indexes retain references rather than canonical corpus text", c do
    body = String.duplicate("CANARY_BODY_", 5_000)
    {:ok, spool} = call(:open, [c.context])
    spool = append_chunks(spool, {:note_markdown, @resource, @version}, body)
    {:ok, sealed} = call(:seal, [spool])
    refute inspect(sealed, limit: :infinity, printable_limit: :infinity) =~ "CANARY_BODY_"
    assert :erts_debug.flat_size(sealed) < 10_000
    assert :ok = call(:abort, [sealed])
  end

  test "known original sizes reserve the fixed final-file total without allocating originals",
       c do
    {:ok, spool} = call(:open, [c.context])

    {:ok, spool} =
      call(:append, [spool, {:metadata, :versions}, asset_version(1, 68_719_476_736)])

    assert spool.accounting.original_bytes == 68_719_476_736
    assert_error(call(:append, [spool, {:metadata, :versions}, asset_version(2, 1)]))
    assert :ok = call(:abort, [spool])
  end

  test "fixed exhausted USED counters reject further append without a quota override", c do
    # SYNTHETIC COUNTER ARITHMETIC, not a 1GiB/1M-record allocation claim.
    # Limits stay fixed; only already-consumed accounting is placed at a boundary.
    for {field, used} <- [
          spool_bytes: 1_073_741_824,
          metadata_records: 1_000_000,
          selected_keys: 100_000
        ] do
      {:ok, spool} = call(:open, [c.context])
      exhausted = %{spool | accounting: Map.put(spool.accounting, field, used)}
      assert_error(call(:append, [exhausted, {:metadata, :resources}, resource(1)]))
      assert :ok = call(:abort, [spool])
    end
  end

  test "synthetic ENOSPC at bounded write boundary aborts with content-free error", c do
    # SYNTHETIC ERROR BRANCH: real path/mode/identity/cleanup, injected disk error.
    armed = :atomics.new(1, [])

    writer = fn device, bytes ->
      assert is_binary(bytes) and byte_size(bytes) <= 65_536

      if :atomics.get(armed, 1) == 1,
        do: {:error, :enospc},
        else: IO.binwrite(device, bytes)
    end

    {:ok, spool} = call(:open, [Map.put(c.context, :write, writer)])
    :atomics.put(armed, 1, 1)
    result = call(:append, [spool, {:note_markdown, @resource, @version}, "DISK_FULL_CANARY"])
    assert_error(result)
    refute inspect(result) =~ "DISK_FULL_CANARY"
    assert_error(call(:seal, [spool]))
    refute File.exists?(operation_dir(c.root, spool))
    assert File.read!(c.sentinel) == "neighbor"
    assert :ok = call(:abort, [spool])
  end

  test "deadline uses the fixed fifteen minutes and expiry closes read and write", c do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 0)
    {:ok, spool} = call(:open, [Map.put(c.context, :clock, fn -> :atomics.get(clock, 1) end)])
    {:ok, spool} = call(:append, [spool, {:note_markdown, @resource, @version}, "private"])
    {:ok, sealed} = call(:seal, [spool])
    :atomics.put(clock, 1, 900_000)

    assert_error(
      call(:read_chunk, [
        sealed,
        Map.fetch!(
          sealed.text_refs,
          {:note_markdown, @resource, @version}
        ),
        0
      ])
    )

    assert_error(call(:read_page, [sealed, cursor(sealed, :resources), 1]))
    assert :ok = call(:abort, [sealed])
    assert File.read!(c.sentinel) == "neighbor"
  end

  test "tampered and truncated sealed payloads never yield unchecked bytes", c do
    for mutation <- [:tamper, :truncate] do
      {:ok, spool} = call(:open, [c.context])
      key = {:note_markdown, @resource, @version}
      {:ok, spool} = call(:append, [spool, key, "UNIQUE_CANONICAL_PAYLOAD_849f"])
      {:ok, sealed} = call(:seal, [spool])
      path = payload_file(operation_dir(c.root, sealed), "UNIQUE_CANONICAL_PAYLOAD_849f")
      bytes = File.read!(path)

      changed =
        if mutation == :tamper,
          do:
            String.replace(
              bytes,
              "UNIQUE_CANONICAL_PAYLOAD_849f",
              "UNIQUE_CANONICAL_PAYLOAD_849g"
            ),
          else: binary_part(bytes, 0, div(byte_size(bytes), 2))

      File.write!(path, changed)
      assert_error(call(:read_chunk, [sealed, Map.fetch!(sealed.text_refs, key), 0]))
      assert :ok = call(:abort, [sealed])
    end

    assert File.read!(c.sentinel) == "neighbor"
  end

  test "cancel invalidates sealed references and never deletes neighboring operations", c do
    {:ok, one} = call(:open, [c.context])
    {:ok, two} = call(:open, [c.context])
    {:ok, one} = call(:append, [one, {:metadata, :resources}, resource(1)])
    {:ok, sealed} = call(:seal, [one])
    assert :ok = call(:abort, [sealed])
    assert_error(call(:read_page, [sealed, cursor(sealed, :resources), 500]))
    assert File.dir?(operation_dir(c.root, two))
    assert File.read!(c.sentinel) == "neighbor"
    assert :ok = call(:abort, [two])
  end

  test "cleanup rejects forged operation identity and symlink replacement", c do
    {:ok, spool} = call(:open, [c.context])
    directory = operation_dir(c.root, spool)
    assert_error(call(:abort, [Map.put(spool, :capture_id, "neighbor-sentinel")]))
    assert File.read!(c.sentinel) == "neighbor"
    displaced = directory <> "-displaced"
    File.rename!(directory, displaced)
    File.ln_s!(Path.dirname(c.root), directory)
    assert_error(call(:abort, [spool]))
    assert File.read!(c.sentinel) == "neighbor"
    File.rm!(directory)
    File.rename!(displaced, directory)
    assert :ok = call(:abort, [spool])
  end

  # BEGIN sealed-record-iteration test-only additions
  test "exact metadata reads match actual native pages for all fixed scalar and composite keys",
       c do
    records = metadata_records()
    sealed = metadata_capture(c, records)

    for collection <- @collections do
      expected = records[collection]

      assert {:ok, %{records: ^expected, next_cursor: nil}} =
               call(:read_page, [sealed, cursor(sealed, collection), 500])

      for record <- expected do
        assert {:ok, ^record} =
                 call(:read_metadata, [sealed, collection, metadata_key(collection, record)])
      end

      assert {:ok, ^expected} =
               call(:reduce_metadata, [
                 sealed,
                 collection,
                 [],
                 fn record, acc -> {:ok, acc ++ [record]} end
               ])
    end

    assert_metadata_cleanup(c, sealed)
  end

  test "ordered metadata reduction preserves exact composite version keys rather than flattening them",
       c do
    expected = Enum.map(1..5, &asset_version(&1, 12))
    sealed = metadata_capture(c, %{versions: Enum.reverse(expected)})
    {paged, _} = pages(sealed, cursor(sealed, :versions), [], [])
    assert paged == expected

    assert {:ok, reversed} =
             call(:reduce_metadata, [
               sealed,
               :versions,
               [],
               fn record, acc -> {:ok, [metadata_key(:versions, record) | acc]} end
             ])

    assert Enum.reverse(reversed) == Enum.map(expected, &metadata_key(:versions, &1))
    assert_metadata_cleanup(c, sealed)
  end

  test "ordered metadata reduction returns every native record exactly once independent of insertion",
       c do
    expected = Enum.map(1..7, &resource/1)
    sealed = metadata_capture(c, %{resources: Enum.reverse(expected)})
    {paged, _} = pages(sealed, cursor(sealed, :resources), [], [])
    assert paged == expected

    assert {:ok, reversed} =
             call(:reduce_metadata, [
               sealed,
               :resources,
               [],
               fn record, acc -> {:ok, [record | acc]} end
             ])

    assert Enum.reverse(reversed) == expected
    assert_metadata_cleanup(c, sealed)
  end

  test "empty ordered metadata reduction preserves accumulator and never calls consumer", c do
    sealed = metadata_capture(c, %{})
    token = make_ref()

    assert {:ok, {:initial, 7}} =
             call(:reduce_metadata, [
               sealed,
               :resources,
               {:initial, 7},
               fn _, _ ->
                 send(self(), token)
                 {:error, Error.new(:forbidden)}
               end
             ])

    refute_receive ^token, 0
    assert_metadata_cleanup(c, sealed)
  end

  test "exact metadata rejects unknown collections missing keys and coercion without aborting source",
       c do
    sealed = metadata_capture(c, metadata_records())
    version_key = {uuid(1), uuid(1_001)}

    for {collection, key} <- [
          {:unknown, uuid(1)},
          {"resources", uuid(1)},
          {:files, uuid(1)},
          {:resources, nil},
          {:resources, uuid(999)},
          {:resources, [uuid(1)]},
          {:versions, Tuple.to_list(version_key)},
          {:versions, :erlang.term_to_binary(version_key)},
          {:versions, {uuid(1), uuid(999)}}
        ] do
      assert {:error, %Error{code: :invalid}} = call(:read_metadata, [sealed, collection, key])
    end

    for args <- [
          [sealed, :unknown, [], fn _, acc -> {:ok, acc} end],
          [sealed, "resources", [], fn _, acc -> {:ok, acc} end],
          [sealed, :resources, [], nil],
          [sealed, :resources, [], fn _ -> :ok end]
        ] do
      assert {:error, %Error{code: :invalid}} = call(:reduce_metadata, args)
    end

    for invalid <- [nil, %{}, "sealed", :erlang.term_to_binary(sealed)],
        method <- [:point, :reduce] do
      assert_error(metadata_read(method, invalid, :resources, uuid(1)))
    end

    assert {:ok, record} = call(:read_metadata, [sealed, :resources, uuid(1)])
    assert record == resource(1)
    assert_metadata_cleanup(c, sealed)
  end

  test "exact metadata detects swapped native catalog keys before point or reduction delivery",
       c do
    for method <- [:point, :reduce] do
      sealed = metadata_capture(c, %{resources: [resource(1), resource(2)]})
      first = sealed._collections.resources[uuid(1)]
      second = sealed._collections.resources[uuid(2)]
      entries = %{uuid(1) => second, uuid(2) => first}
      substituted = %{sealed | _collections: Map.put(sealed._collections, :resources, entries)}

      assert_metadata_native_denial(
        c,
        sealed,
        metadata_read(method, substituted, :resources, uuid(1))
      )
    end
  end

  test "same-ID resource and tag whole-frame substitution cannot cross the native collection selector",
       c do
    for method <- [:point, :reduce] do
      tag = %{"id" => uuid(1), "display_value" => "Tag", "normalized_key" => "tag"}
      sealed = metadata_capture(c, %{resources: [resource(1)], tags: [tag]})
      assert {:ok, %{records: [^tag]}} = call(:read_page, [sealed, cursor(sealed, :tags), 500])
      tag_frame = sealed._collections.tags[uuid(1)]
      resource_frame = sealed._collections.resources[uuid(1)]

      collections =
        sealed._collections
        |> Map.put(:resources, %{uuid(1) => tag_frame})
        |> Map.put(:tags, %{uuid(1) => resource_frame})

      substituted = %{sealed | _collections: collections}

      assert_metadata_native_denial(
        c,
        sealed,
        metadata_read(method, substituted, :resources, uuid(1))
      )
    end
  end

  test "genuine wrong native index reference cannot authenticate a different metadata payload",
       c do
    for method <- [:point, :reduce] do
      sealed = metadata_capture(c, %{resources: [resource(1), resource(2)]})
      first = sealed._collections.resources[uuid(1)]
      second = sealed._collections.resources[uuid(2)]
      substituted_frame = %{first | index: second.index}
      entries = Map.put(sealed._collections.resources, uuid(1), substituted_frame)
      substituted = %{sealed | _collections: Map.put(sealed._collections, :resources, entries)}

      assert_metadata_native_denial(
        c,
        sealed,
        metadata_read(method, substituted, :resources, uuid(1))
      )
    end
  end

  test "point and reduction authenticate real payload and index bytes not only native file lengths",
       c do
    for file <- [:payload, :index], method <- [:point, :reduce] do
      sealed = metadata_capture(c, %{resources: [resource(1)]})
      frame = sealed._collections.resources[uuid(1)]
      ref = if file == :index, do: frame.index, else: frame
      path = Path.join(operation_dir(c.root, sealed), Atom.to_string(file))
      bytes = File.read!(path)
      position = ref.offset + 40
      <<prefix::binary-size(position), original, rest::binary>> = bytes
      File.write!(path, prefix <> <<Bitwise.bxor(original, 1)>> <> rest)
      assert File.stat!(path).size == byte_size(bytes)
      assert_metadata_native_denial(c, sealed, metadata_read(method, sealed, :resources, uuid(1)))
    end
  end

  test "point and reduction reject unsealed stale and already aborted native captures", c do
    {:ok, initial} = call(:open, [c.context])
    {:ok, appended} = call(:append, [initial, {:metadata, :resources}, resource(1)])
    {:ok, sealed} = call(:seal, [appended])

    for descriptor <- [initial, appended], method <- [:point, :reduce] do
      assert {:error, %Error{code: :invalid}} =
               metadata_read(method, descriptor, :resources, uuid(1))
    end

    assert :ok = call(:abort, [sealed])

    for method <- [:point, :reduce] do
      assert {:error, %Error{code: :invalid}} = metadata_read(method, sealed, :resources, uuid(1))
    end

    assert File.ls!(c.root) == ["neighbor-sentinel"]
    assert File.read!(c.sentinel) == "neighbor"
  end

  test "point and reduction expire at the unchanged deadline and clean only their owned capture",
       c do
    for method <- [:point, :reduce] do
      now = :atomics.new(1, signed: true)
      :atomics.put(now, 1, 0)

      sealed =
        metadata_capture(c, %{resources: [resource(1)]}, %{clock: fn -> :atomics.get(now, 1) end})

      assert sealed._deadline == 900_000
      :atomics.put(now, 1, sealed._deadline)
      assert_metadata_native_denial(c, sealed, metadata_read(method, sealed, :resources, uuid(1)))
    end
  end

  test "forged capture identity cannot read metadata or remove the genuine owned operation", c do
    sealed = metadata_capture(c, %{resources: [resource(1)]})
    forged = %{sealed | capture_id: uuid(999)}

    for method <- [:point, :reduce] do
      assert {:error, %Error{code: :invalid}} = metadata_read(method, forged, :resources, uuid(1))
    end

    assert File.dir?(operation_dir(c.root, sealed))
    assert_metadata_cleanup(c, sealed)
  end

  test "native operation identity drift denies metadata without adopting or deleting the replacement",
       c do
    for method <- [:point, :reduce] do
      sealed = metadata_capture(c, %{resources: [resource(1)]})
      directory = operation_dir(c.root, sealed)
      displaced = directory <> "-owned"
      File.rename!(directory, displaced)
      File.mkdir!(directory)
      File.chmod!(directory, 0o700)
      foreign = Path.join(directory, "foreign-sentinel")
      File.write!(foreign, "foreign")

      try do
        assert_error(metadata_read(method, sealed, :resources, uuid(1)))
        assert File.read!(foreign) == "foreign"
        assert File.dir?(displaced)
        assert File.read!(c.sentinel) == "neighbor"
      after
        File.rm!(foreign)
        File.rmdir!(directory)
        File.rename!(displaced, directory)
        assert_metadata_cleanup(c, sealed)
      end
    end
  end

  test "ordinary reduction consumer error halts once strips details and leaves native capture readable",
       c do
    sealed = metadata_capture(c, %{resources: [resource(1), resource(2)]})
    token = make_ref()
    canary = "METADATA_CONSUMER_PRIVATE_290a"

    result =
      call(:reduce_metadata, [
        sealed,
        :resources,
        0,
        fn record, _ ->
          send(self(), {token, record["id"]})

          {:error,
           Error.new(:forbidden, retryable?: true, message: canary, details: %{body: canary})}
        end
      ])

    assert {:error, %Error{code: :forbidden, retryable?: true, details: %{}, message: nil}} =
             result

    assert result == {:error, Error.new(:forbidden, retryable?: true)}
    refute inspect(result) =~ canary
    assert_receive {^token, first}
    assert first == uuid(1)
    refute_receive {^token, _}, 0
    assert {:ok, record} = call(:read_metadata, [sealed, :resources, uuid(2)])
    assert record == resource(2)
    assert_metadata_cleanup(c, sealed)
  end

  test "raised thrown and malformed reduction callbacks fail content-free without false native corruption",
       c do
    sealed = metadata_capture(c, %{resources: [resource(1)]})
    canary = "METADATA_CALLBACK_PRIVATE_3d72"

    for {consumer, code} <- [
          {fn _, _ -> raise canary end, :storage_unavailable},
          {fn _, _ -> throw(canary) end, :storage_unavailable},
          {fn _, _ -> {:ok, :unchecked, canary} end, :invalid},
          {fn _, _ -> {:error, canary} end, :invalid},
          {fn _, _ -> :ok end, :invalid}
        ] do
      result = call(:reduce_metadata, [sealed, :resources, [], consumer])
      assert {:error, %Error{code: ^code, details: %{}, message: nil}} = result
      assert result == {:error, Error.new(code)}
      refute inspect(result) =~ canary
      assert {:ok, record} = call(:read_metadata, [sealed, :resources, uuid(1)])
      assert record == resource(1)
    end

    assert_metadata_cleanup(c, sealed)
  end

  test "consumer cancellation invalidates reduction completion and preserves neighboring captures",
       c do
    sealed = metadata_capture(c, %{resources: [resource(1)]})
    other = metadata_capture(c, %{resources: [resource(2)]})

    assert {:error, %Error{}} =
             call(:reduce_metadata, [
               sealed,
               :resources,
               0,
               fn _, acc ->
                 assert :ok = call(:abort, [sealed])
                 {:ok, acc + 1}
               end
             ])

    refute File.exists?(operation_dir(c.root, sealed))
    assert File.dir?(operation_dir(c.root, other))
    assert {:ok, record} = call(:read_metadata, [other, :resources, uuid(2)])
    assert record == resource(2)
    assert_metadata_cleanup(c, other)
  end

  test "last successful metadata consumer cannot hide expiry before final reduction return", c do
    now = :atomics.new(1, signed: true)
    :atomics.put(now, 1, 0)

    sealed =
      metadata_capture(c, %{resources: [resource(1)]}, %{clock: fn -> :atomics.get(now, 1) end})

    token = make_ref()

    result =
      call(:reduce_metadata, [
        sealed,
        :resources,
        0,
        fn _, acc ->
          send(self(), token)
          :atomics.put(now, 1, sealed._deadline)
          {:ok, acc + 1}
        end
      ])

    assert_receive ^token
    assert_metadata_native_denial(c, sealed, result)
  end

  test "empty reduction repeats native readability rather than accepting the entry deadline alone",
       c do
    state = :atomics.new(2, signed: true)

    clock = fn ->
      if :atomics.get(state, 1) == 0 or :atomics.add_get(state, 2, 1) == 1,
        do: 0,
        else: 900_000
    end

    sealed = metadata_capture(c, %{}, %{clock: clock})
    :atomics.put(state, 1, 1)
    token = make_ref()

    result =
      call(:reduce_metadata, [
        sealed,
        :resources,
        :initial,
        fn _, _ ->
          send(self(), token)
          {:ok, :unchecked}
        end
      ])

    refute_receive ^token, 0
    assert_metadata_native_denial(c, sealed, result)
  end

  test "last successful metadata consumer cannot hide native size drift before final return", c do
    sealed = metadata_capture(c, %{resources: [resource(1)]})

    result =
      call(:reduce_metadata, [
        sealed,
        :resources,
        0,
        fn _, acc ->
          path = Path.join(operation_dir(c.root, sealed), "payload")
          File.write!(path, File.read!(path) <> "DRIFT_AFTER_LAST_RECORD")
          {:ok, acc + 1}
        end
      ])

    assert_metadata_native_denial(c, sealed, result)
  end

  test "exact metadata preserves accepted pending Asset draft without inventing a digest", c do
    key = {:binary_binding, :asset, uuid(1), uuid(1_001)}
    draft = Map.put(asset_version(1, 12), "original_digest", nil)
    {:ok, spool} = call(:open, [c.context])
    {:ok, spool} = call(:append, [spool, key, asset_binding(1, 12)])
    {:ok, spool} = call(:append, [spool, {:metadata, :versions}, draft])
    {:ok, sealed} = call(:seal, [spool])
    on_exit(fn -> assert :ok = call(:abort, [sealed]) end)

    assert {:ok, %{records: [^draft]}} =
             call(:read_page, [sealed, cursor(sealed, :versions), 500])

    assert {:ok, ^draft} = call(:read_metadata, [sealed, :versions, {uuid(1), uuid(1_001)}])

    assert {:ok, [^draft]} =
             call(:reduce_metadata, [
               sealed,
               :versions,
               [],
               fn record, acc -> {:ok, [record | acc]} end
             ])

    assert {:error, %Error{code: :invalid}} =
             Singularity.Core.KnowledgeExportManifest.record(:versions, draft)

    assert_metadata_cleanup(c, sealed)
  end

  defp metadata_capture(c, records, overrides \\ %{}) do
    {:ok, spool} = call(:open, [Map.merge(c.context, overrides)])

    spool =
      Enum.reduce(@collections, spool, fn collection, current ->
        Enum.reduce(Map.get(records, collection, []), current, fn record, owned ->
          {:ok, next} = call(:append, [owned, {:metadata, collection}, record])
          next
        end)
      end)

    {:ok, sealed} = call(:seal, [spool])
    on_exit(fn -> assert :ok = call(:abort, [sealed]) end)
    sealed
  end

  defp metadata_read(:point, sealed, collection, key),
    do: call(:read_metadata, [sealed, collection, key])

  defp metadata_read(:reduce, sealed, collection, _key) do
    token = make_ref()

    result =
      call(:reduce_metadata, [
        sealed,
        collection,
        [],
        fn _, acc ->
          send(self(), token)
          {:ok, acc}
        end
      ])

    refute_receive ^token, 0
    result
  end

  defp assert_metadata_native_denial(c, sealed, result) do
    assert {:error, %Error{code: :integrity_failure, details: %{}, message: nil}} = result
    assert result == {:error, Error.new(:integrity_failure)}
    refute File.exists?(operation_dir(c.root, sealed))
    assert_metadata_cleanup(c, sealed)
  end

  defp assert_metadata_cleanup(c, sealed) do
    assert :ok = call(:abort, [sealed])
    refute File.exists?(operation_dir(c.root, sealed))
    assert File.ls!(c.root) == ["neighbor-sentinel"]
    assert File.read!(c.sentinel) == "neighbor"
  end

  defp metadata_records do
    locator = %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}

    %{
      resources: [resource(1)],
      versions: [asset_version(1, 12)],
      fragments: [
        %{
          "id" => sha("fragment identity"),
          "resource_id" => uuid(2),
          "version_id" => uuid(1_002),
          "ordinal" => 0,
          "digest" => sha("text"),
          "locator" => locator,
          "extracted_path" => nil,
          "start_byte" => nil,
          "byte_size" => nil
        }
      ],
      tags: [%{"id" => uuid(3), "display_value" => "Tag", "normalized_key" => "tag"}],
      tag_assignments: [%{"resource_id" => uuid(1), "tag_id" => uuid(3)}],
      relationships: [
        %{
          "id" => uuid(4),
          "source_resource_id" => uuid(1),
          "target_resource_id" => uuid(2),
          "target_version_id" => uuid(1_002),
          "type" => "references"
        }
      ],
      attachments: [
        %{
          "note_resource_id" => uuid(1),
          "note_version_id" => uuid(1_001),
          "id" => uuid(5),
          "ordinal" => 0,
          "target_resource_id" => uuid(2),
          "target_version_id" => uuid(1_002),
          "target_kind" => "document",
          "role" => "source",
          "label" => nil
        }
      ],
      citations: [
        %{
          "note_resource_id" => uuid(1),
          "note_version_id" => uuid(1_001),
          "id" => uuid(6),
          "ordinal" => 0,
          "source_resource_id" => uuid(2),
          "source_version_id" => uuid(1_002),
          "fragment_id" => sha("fragment identity"),
          "locator" => locator
        }
      ]
    }
  end

  defp metadata_key(collection, record) when collection in [:resources, :tags, :relationships],
    do: record["id"]

  defp metadata_key(:versions, record), do: {record["resource_id"], record["version_id"]}

  defp metadata_key(:fragments, record),
    do: {record["resource_id"], record["version_id"], record["ordinal"], record["id"]}

  defp metadata_key(:tag_assignments, record), do: {record["resource_id"], record["tag_id"]}

  defp metadata_key(collection, record) when collection in [:attachments, :citations],
    do: {record["note_resource_id"], record["note_version_id"], record["ordinal"], record["id"]}

  # END sealed-record-iteration test-only additions

  defp call(function, args) do
    assert Code.ensure_loaded?(@spool), "missing concrete capture Spool"
    assert function_exported?(@spool, function, length(args))
    apply(@spool, function, args)
  end

  defp trusted_context(tmp_dir, root) do
    storage = Path.join(tmp_dir, "ciphertext")
    backup = Path.join(tmp_dir, "backup")

    for path <- [storage, backup] do
      File.mkdir!(path)
      File.chmod!(path, 0o700)
    end

    %{root: Path.expand(root), storage_root: storage, backup_root: backup}
  end

  defp cursor(descriptor, collection),
    do: %{capture_id: descriptor.capture_id, collection: collection, after: nil}

  defp pages(sealed, cursor, records, pages) do
    {:ok, %{records: page, next_cursor: next}} = call(:read_page, [sealed, cursor, 500])
    assert length(page) <= 500

    if is_nil(next),
      do: {records ++ page, pages ++ [page]},
      else: pages(sealed, next, records ++ page, pages ++ [page])
  end

  defp append_chunks(spool, selector, <<>>), do: elem(call(:append, [spool, selector, ""]), 1)

  defp append_chunks(spool, selector, bytes) do
    size = min(byte_size(bytes), 65_536)
    <<chunk::binary-size(size), rest::binary>> = bytes
    {:ok, next} = call(:append, [spool, selector, chunk])
    if rest == "", do: next, else: append_chunks(next, selector, rest)
  end

  defp read_text(sealed, ref) do
    count = max(1, div(ref.byte_size + 65_535, 65_536))

    Enum.map_join(0..(count - 1), "", fn index ->
      {:ok, chunk} = call(:read_chunk, [sealed, ref, index])
      assert byte_size(chunk) <= 65_536
      chunk
    end)
  end

  defp resource(number, title \\ "title"),
    do: %{
      "id" => uuid(number),
      "kind" => "note",
      "title" => title,
      "current_version_id" => uuid(number + 1_000),
      "deleted_at" => nil,
      "selection_reason" => "head"
    }

  defp asset_version(number, size) do
    resource = uuid(number)
    version = uuid(number + 1_000)

    ~w(resource_id version_id revision kind inserted_at availability body_path original_path extracted_path body_digest original_digest original_byte_size extracted_digest media_type state extraction_adapter extraction_format parent_version_id merge_parent_version_id)
    |> Map.new(&{&1, nil})
    |> Map.merge(%{
      "resource_id" => resource,
      "version_id" => version,
      "revision" => 0,
      "kind" => "asset",
      "inserted_at" => @time,
      "availability" => "included",
      "original_path" => "assets/#{resource}--#{version}.bin",
      "original_digest" => sha("original"),
      "original_byte_size" => size,
      "media_type" => "application/octet-stream"
    })
  end

  defp asset_binding(number, size),
    do: %{
      "kind" => "asset",
      "resource_id" => uuid(number),
      "version_id" => uuid(number + 1_000),
      "asset_id" => uuid(number + 2_000),
      "object_id" => uuid(number + 3_000),
      "owner_scope_id" => uuid(4_000),
      "classification" => "private",
      "key_domain_id" => uuid(5_000),
      "domain_key_version_id" => uuid(6_000),
      "domain_key_generation" => 1,
      "object_generation" => 1,
      "lookup_digest" => sha("keyed lookup"),
      "ciphertext_hash" => sha("ciphertext"),
      "plaintext_byte_size" => size,
      "ciphertext_byte_size" => size + 88,
      "storage_ref" =>
        "objects/#{uuid(4_000)}/#{uuid(5_000)}/hmac-sha256/#{binary_part(sha("keyed lookup"), 0, 2)}/#{sha("keyed lookup")}",
      "format_version" => 1,
      "plaintext_sha256" => nil
    }

  defp operation_dir(root, spool), do: Path.join(root, spool.capture_id)
  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp uuid(n),
    do:
      "00000000-0000-4000-8000-" <>
        String.pad_leading(String.downcase(Integer.to_string(n, 16)), 12, "0")

  defp assert_error(result), do: assert(match?({:error, %Error{}}, result))
  defp assert_mode(path, mode), do: assert(Bitwise.band(File.stat!(path).mode, 0o777) == mode)
  defp tree(path), do: Path.wildcard(Path.join(path, "**/*"), match_dot: true)

  defp assert_private_tree(path) do
    for child <- tree(path) do
      case File.lstat!(child).type do
        :directory -> assert_mode(child, 0o700)
        :regular -> assert_mode(child, 0o600)
      end
    end
  end

  defp disk_bytes(path),
    do:
      Enum.reduce(tree(path), 0, fn child, acc ->
        case File.lstat!(child) do
          %{type: :regular, size: size} -> acc + size
          _ -> acc
        end
      end)

  defp payload_file(path, canary),
    do:
      Enum.find(tree(path), fn child ->
        File.regular?(child) and :binary.match(File.read!(child), canary) != :nomatch
      end) || flunk("canonical payload was not retained in the operation spool")
end
