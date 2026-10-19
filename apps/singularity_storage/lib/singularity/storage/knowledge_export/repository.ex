defmodule Singularity.Storage.KnowledgeExport.Repository do
  @moduledoc "Internal authenticated, bounded portable snapshot capture."

  alias Singularity.Core.{DocumentFragment, Error, KnowledgeExport, SourceLocator, Types}
  alias Singularity.Storage.SafeSQL
  alias Singularity.Storage.KnowledgeExport.Spool
  alias Singularity.Storage.Postgres.{KnowledgeError, KnowledgeLinkRepository}

  @collections ~w(resources versions fragments tags tag_assignments relationships attachments citations)a
  @version_fields ~w(resource_id version_id revision kind inserted_at availability body_path original_path extracted_path body_digest original_digest original_byte_size extracted_digest media_type state extraction_adapter extraction_format parent_version_id merge_parent_version_id)
  @reason_rank %{"head" => 0, "source" => 1, "tombstone" => 2, "relationship_endpoint" => 3}

  def capture(repo, authorize_snapshot, options, spool) do
    result =
      try do
        unless is_atom(repo) and not is_nil(repo) and is_function(authorize_snapshot, 1) and
                 repo.in_transaction?(),
               do: fail(:invalid)

        options = unwrap(KnowledgeExport.options(options))
        session = unwrap(authorize_snapshot.(repo))
        {principal, owner} = authority!(repo, session)

        state = %{
          repo: repo,
          authorize: authorize_snapshot,
          principal: principal,
          owner: owner,
          spool: spool,
          resources: %{},
          versions: %{},
          keys: MapSet.new(),
          anchors: MapSet.new(),
          frontier: :gb_sets.empty(),
          fragments: MapSet.new(),
          relationships: MapSet.new(),
          tags: MapSet.new(),
          assignments: MapSet.new()
        }

        state = heads(state, nil)
        state = if options.include_tombstones, do: tombstones(state, nil), else: state
        state = traverse(state)
        # Freeze the body/source endpoint set before discovering organization
        # metadata. An endpoint never recursively selects its other edges.
        anchors = state.anchors |> MapSet.to_list() |> Enum.sort()
        state = organization(state, anchors)
        state = project_metadata(state)
        session = unwrap(state.authorize.(repo))
        unless authority!(repo, session) == {principal, owner}, do: fail(:invalid)
        sealed = unwrap(Spool.seal(state.spool))
        {:ok, sealed}
      rescue
        exception -> {:error, KnowledgeError.from(exception)}
      catch
        :throw, {__MODULE__, %Error{} = error} -> {:error, error}
        _kind, _reason -> {:error, Error.new(:storage_unavailable, retryable?: true)}
      end

    case result do
      {:error, %Error{}} -> abort(spool)
      _ -> :ok
    end

    result
  end

  # Spool validates the exact capture/channel-bound cursor and authentication
  # tag. This path deliberately has no repository or live SQL dependency.
  def next_page(sealed, %{collection: collection} = cursor, limit)
      when collection in @collections,
      do: Spool.read_page(sealed, cursor, limit)

  def next_page(_sealed, _cursor, _limit), do: {:error, Error.new(:invalid)}

  # These reads run only inside the authenticated request scope. The owner is
  # taken from its PostgreSQL context, never from a captured descriptor.
  def lock_asset_source(repo, binding, mode) do
    export_read(fn ->
      owner = export_owner!(repo)
      unless binding["owner_scope_id"] == owner, do: fail(:integrity_failure)

      case mode do
        :zero ->
          unless binding["plaintext_byte_size"] == 0 and binding["format_version"] == 1 and
                   binding["ciphertext_byte_size"] == 134,
                 do: fail(:integrity_failure)

        %Range{first: first, last: last, step: 1}
        when first >= 0 and last >= first and last - first < 65_536 ->
          unless last < binding["plaintext_byte_size"], do: fail(:integrity_failure)

        _ ->
          fail(:invalid)
      end

      export_original!(repo, owner, binding, false)
      :ok
    end)
  end

  def document_source(repo, %{version: version, source: source}) do
    export_read(fn ->
      owner = export_owner!(repo)
      resource = canonical_id(version["resource_id"])
      id = canonical_id(version["version_id"])
      export_live_version!(repo, owner, resource, id, "document")

      [source_resource, source_version, asset, object, digest, size] =
        one(
          export_query(
            repo,
            """
            SELECT source_resource_id,source_resource_version_id,source_asset_id,source_object_id,
                   source_digest,source_byte_size
            FROM content.document_versions
            WHERE resource_id=$1 AND resource_version_id=$2 AND vault_id=$3 AND classification='private'
            LIMIT 2
            """,
            [dump(resource), dump(id), dump(owner)]
          )
        )

      unless version["kind"] == "document" and hex(digest) == version["original_digest"] and
               size == version["original_byte_size"] and is_integer(size) and
               size in 0..67_108_864 and source["owner_scope_id"] == owner and
               source["resource_id"] == text(source_resource) and
               source["version_id"] == text(source_version) and source["asset_id"] == text(asset) and
               source["object_id"] == text(object) and source["plaintext_byte_size"] == size,
             do: fail(:integrity_failure)

      export_original!(repo, owner, source, true)

      {:ok,
       %{
         resource_id: resource,
         resource_version_id: id,
         object_id: text(object),
         object_generation: source["object_generation"],
         source_digest: digest,
         source_byte_size: size
       }}
    end)
  end

  def document_source(_repo, _binding), do: {:error, Error.new(:invalid)}

  def document_source_selector(repo, version) when is_map(version) and not is_struct(version) do
    export_read(fn ->
      owner = export_owner!(repo)
      resource = canonical_id(version["resource_id"])
      id = canonical_id(version["version_id"])
      export_live_version!(repo, owner, resource, id, "document")

      [source_resource, source_version, digest, size] =
        one(
          export_query(
            repo,
            """
            SELECT source_resource_id,source_resource_version_id,source_digest,source_byte_size
            FROM content.document_versions
            WHERE resource_id=$1 AND resource_version_id=$2 AND vault_id=$3
              AND classification='private'
            LIMIT 2
            """,
            [dump(resource), dump(id), dump(owner)]
          )
        )

      unless version["kind"] == "document" and version["availability"] == "included" and
               hex(digest) == version["original_digest"] and
               size == version["original_byte_size"] and is_integer(size) and
               size in 0..67_108_864,
             do: fail(:integrity_failure)

      {:ok,
       {:binary_binding, :asset, canonical_id(text(source_resource)),
        canonical_id(text(source_version))}}
    end)
  end

  def document_source_selector(_repo, _version), do: {:error, Error.new(:invalid)}

  def revalidate_note(repo, %{version: version}) do
    export_read(fn ->
      owner = export_owner!(repo)
      resource = canonical_id(version["resource_id"])
      id = canonical_id(version["version_id"])
      export_live_version!(repo, owner, resource, id, "note")

      [body] =
        one(
          export_query(
            repo,
            """
            SELECT markdown FROM content.note_versions
            WHERE resource_id=$1 AND resource_version_id=$2 AND vault_id=$3 AND classification='private'
              AND octet_length(markdown)<=1048576 LIMIT 2
            """,
            [dump(resource), dump(id), dump(owner)]
          )
        )

      unless version["kind"] == "note" and
               hex(:crypto.hash(:sha256, body)) == version["body_digest"],
             do: fail(:integrity_failure)

      :ok
    end)
  end

  def revalidate_note(_repo, _binding), do: {:error, Error.new(:invalid)}

  def revalidate_fragment(repo, %{fragment: fragment}) do
    export_read(fn ->
      owner = export_owner!(repo)
      resource = canonical_id(fragment["resource_id"])
      version = canonical_id(fragment["version_id"])
      export_live_version!(repo, owner, resource, version, "document")

      [id, ordinal, digest, locator, body] =
        one(
          export_query(
            repo,
            """
            SELECT id,ordinal,digest,locator,text FROM content.document_fragments
            WHERE resource_id=$1 AND resource_version_id=$2 AND vault_id=$3 AND classification='private'
              AND id=$4 AND octet_length(text)<=65536 LIMIT 2
            """,
            [dump(resource), dump(version), dump(owner), fragment["id"]]
          )
        )

      unless id == fragment["id"] and ordinal == fragment["ordinal"] and
               hex(digest) == fragment["digest"] and locator == fragment["locator"] and
               byte_size(body) == fragment["byte_size"] and :crypto.hash(:sha256, body) == digest and
               DocumentFragment.id(version, locator, ordinal, digest) == id,
             do: fail(:integrity_failure)

      :ok
    end)
  end

  def revalidate_fragment(_repo, _binding), do: {:error, Error.new(:invalid)}

  defp export_read(callback) do
    callback.()
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  catch
    :throw, {__MODULE__, %Error{} = error} -> {:error, error}
    _, _ -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  defp export_owner!(repo) do
    unless is_atom(repo) and not is_nil(repo) and repo.in_transaction?(), do: fail(:invalid)

    case export_query(
           repo,
           """
           SELECT current_setting('singularity.principal_id',true),
                  current_setting('singularity.vault_id',true)
           """,
           []
         ) do
      [[principal, owner]] ->
        canonical_id(principal)
        canonical_id(owner)

      _ ->
        fail(:invalid)
    end
  end

  defp export_query(repo, sql, params), do: SafeSQL.query!(repo, sql, params).rows

  defp export_live_version!(repo, owner, resource, version, kind) do
    case export_query(
           repo,
           """
           SELECT r.kind FROM content.resources r
           JOIN content.resource_versions v ON
             (v.resource_id,v.vault_id,v.classification)=(r.id,r.vault_id,r.classification)
           WHERE r.id=$1 AND v.id=$2 AND r.vault_id=$3 AND r.classification='private'
             AND r.deleted_at IS NULL LIMIT 2
           """,
           [dump(resource), dump(version), dump(owner)]
         ) do
      [[^kind]] -> :ok
      [] -> fail(:not_found)
      _ -> fail(:integrity_failure)
    end
  end

  defp export_original!(repo, owner, binding, retained?) do
    asset = canonical_id(binding["asset_id"])
    object = canonical_id(binding["object_id"])

    # Asset first is the established destructive-mutation lock order. Object,
    # envelope and domain-version locks then cover custody material loading.
    one(
      export_query(
        repo,
        "SELECT id FROM content.assets WHERE id=$1 AND vault_id=$2 AND classification='private' FOR SHARE",
        [dump(asset), dump(owner)]
      )
    )

    one(
      export_query(
        repo,
        "SELECT id FROM content.asset_objects WHERE id=$1 AND vault_id=$2 AND classification='private' FOR SHARE",
        [dump(object), dump(owner)]
      )
    )

    one(
      export_query(
        repo,
        """
        SELECT e.id FROM content.asset_key_envelopes e
        JOIN core.domain_key_versions d ON
          (d.id,d.vault_id,d.key_domain_id)=(e.domain_key_version_id,e.vault_id,e.key_domain_id)
        WHERE e.asset_object_id=$1 AND e.vault_id=$2 AND e.classification='private' AND d.state='active'
        LIMIT 2 FOR SHARE OF e,d
        """,
        [dump(object), dump(owner)]
      )
    )

    [
      actual_asset,
      actual_object,
      domain,
      domain_version,
      domain_generation,
      generation,
      lookup,
      ciphertext,
      size,
      cipher_size,
      storage,
      format,
      state,
      lifecycle,
      deleted,
      released,
      tombstoned,
      metadata_size,
      candidates
    ] =
      one(
        export_query(
          repo,
          """
          SELECT a.id,o.id,o.key_domain_id,e.domain_key_version_id,d.generation,e.key_generation,
                 o.lookup_digest,o.ciphertext_hash,o.plaintext_byte_size,o.ciphertext_byte_size,
                 o.storage_ref,o.format_version,a.state,o.lifecycle,r.deleted_at,ra.released_at,
                 EXISTS(SELECT 1 FROM content.tombstones t WHERE
                   (t.asset_id,t.vault_id,t.classification)=(a.id,a.vault_id,a.classification)),
                 m.plaintext_byte_size,
                 (SELECT count(*) FROM (
                   SELECT id FROM content.assets WHERE resource_version_id=$2 AND vault_id=$3
                   UNION SELECT asset_id FROM content.asset_metadata WHERE resource_version_id=$2 AND vault_id=$3
                   UNION SELECT asset_id FROM content.resource_assets WHERE resource_version_id=$2 AND vault_id=$3
                 ) candidates)
          FROM content.assets a
          JOIN content.resource_versions v ON (v.id,v.vault_id,v.classification)=(a.resource_version_id,a.vault_id,a.classification)
          JOIN content.resources r ON (r.id,r.vault_id,r.classification)=(v.resource_id,v.vault_id,v.classification)
          JOIN content.resource_assets ra ON (ra.asset_id,ra.resource_version_id,ra.vault_id,ra.classification)=(a.id,v.id,a.vault_id,a.classification)
          JOIN content.asset_metadata m ON (m.asset_id,m.resource_version_id,m.vault_id,m.classification)=(a.id,v.id,a.vault_id,a.classification)
          JOIN content.asset_objects o ON (o.id,o.vault_id,o.classification)=(CASE WHEN $4 THEN $5::uuid ELSE a.asset_object_id END,a.vault_id,a.classification)
          JOIN content.asset_key_envelopes e ON (e.asset_object_id,e.vault_id,e.key_domain_id,e.classification)=(o.id,o.vault_id,o.key_domain_id,o.classification)
          JOIN core.domain_key_versions d ON (d.id,d.vault_id,d.key_domain_id)=(e.domain_key_version_id,e.vault_id,e.key_domain_id)
          JOIN core.key_domains k ON (k.id,k.vault_id)=(o.key_domain_id,o.vault_id)
          WHERE r.id=$1 AND v.id=$2 AND a.vault_id=$3 AND a.classification='private'
            AND r.kind='asset' AND d.state='active' AND k.state='active' AND k.kind='content'
            AND k.classification='private' LIMIT 2
          """,
          [
            dump(binding["resource_id"]),
            dump(binding["version_id"]),
            dump(owner),
            retained?,
            dump(object)
          ]
        )
      )

    actual = %{
      "kind" => "asset",
      "resource_id" => binding["resource_id"],
      "version_id" => binding["version_id"],
      "asset_id" => text(actual_asset),
      "object_id" => text(actual_object),
      "owner_scope_id" => owner,
      "classification" => "private",
      "key_domain_id" => text(domain),
      "domain_key_version_id" => text(domain_version),
      "domain_key_generation" => domain_generation,
      "object_generation" => generation,
      "lookup_digest" => hex(lookup),
      "ciphertext_hash" => hex(ciphertext),
      "plaintext_byte_size" => size,
      "ciphertext_byte_size" => cipher_size,
      "storage_ref" => storage,
      "format_version" => format,
      "plaintext_sha256" => nil
    }

    unless actual == binding and candidates == 1 and size == metadata_size and
             lifecycle == "available" and
             format == 1 and
             (retained? or
                (is_nil(deleted) and is_nil(released) and
                   not tombstoned and state in ["available", "processing", "ready"])),
           do: fail(:integrity_failure)

    :ok
  end

  defp authority!(repo, %{principal_id: principal, vault_id: owner}) do
    principal = canonical_id(principal)
    owner = canonical_id(owner)
    unless repo.in_transaction?(), do: fail(:invalid)

    case SafeSQL.query!(
           repo,
           """
           SELECT current_setting('transaction_isolation'),
                  current_setting('transaction_read_only'),
                  current_setting('singularity.principal_id',true),
                  current_setting('singularity.vault_id',true)
           """,
           []
         ).rows do
      [["repeatable read", "off", ^principal, ^owner]] -> {principal, owner}
      _ -> fail(:invalid)
    end
  end

  defp authority!(_repo, _session), do: fail(:invalid)

  defp heads(state, after_id) do
    rows =
      query(
        state,
        """
        SELECT id,current_version_id,kind
        FROM content.resources
        WHERE vault_id=$1 AND classification='private' AND deleted_at IS NULL
          AND kind IN ('note','document') AND ($2::uuid IS NULL OR id>$2)
        ORDER BY id LIMIT 500
        """,
        [dump(state.owner), optional_dump(after_id)]
      )

    state =
      Enum.reduce(rows, state, fn [resource, version, kind], current ->
        unless not is_nil(version), do: fail(:integrity_failure)
        select(current, text(resource), text(version), kind, "head", true)
      end)

    case List.last(rows) do
      [id, _, _] when length(rows) == 500 -> heads(state, text(id))
      _ -> state
    end
  end

  defp tombstones(state, after_id) do
    rows =
      query(
        state,
        """
        SELECT id,current_version_id,kind
        FROM content.resources
        WHERE vault_id=$1 AND classification='private' AND deleted_at IS NOT NULL
          AND ($2::uuid IS NULL OR id>$2)
        ORDER BY id LIMIT 500
        """,
        [dump(state.owner), optional_dump(after_id)]
      )

    state =
      Enum.reduce(rows, state, fn [resource, version, kind], current ->
        resource = text(resource)
        {current, _} = discover_resource(current, resource, "tombstone")

        if is_nil(version) do
          current
        else
          version = text(version)
          current = select(current, resource, version, kind, "tombstone", false)

          if kind == "note",
            do: expand_note(current, {kind, resource, version}, false),
            else: current
        end
      end)

    case List.last(rows) do
      [id, _, _] when length(rows) == 500 -> tombstones(state, text(id))
      _ -> state
    end
  end

  defp select(state, resource, version, kind, reason, demand?) do
    {state, row} = discover_resource(state, resource, reason)
    unless row.kind == kind, do: fail(:integrity_failure)
    key = {kind, resource, version}
    state = discover_version(state, row, version)
    entry = Map.fetch!(state.versions, key)

    if demand? and not entry.deleted? and not entry.demand? do
      state = charge(state, 2)

      %{
        state
        | versions: Map.put(state.versions, key, %{entry | demand?: true}),
          frontier: :gb_sets.add(key, state.frontier)
      }
    else
      state
    end
  end

  defp discover_resource(state, id, reason) do
    row = resource_row(state, id)
    previous = Map.get(state.resources, id)

    chosen =
      if is_nil(previous) or @reason_rank[reason] < @reason_rank[previous],
        do: reason,
        else: previous

    state = if previous == chosen, do: state, else: charge(state, 1)
    state = %{state | resources: Map.put(state.resources, id, chosen)}

    state =
      if is_nil(previous) and is_nil(row.current_version_id),
        do: remember_key(state, {row.kind, id, nil}),
        else: state

    state =
      if reason != "relationship_endpoint" and not MapSet.member?(state.anchors, id) do
        current = charge(state, 1)
        %{current | anchors: MapSet.put(current.anchors, id)}
      else
        state
      end

    # Every declared current head has a descriptor, but discovering it is not
    # body authority. Body demand below is an independent promotion index.
    state =
      if is_nil(previous) and not is_nil(row.current_version_id),
        do: discover_version(state, row, row.current_version_id),
        else: state

    {state, row}
  end

  defp discover_version(state, resource, version) do
    key = {resource.kind, resource.id, version}

    if Map.has_key?(state.versions, key) do
      state
    else
      unless map_size(state.versions) < KnowledgeExport.limits().selected_keys,
        do: fail(:invalid)

      metadata = version_row(state, resource, version)
      state = remember_key(state, key)
      state = charge(state, 1)

      entry = %{
        demand?: false,
        traversed?: false,
        membership?: false,
        deleted?: metadata.deleted?,
        projected?: false
      }

      state = %{state | versions: Map.put(state.versions, key, entry)}

      Enum.reduce([metadata.parent_version_id, metadata.merge_parent_version_id], state, fn
        nil, current -> current
        parent, current -> discover_version(current, resource, parent)
      end)
    end
  end

  defp traverse(state) do
    if :gb_sets.is_empty(state.frontier) do
      state
    else
      {key, frontier} = :gb_sets.take_smallest(state.frontier)
      entry = Map.fetch!(state.versions, key)
      state = charge(state, 1)
      # Mark traversal before expanding source membership, including cycles.
      state = %{
        state
        | frontier: frontier,
          versions: Map.put(state.versions, key, %{entry | traversed?: true})
      }

      state = capture_body(state, key)
      traverse(state)
    end
  end

  defp capture_body(state, {"note", resource, version} = key) do
    row = resource_row(state, resource)
    metadata = version_row(state, row, version)

    markdown =
      case query(
             state,
             """
             SELECT markdown FROM content.note_versions
             WHERE resource_id=$1 AND resource_version_id=$2 AND vault_id=$3
               AND classification='private' AND octet_length(markdown)<=1048576
             LIMIT 1
             """,
             [dump(resource), dump(version), dump(state.owner)]
           ) do
        [[body]] when is_binary(body) -> body
        _ -> fail(:integrity_failure)
      end

    unless String.valid?(markdown) and not String.contains?(markdown, <<0>>),
      do: fail(:integrity_failure)

    # The one bounded SQL body is consumed now. No corpus payload enters an
    # index, and the canonical SHA is not confused with the rendered file SHA.
    state = temporary_text(state, byte_size(markdown))
    state = append_chunks(state, {:note_markdown, resource, version}, markdown)

    record =
      metadata.record
      |> Map.merge(%{
        "availability" => "included",
        "body_path" => path(:note, resource, version),
        "body_digest" => hex(:crypto.hash(:sha256, markdown))
      })

    state = append(state, {:metadata, :versions}, record)
    state = projected(state, key)
    expand_note(state, key, true)
  end

  defp capture_body(state, {"asset", resource, version} = key) do
    row = resource_row(state, resource)
    metadata = version_row(state, row, version)
    binding = original_binding(state, resource, version, nil)
    state = append(state, {:binary_binding, :asset, resource, version}, binding)

    record =
      metadata.record
      |> Map.merge(%{
        "availability" => "included",
        "original_path" => path(:asset, resource, version),
        "original_digest" => nil,
        "original_byte_size" => binding["plaintext_byte_size"]
      })

    state |> append({:metadata, :versions}, record) |> projected(key)
  end

  defp capture_body(state, {"document", resource, version} = key) do
    row = resource_row(state, resource)
    metadata = version_row(state, row, version)
    source = metadata.source
    binding = original_binding(state, source.resource_id, source.version_id, source.object_id)

    unless binding["asset_id"] == source.asset_id and binding["object_id"] == source.object_id and
             binding["plaintext_byte_size"] == metadata.record["original_byte_size"],
           do: fail(:integrity_failure)

    selector = {:binary_binding, :asset, source.resource_id, source.version_id}
    state = remember_key(state, {"asset", source.resource_id, source.version_id})
    state = append(state, selector, binding)

    # The exact source Asset binding is a sealed, physically journaled private
    # ref. The Document record binds its immutable version/digest/size. No
    # unchecked post-seal Document mapping is added to the descriptor.
    record =
      metadata.record
      |> Map.merge(%{
        "availability" => "included",
        "original_path" => path(:document, resource, version, metadata.record["media_type"]),
        "extracted_path" =>
          if(metadata.record["state"] == "ready",
            do: path(:extracted, resource, version),
            else: nil
          )
      })

    # Reserve the known original size before reading any extracted text.
    state = state |> append({:metadata, :versions}, record) |> projected(key)
    if record["state"] == "ready", do: document_text(state, key, record), else: state
  end

  defp document_text(state, {"document", resource, version}, record) do
    [count, total] =
      one(
        query(
          state,
          """
          SELECT count(*),coalesce(sum(octet_length(text)),0)
          FROM content.document_fragments
          WHERE resource_id=$1 AND resource_version_id=$2 AND vault_id=$3 AND classification='private'
          """,
          [dump(resource), dump(version), dump(state.owner)]
        )
      )

    limits = KnowledgeExport.limits()

    unless is_integer(count) and count in 1..limits.document_fragments and
             is_integer(total) and total in 1..limits.extracted_bytes,
           do: fail(:integrity_failure)

    {state, hash, offset} =
      Enum.reduce(0..(count - 1), {state, :crypto.hash_init(:sha256), 0}, fn ordinal,
                                                                             {current, hash,
                                                                              offset} ->
        [id, body, digest, locator] =
          one(
            query(
              current,
              """
              SELECT id,text,digest,locator FROM content.document_fragments
              WHERE resource_id=$1 AND resource_version_id=$2 AND vault_id=$3
                AND classification='private' AND ordinal=$4 AND octet_length(text)<=65536
              LIMIT 1
              """,
              [dump(resource), dump(version), dump(current.owner), ordinal]
            )
          )

        fragment =
          unwrap_integrity(
            DocumentFragment.new(%{
              resource_id: resource,
              resource_version_id: version,
              owner_scope_id: current.owner,
              classification: :private,
              ordinal: ordinal,
              text: body,
              digest: digest,
              locator: locator,
              fragment_id: id
            })
          )

        current = temporary_text(current, byte_size(body))
        current = append(current, {:fragment_text, resource, version, ordinal, id}, body)

        descriptor =
          fragment_record(
            resource,
            version,
            fragment.fragment_id,
            ordinal,
            hex(fragment.digest),
            SourceLocator.to_map(fragment.locator),
            record["extracted_path"],
            offset,
            byte_size(body)
          )

        current = append(current, {:metadata, :fragments}, descriptor)
        {current, :crypto.hash_update(hash, body), offset + byte_size(body)}
      end)

    unless offset == total and hex(:crypto.hash_final(hash)) == record["extracted_digest"],
      do: fail(:integrity_failure)

    state
  end

  defp expand_note(state, {"note", resource, version} = key, body?) do
    entry = Map.fetch!(state.versions, key)

    if entry.membership? do
      state
    else
      membership =
        unwrap_integrity(
          KnowledgeLinkRepository.read_membership(
            link_context(state),
            resource,
            version
          )
        )

      targets =
        Enum.map(membership.attachments, &{&1.target_resource_id, &1.target_resource_version_id}) ++
          Enum.map(membership.citations, &{&1.source_resource_id, &1.source_resource_version_id})

      unless MapSet.size(MapSet.new(targets)) <= KnowledgeExport.limits().source_targets,
        do: fail(:integrity_failure)

      state = charge(state, 1)
      state = %{state | versions: Map.put(state.versions, key, %{entry | membership?: true})}

      {state, attachments} =
        membership.attachments
        |> Enum.with_index()
        |> Enum.map_reduce(state, fn {reference, ordinal}, current ->
          resolved =
            unwrap_integrity(
              KnowledgeLinkRepository.resolve_attachment_in_scope(
                link_context(current),
                reference
              )
            )

          source = resolved.source

          current =
            select(
              current,
              source.resource_id,
              source.resource_version_id,
              Atom.to_string(source.kind),
              "source",
              body? and not source.deleted?
            )

          current =
            append(
              current,
              {:metadata, :attachments},
              attachment_record(resource, version, reference, ordinal)
            )

          {%{reference: reference, source: source, href: href(source)}, current}
        end)
        |> reverse_reduce()

      {state, citations} =
        membership.citations
        |> Enum.with_index()
        |> Enum.map_reduce(state, fn {reference, ordinal}, current ->
          {current, source} = citation_source(current, reference, body?)

          current =
            select(
              current,
              source.resource_id,
              source.resource_version_id,
              "document",
              "source",
              body? and not source.deleted?
            )

          current = cited_fragment(current, reference, source.deleted? or not body?)

          current =
            append(
              current,
              {:metadata, :citations},
              citation_record(resource, version, reference, ordinal)
            )

          {%{reference: reference, source: source, href: href(source)}, current}
        end)
        |> reverse_reduce()

      if body? do
        append(state, {:render_descriptions, resource, version}, %{
          attachments: attachments,
          citations: citations
        })
      else
        state
      end
    end
  end

  defp citation_source(state, reference, body?) do
    resource = resource_row(state, reference.source_resource_id)
    metadata = version_row(state, resource, reference.source_resource_version_id)

    unless resource.kind == "document" and metadata.record["state"] == "ready",
      do: fail(:integrity_failure)

    # Unlike the eager citation resolver, this fixed projection never reads a
    # deleted fragment's hidden plaintext. The exact typed/version/owner joins
    # and canonical selected-fragment witness are the same metadata contract.
    source = %{
      kind: :document,
      resource_id: resource.id,
      resource_version_id: reference.source_resource_version_id,
      title: metadata.title,
      deleted?: metadata.deleted?
    }

    if body? and not source.deleted? do
      resolved =
        unwrap_integrity(
          KnowledgeLinkRepository.resolve_citation_in_scope(
            link_context(state),
            reference
          )
        )

      unless resolved.source == source, do: fail(:integrity_failure)
      # The established live resolver reads one bounded fragment. Its temporary
      # plaintext copy also consumes the fixed capture byte budget.
      {temporary_text(state, byte_size(resolved.fragment.text)), resolved.source}
    else
      {state, source}
    end
  end

  defp cited_fragment(state, reference, metadata_only?) do
    resource = reference.source_resource_id
    version = reference.source_resource_version_id

    [ordinal, digest, locator] =
      one(
        query(
          state,
          """
          SELECT ordinal,digest,locator FROM content.document_fragments
          WHERE resource_id=$1 AND resource_version_id=$2 AND vault_id=$3
            AND classification='private' AND id=$4 LIMIT 1
          """,
          [dump(resource), dump(version), dump(state.owner), reference.fragment_id]
        )
      )

    locator = unwrap_integrity(SourceLocator.new(locator))

    unless locator == reference.locator and is_integer(ordinal) and ordinal in 0..4095 and
             DocumentFragment.id(version, locator, ordinal, digest) == reference.fragment_id,
           do: fail(:integrity_failure)

    key = {resource, version, reference.fragment_id}

    if metadata_only? and not MapSet.member?(state.fragments, key) do
      state = charge(state, 1)
      state = %{state | fragments: MapSet.put(state.fragments, key)}

      append(
        state,
        {:metadata, :fragments},
        fragment_record(
          resource,
          version,
          reference.fragment_id,
          ordinal,
          hex(digest),
          SourceLocator.to_map(locator),
          nil,
          nil,
          nil
        )
      )
    else
      state
    end
  end

  defp organization(state, anchors) do
    state =
      Enum.reduce(Enum.chunk_every(anchors, 500), state, fn ids, current ->
        edges(current, ids, nil)
      end)

    state.resources
    |> Map.keys()
    |> Enum.sort()
    |> Enum.chunk_every(500)
    |> Enum.reduce(state, fn ids, current -> tag_assignments(current, ids, nil) end)
  end

  defp edges(state, ids, after_id) do
    rows =
      query(
        state,
        """
        SELECT id,source_resource_id,target_resource_id,target_resource_version_id,type
        FROM content.relationships
        WHERE vault_id=$1 AND classification='private'
          AND (source_resource_id=ANY($2::uuid[]) OR target_resource_id=ANY($2::uuid[]))
          AND ($3::uuid IS NULL OR id>$3) ORDER BY id LIMIT 500
        """,
        [dump(state.owner), Enum.map(ids, &dump/1), optional_dump(after_id)]
      )

    state =
      Enum.reduce(rows, state, fn [id, source, target, pin, type], current ->
        id = text(id)

        if MapSet.member?(current.relationships, id) do
          current
        else
          current = charge(current, 1)
          current = %{current | relationships: MapSet.put(current.relationships, id)}
          {current, _} = discover_resource(current, text(source), "relationship_endpoint")

          {current, target_row} =
            discover_resource(current, text(target), "relationship_endpoint")

          current =
            if is_nil(pin),
              do: current,
              else: discover_version(current, target_row, text(pin))

          append(current, {:metadata, :relationships}, %{
            "id" => id,
            "source_resource_id" => text(source),
            "target_resource_id" => text(target),
            "target_version_id" => text(pin),
            "type" => type
          })
        end
      end)

    case List.last(rows) do
      [id | _] when length(rows) == 500 -> edges(state, ids, text(id))
      _ -> state
    end
  end

  defp tag_assignments(state, ids, after_key) do
    {after_resource, after_tag} = after_key || {nil, nil}

    rows =
      query(
        state,
        """
        SELECT a.resource_id,t.id,t.display_value,t.normalized_key
        FROM content.resource_tags a JOIN content.tags t
          ON (t.id,t.vault_id,t.classification)=(a.tag_id,a.vault_id,a.classification)
        WHERE a.vault_id=$1 AND a.classification='private' AND a.resource_id=ANY($2::uuid[])
          AND ($3::uuid IS NULL OR (a.resource_id,t.id)>($3,$4))
        ORDER BY a.resource_id,t.id LIMIT 500
        """,
        [
          dump(state.owner),
          Enum.map(ids, &dump/1),
          optional_dump(after_resource),
          optional_dump(after_tag)
        ]
      )

    state =
      Enum.reduce(rows, state, fn [resource, tag, display, normalized], current ->
        resource = text(resource)
        tag = text(tag)
        key = {resource, tag}

        current =
          if MapSet.member?(current.tags, tag),
            do: current,
            else:
              (
                current = charge(current, 1)
                current = %{current | tags: MapSet.put(current.tags, tag)}

                append(current, {:metadata, :tags}, %{
                  "id" => tag,
                  "display_value" => display,
                  "normalized_key" => normalized
                })
              )

        if MapSet.member?(current.assignments, key) do
          current
        else
          current = charge(current, 1)
          current = %{current | assignments: MapSet.put(current.assignments, key)}

          append(current, {:metadata, :tag_assignments}, %{
            "resource_id" => resource,
            "tag_id" => tag
          })
        end
      end)

    case List.last(rows) do
      [resource, tag | _] when length(rows) == 500 ->
        tag_assignments(state, ids, {text(resource), text(tag)})

      _ ->
        state
    end
  end

  defp project_metadata(state) do
    state =
      Enum.reduce(Enum.sort(Map.keys(state.resources)), state, fn id, current ->
        row = resource_row(current, id)

        append(current, {:metadata, :resources}, %{
          "id" => id,
          "kind" => row.kind,
          "title" => row.title,
          "current_version_id" => row.current_version_id,
          "deleted_at" => timestamp(row.deleted_at),
          "selection_reason" => Map.fetch!(current.resources, id)
        })
      end)

    Enum.reduce(Enum.sort(Map.keys(state.versions)), state, fn {_kind, resource, version} = key,
                                                               current ->
      entry = Map.fetch!(current.versions, key)

      if entry.projected? do
        current
      else
        row = resource_row(current, resource)
        metadata = version_row(current, row, version)

        availability =
          if entry.deleted?, do: "metadata_only_deleted", else: "metadata_only_unselected"

        current
        |> append({:metadata, :versions}, Map.put(metadata.record, "availability", availability))
        |> projected(key)
      end
    end)
  end

  defp resource_row(state, resource) do
    [kind, title, current, deleted] =
      one(
        query(
          state,
          """
          SELECT kind,title,current_version_id,deleted_at FROM content.resources
          WHERE id=$1 AND vault_id=$2 AND classification='private' LIMIT 1
          """,
          [dump(resource), dump(state.owner)]
        )
      )

    unless kind in ["note", "document", "asset"], do: fail(:integrity_failure)

    %{
      id: resource,
      kind: kind,
      title: title,
      current_version_id: text(current),
      deleted_at: deleted
    }
  end

  defp version_row(state, resource, version) do
    [revision, inserted_at] =
      one(
        query(
          state,
          """
          SELECT revision,inserted_at FROM content.resource_versions
          WHERE id=$1 AND resource_id=$2 AND vault_id=$3 AND classification='private' LIMIT 1
          """,
          [dump(version), dump(resource.id), dump(state.owner)]
        )
      )

    record =
      Map.new(@version_fields, &{&1, nil})
      |> Map.merge(%{
        "resource_id" => resource.id,
        "version_id" => version,
        "revision" => revision,
        "kind" => resource.kind,
        "inserted_at" => timestamp(inserted_at)
      })

    case resource.kind do
      "note" ->
        [title, parent, merge] =
          one(
            query(
              state,
              """
              SELECT title,parent_version_id,merge_parent_version_id FROM content.note_versions
              WHERE resource_version_id=$1 AND resource_id=$2 AND vault_id=$3
                AND classification='private' LIMIT 1
              """,
              [dump(version), dump(resource.id), dump(state.owner)]
            )
          )

        %{
          record:
            Map.merge(record, %{
              "parent_version_id" => text(parent),
              "merge_parent_version_id" => text(merge)
            }),
          title: title,
          deleted?: not is_nil(resource.deleted_at),
          parent_version_id: text(parent),
          merge_parent_version_id: text(merge)
        }

      "document" ->
        [
          title,
          status,
          media,
          adapter,
          format,
          extracted,
          digest,
          size,
          source_resource,
          source_version,
          asset,
          object
        ] =
          one(
            query(
              state,
              """
              SELECT title,state,media_type,extraction_adapter,extraction_format,extracted_text_digest,
                     source_digest,source_byte_size,source_resource_id,source_resource_version_id,
                     source_asset_id,source_object_id
              FROM content.document_versions
              WHERE resource_version_id=$1 AND resource_id=$2 AND vault_id=$3
                AND classification='private' LIMIT 1
              """,
              [dump(version), dump(resource.id), dump(state.owner)]
            )
          )

        %{
          record:
            Map.merge(record, %{
              "state" => status,
              "media_type" => media,
              "extraction_adapter" => adapter,
              "extraction_format" => format,
              "extracted_digest" => optional_hex(extracted),
              "original_digest" => hex(digest),
              "original_byte_size" => size
            }),
          title: title,
          deleted?: not is_nil(resource.deleted_at),
          parent_version_id: nil,
          merge_parent_version_id: nil,
          source: %{
            resource_id: text(source_resource),
            version_id: text(source_version),
            asset_id: text(asset),
            object_id: text(object)
          }
        }

      "asset" ->
        asset = asset_metadata(state, resource.id, version)

        %{
          record:
            Map.merge(record, %{
              "media_type" => asset.media_type,
              "original_byte_size" => asset.byte_size
            }),
          title: asset.title,
          deleted?: not is_nil(resource.deleted_at) or asset.deleted?,
          parent_version_id: nil,
          merge_parent_version_id: nil
        }
    end
  end

  defp asset_metadata(state, resource, version) do
    [title, media, size, deleted, candidates] =
      one(
        query(
          state,
          """
          SELECT m.original_filename,coalesce(m.detected_media_type,m.declared_media_type,'application/octet-stream'),
                 m.plaintext_byte_size,
                 (a.state IN ('pending_delete','deleted') OR ra.released_at IS NOT NULL OR EXISTS(
                   SELECT 1 FROM content.tombstones t
                   WHERE (t.asset_id,t.vault_id,t.classification)=(a.id,a.vault_id,a.classification))),
                 (SELECT count(*) FROM (
                   SELECT id FROM content.assets WHERE resource_version_id=$2 AND vault_id=$3
                   UNION SELECT asset_id FROM content.asset_metadata WHERE resource_version_id=$2 AND vault_id=$3
                   UNION SELECT asset_id FROM content.resource_assets WHERE resource_version_id=$2 AND vault_id=$3
                 ) candidates)
          FROM content.resources r
          JOIN content.resource_versions v ON (v.resource_id,v.vault_id,v.classification)=(r.id,r.vault_id,r.classification)
          JOIN content.assets a ON (a.resource_version_id,a.vault_id,a.classification)=(v.id,r.vault_id,r.classification)
          JOIN content.asset_metadata m ON (m.asset_id,m.resource_version_id,m.vault_id,m.classification)=(a.id,v.id,r.vault_id,r.classification)
          JOIN content.resource_assets ra ON (ra.resource_version_id,ra.asset_id,ra.vault_id,ra.classification)=(v.id,a.id,r.vault_id,r.classification)
          WHERE (r.id,v.id,r.vault_id,r.classification)=($1,$2,$3,'private') AND r.kind='asset'
          LIMIT 2
          """,
          [dump(resource), dump(version), dump(state.owner)]
        )
      )

    unless candidates == 1 and is_boolean(deleted), do: fail(:integrity_failure)
    %{title: title, media_type: media, byte_size: size, deleted?: deleted}
  end

  defp original_binding(state, resource, version, retained_object) do
    retained? = not is_nil(retained_object)
    metadata = asset_metadata(state, resource, version)
    row = resource_row(state, resource)

    unless retained? or (not metadata.deleted? and is_nil(row.deleted_at)),
      do: fail(:integrity_failure)

    [
      asset,
      object,
      domain,
      domain_version,
      domain_generation,
      object_generation,
      lookup,
      ciphertext,
      size,
      ciphertext_size,
      storage_ref,
      format,
      asset_state,
      lifecycle
    ] =
      one(
        query(
          state,
          """
          SELECT a.id,o.id,o.key_domain_id,e.domain_key_version_id,d.generation,e.key_generation,
                 o.lookup_digest,o.ciphertext_hash,o.plaintext_byte_size,o.ciphertext_byte_size,
                 o.storage_ref,o.format_version,a.state,o.lifecycle
          FROM content.assets a
          JOIN content.resource_versions v ON (v.id,v.vault_id,v.classification)=(a.resource_version_id,a.vault_id,a.classification)
          JOIN content.resources r ON (r.id,r.vault_id,r.classification)=(v.resource_id,v.vault_id,v.classification)
          JOIN content.resource_assets ra ON (ra.asset_id,ra.resource_version_id,ra.vault_id,ra.classification)=(a.id,a.resource_version_id,a.vault_id,a.classification)
          JOIN content.asset_objects o ON (o.id,o.vault_id,o.classification)=(CASE WHEN $4::uuid IS NULL THEN a.asset_object_id ELSE $4::uuid END,a.vault_id,a.classification)
          JOIN content.asset_key_envelopes e ON (e.asset_object_id,e.vault_id,e.key_domain_id,e.classification)=(o.id,o.vault_id,o.key_domain_id,o.classification)
          JOIN core.domain_key_versions d ON (d.id,d.vault_id,d.key_domain_id)=(e.domain_key_version_id,e.vault_id,e.key_domain_id)
          WHERE a.resource_version_id=$1 AND a.vault_id=$2 AND a.classification='private'
            AND r.id=$3 AND r.kind='asset' AND d.state='active'
          LIMIT 2
          """,
          [dump(version), dump(state.owner), dump(resource), optional_dump(retained_object)]
        )
      )

    unless size == metadata.byte_size and lifecycle == "available" and
             (retained? or asset_state in ["available", "processing", "ready"]),
           do: fail(:integrity_failure)

    %{
      "kind" => "asset",
      "resource_id" => resource,
      "version_id" => version,
      "asset_id" => text(asset),
      "object_id" => text(object),
      "owner_scope_id" => state.owner,
      "classification" => "private",
      "key_domain_id" => text(domain),
      "domain_key_version_id" => text(domain_version),
      "domain_key_generation" => domain_generation,
      "object_generation" => object_generation,
      "lookup_digest" => hex(lookup),
      "ciphertext_hash" => hex(ciphertext),
      "plaintext_byte_size" => size,
      "ciphertext_byte_size" => ciphertext_size,
      "storage_ref" => storage_ref,
      "format_version" => format,
      "plaintext_sha256" => nil
    }
  end

  defp attachment_record(resource, version, r, ordinal),
    do: %{
      "note_resource_id" => resource,
      "note_version_id" => version,
      "id" => r.attachment_id,
      "ordinal" => ordinal,
      "target_resource_id" => r.target_resource_id,
      "target_version_id" => r.target_resource_version_id,
      "target_kind" => Atom.to_string(r.target_kind),
      "role" => Atom.to_string(r.role),
      "label" => r.label
    }

  defp citation_record(resource, version, r, ordinal),
    do: %{
      "note_resource_id" => resource,
      "note_version_id" => version,
      "id" => r.citation_id,
      "ordinal" => ordinal,
      "source_resource_id" => r.source_resource_id,
      "source_version_id" => r.source_resource_version_id,
      "fragment_id" => r.fragment_id,
      "locator" => SourceLocator.to_map(r.locator)
    }

  defp fragment_record(resource, version, id, ordinal, digest, locator, path, offset, size),
    do: %{
      "id" => id,
      "resource_id" => resource,
      "version_id" => version,
      "ordinal" => ordinal,
      "digest" => digest,
      "locator" => locator,
      "extracted_path" => path,
      "start_byte" => offset,
      "byte_size" => size
    }

  defp href(source) do
    extension =
      case source.kind do
        :note -> "md"
        :document -> "txt"
        :asset -> "bin"
      end

    "sources/#{source.kind}-#{source.resource_id}-#{source.resource_version_id}.#{extension}"
  end

  defp link_context(state),
    do: %{repo: state.repo, principal_id: state.principal, owner_scope_id: state.owner}

  defp reverse_reduce({values, state}), do: {state, values}

  defp projected(state, key) do
    entry = Map.fetch!(state.versions, key)
    state = charge(state, 1)
    %{state | versions: Map.put(state.versions, key, %{entry | projected?: true})}
  end

  defp remember_key(state, key) do
    if MapSet.member?(state.keys, key) do
      state
    else
      unless MapSet.size(state.keys) < KnowledgeExport.limits().selected_keys, do: fail(:invalid)
      state = charge(state, 1)
      %{state | keys: MapSet.put(state.keys, key)}
    end
  end

  defp append(state, selector, value),
    do: %{state | spool: unwrap(Spool.append(state.spool, selector, value))}

  defp append_chunks(state, selector, <<>>), do: append(state, selector, "")

  defp append_chunks(state, selector, bytes) do
    size = min(byte_size(bytes), KnowledgeExport.limits().chunk_bytes)
    <<chunk::binary-size(size), rest::binary>> = bytes
    state = append(state, selector, chunk)
    if rest == "", do: state, else: append_chunks(state, selector, rest)
  end

  # Charge every retained and superseded traversal/index record in addition to
  # Spool's own framed payload, on-disk indexes and private reference charges.
  # These are actual fixed-budget counters, never caller-controlled quotas.
  defp charge(state, records) do
    accounting = %{
      state.spool.accounting
      | metadata_records: state.spool.accounting.metadata_records + records
    }

    unless accounting.metadata_records <= KnowledgeExport.limits().metadata_records,
      do: fail(:invalid)

    %{state | spool: %{state.spool | accounting: accounting}}
  end

  defp temporary_text(state, bytes) do
    accounting = %{
      state.spool.accounting
      | spool_bytes: state.spool.accounting.spool_bytes + bytes
    }

    unless accounting.spool_bytes <= KnowledgeExport.limits().metadata_bytes,
      do: fail(:invalid)

    %{state | spool: %{state.spool | accounting: accounting}}
  end

  defp query(state, sql, params) do
    unless state.spool._clock.() <= state.spool._deadline and state.repo.in_transaction?(),
      do: fail(:invalid)

    SafeSQL.query!(state.repo, sql, params).rows
  end

  defp one([row]), do: row
  defp one(_), do: fail(:integrity_failure)
  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, %Error{} = error}), do: throw({__MODULE__, KnowledgeError.from(error)})
  defp unwrap(_), do: fail(:invalid)
  defp unwrap_integrity({:ok, value}), do: value

  defp unwrap_integrity({:error, %Error{code: code} = error})
       when code not in [:invalid, :not_found],
       do: throw({__MODULE__, KnowledgeError.from(error)})

  defp unwrap_integrity(_), do: fail(:integrity_failure)
  defp canonical_id(value), do: unwrap(Types.canonical_uuid(%{id: value}, :id))
  defp dump(id), do: Ecto.UUID.dump!(id)
  defp optional_dump(nil), do: nil
  defp optional_dump(id), do: dump(id)
  defp text(nil), do: nil
  defp text(<<_::binary-size(16)>> = id), do: Ecto.UUID.load!(id)
  defp text(id), do: canonical_id(id)
  defp hex(<<_::binary-size(32)>> = bytes), do: Base.encode16(bytes, case: :lower)
  defp hex(_), do: fail(:integrity_failure)
  defp optional_hex(nil), do: nil
  defp optional_hex(bytes), do: hex(bytes)
  defp timestamp(nil), do: nil

  defp timestamp(%DateTime{microsecond: {microsecond, _}} = date),
    do: DateTime.to_iso8601(%{date | microsecond: {microsecond, 6}})

  defp timestamp(_), do: fail(:integrity_failure)

  defp path(kind, resource, version, media \\ nil),
    do: unwrap(KnowledgeExport.path(kind, resource, version, media))

  defp fail(code), do: throw({__MODULE__, Error.new(code)})

  defp abort(spool) do
    Spool.abort(spool)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
