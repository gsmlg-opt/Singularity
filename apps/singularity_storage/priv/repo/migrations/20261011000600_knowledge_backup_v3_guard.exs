defmodule Singularity.Storage.Migrations.KnowledgeBackupV3Guard do
  use Ecto.Migration

  # These are fixed canonical identity joins, including deferred identities that
  # may not yet have been checked at the backup cut. No runtime-selected SQL.
  @references [
    {"content.resource_versions", ~w(resource_id vault_id classification), "content.resources",
     ~w(id vault_id classification)},
    {"content.note_versions", ~w(resource_version_id resource_id vault_id classification),
     "content.resource_versions", ~w(id resource_id vault_id classification)},
    {"content.document_versions", ~w(resource_version_id resource_id vault_id classification),
     "content.resource_versions", ~w(id resource_id vault_id classification)},
    {"content.document_versions", ~w(source_asset_id vault_id classification), "content.assets",
     ~w(id vault_id classification)},
    {"content.document_versions", ~w(source_resource_id vault_id classification),
     "content.resources", ~w(id vault_id classification)},
    {"content.document_versions",
     ~w(source_resource_version_id source_resource_id vault_id classification),
     "content.resource_versions", ~w(id resource_id vault_id classification)},
    {"content.document_versions", ~w(source_object_id vault_id classification),
     "content.asset_objects", ~w(id vault_id classification)},
    {"content.document_fragments", ~w(resource_version_id resource_id vault_id classification),
     "content.document_versions", ~w(resource_version_id resource_id vault_id classification)},
    {"content.document_import_receipts", ~w(version_id resource_id vault_id),
     "content.document_versions", ~w(resource_version_id resource_id vault_id)},
    {"content.document_import_receipts", ~w(principal_id vault_id), "core.vault_members",
     ~w(principal_id vault_id)},
    {"content.note_attachments",
     ~w(note_resource_version_id note_resource_id vault_id classification),
     "content.note_versions", ~w(resource_version_id resource_id vault_id classification)},
    {"content.note_attachments",
     ~w(target_resource_version_id target_resource_id vault_id classification),
     "content.resource_versions", ~w(id resource_id vault_id classification)},
    {"content.note_citations",
     ~w(note_resource_version_id note_resource_id vault_id classification),
     "content.note_versions", ~w(resource_version_id resource_id vault_id classification)},
    {"content.note_citations",
     ~w(fragment_id source_resource_version_id source_resource_id vault_id classification),
     "content.document_fragments",
     ~w(id resource_version_id resource_id vault_id classification)},
    {"content.resource_tags", ~w(resource_id vault_id classification), "content.resources",
     ~w(id vault_id classification)},
    {"content.resource_tags", ~w(tag_id vault_id classification), "content.tags",
     ~w(id vault_id classification)},
    {"content.relationships", ~w(source_resource_id vault_id classification), "content.resources",
     ~w(id vault_id classification)},
    {"content.relationships", ~w(target_resource_id vault_id classification), "content.resources",
     ~w(id vault_id classification)},
    {"content.relationships",
     ~w(target_resource_version_id target_resource_id vault_id classification),
     "content.resource_versions", ~w(id resource_id vault_id classification)}
  ]

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")
    create_guard()

    execute("""
    REVOKE ALL ON FUNCTION content.backup_has_unsupported_canonical_rows(uuid,integer)
    FROM PUBLIC, singularity_web, singularity_worker, singularity_dispatcher, singularity_pre_auth
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION content.backup_has_unsupported_canonical_rows(uuid,integer)
    TO singularity_worker
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down, do: raise(Ecto.MigrationError, "Knowledge backup V3 guard is forward-only")

  defp create_guard do
    references =
      Enum.map(@references, fn {source, columns, target, target_columns} ->
        equality =
          Enum.zip(columns, target_columns)
          |> Enum.map_join(" AND ", fn {column, target_column} ->
            "s.#{column}=t.#{target_column}"
          end)

        "EXISTS(SELECT 1 FROM #{source} s WHERE s.vault_id=requested_vault_id " <>
          "AND s.#{hd(columns)} IS NOT NULL AND NOT EXISTS(SELECT 1 FROM #{target} t WHERE #{equality}))"
      end)

    creators =
      Enum.map(
        ~w(content.note_versions content.document_versions content.tags content.relationships),
        fn table ->
          "EXISTS(SELECT 1 FROM #{table} s WHERE s.vault_id=requested_vault_id AND NOT EXISTS(" <>
            "SELECT 1 FROM identity.principals p JOIN core.vault_members m ON m.principal_id=p.id " <>
            "WHERE p.id=s.created_by_principal_id AND p.account_id=owner_account_id AND m.vault_id=s.vault_id))"
        end
      )

    execute("""
    CREATE FUNCTION content.backup_has_unsupported_canonical_rows(requested_vault_id uuid, logical_version integer)
    RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, content, core
    AS $function$
    DECLARE owner_account_id uuid; document record; fragment record;
      bytes bytea; amount bigint; total_bytes bigint;
    BEGIN
      -- Authentication precedes every version branch, including unsupported ones.
      IF NOT EXISTS (
        SELECT 1 FROM core.live_principal_authorization() AS auth
        WHERE auth.vault_id = requested_vault_id
          AND auth.principal_kind = 'owner'
          AND auth.principal_revoked_at IS NULL
          AND auth.membership_revoked_at IS NULL
          AND 'backup.create' = ANY(auth.capabilities)
      ) THEN
        RAISE EXCEPTION 'backup authorization unavailable' USING ERRCODE = '42501';
      END IF;
      IF logical_version = 2 THEN
        RETURN content.backup_has_unsupported_canonical_rows(requested_vault_id);
      ELSIF logical_version IS DISTINCT FROM 3 THEN
        RETURN true;
      END IF;

      SELECT p.account_id INTO owner_account_id FROM identity.principals p
      WHERE p.id = NULLIF(current_setting('singularity.principal_id',true),'')::uuid;
      IF owner_account_id IS NULL THEN RETURN true; END IF;

      IF #{Enum.join(references ++ creators, "\n        OR ")}
        OR EXISTS(SELECT 1 FROM content.document_import_receipts r
          WHERE r.vault_id=requested_vault_id AND (r.state IS DISTINCT FROM 'completed'
            OR r.resource_id IS NULL OR r.version_id IS NULL OR octet_length(r.request_fingerprint) IS DISTINCT FROM 32
            OR NOT EXISTS(SELECT 1 FROM identity.principals p JOIN core.vault_members m ON m.principal_id=p.id
              WHERE p.id=r.principal_id AND p.account_id=owner_account_id AND m.vault_id=r.vault_id)))
        OR EXISTS(SELECT 1 FROM content.resources r WHERE r.vault_id=requested_vault_id
          AND ((r.kind IN ('asset','note','document')) IS NOT TRUE
            OR (r.classification IN ('private','sensitive','restricted')) IS NOT TRUE
            OR (r.kind IN ('note','document') AND r.classification IS DISTINCT FROM 'private')
            OR (r.kind='asset' AND r.current_version_id IS NOT NULL)
            OR (r.kind='note' AND NOT EXISTS(SELECT 1 FROM content.note_versions n
              WHERE (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=
                (r.current_version_id,r.id,r.vault_id,r.classification)))
            OR (r.kind='document' AND NOT EXISTS(SELECT 1 FROM content.document_versions d
              WHERE (d.resource_version_id,d.resource_id,d.vault_id,d.classification)=
                (r.current_version_id,r.id,r.vault_id,r.classification)))))
        OR EXISTS(SELECT 1 FROM content.resource_versions v JOIN content.resources r ON r.id=v.resource_id
          WHERE v.vault_id=requested_vault_id AND (v.revision<0
            OR (r.kind='note' AND NOT EXISTS(SELECT 1 FROM content.note_versions n
              WHERE (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=
                (v.id,v.resource_id,v.vault_id,v.classification)))
            OR (r.kind='document' AND NOT EXISTS(SELECT 1 FROM content.document_versions d
              WHERE (d.resource_version_id,d.resource_id,d.vault_id,d.classification)=
                (v.id,v.resource_id,v.vault_id,v.classification)))))
        OR EXISTS(SELECT 1 FROM content.note_versions n WHERE n.vault_id=requested_vault_id
          AND NOT EXISTS(SELECT 1 FROM content.resources r
            WHERE (r.id,r.vault_id,r.classification)=(n.resource_id,n.vault_id,n.classification) AND r.kind='note'))
        OR EXISTS(SELECT 1 FROM content.document_versions d WHERE d.vault_id=requested_vault_id
          AND NOT EXISTS(SELECT 1 FROM content.resources r
            WHERE (r.id,r.vault_id,r.classification)=(d.resource_id,d.vault_id,d.classification) AND r.kind='document'))
        OR EXISTS(SELECT 1 FROM content.note_versions n JOIN content.resource_versions v ON v.id=n.resource_version_id
          WHERE n.vault_id=requested_vault_id AND (
            (n.parent_version_id IS NULL) IS DISTINCT FROM (v.revision=0)
            OR (n.parent_version_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM content.note_versions p
              JOIN content.resource_versions pv ON pv.id=p.resource_version_id
              WHERE (p.resource_version_id,p.resource_id,p.vault_id,p.classification)=
                (n.parent_version_id,n.resource_id,n.vault_id,n.classification) AND pv.revision<v.revision))
            OR (n.merge_parent_version_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM content.note_versions p
              JOIN content.resource_versions pv ON pv.id=p.resource_version_id
              WHERE (p.resource_version_id,p.resource_id,p.vault_id,p.classification)=
                (n.merge_parent_version_id,n.resource_id,n.vault_id,n.classification) AND pv.revision<v.revision))))
        OR EXISTS(SELECT 1 FROM content.note_conflicts c WHERE c.vault_id=requested_vault_id
          AND ((c.state IN ('open','resolved')) IS NOT TRUE
            OR NOT EXISTS(SELECT 1 FROM content.note_versions b
              JOIN content.resource_versions bv ON bv.id=b.resource_version_id
              JOIN content.note_versions a ON a.resource_version_id=c.canonical_version_id
              JOIN content.resource_versions av ON av.id=a.resource_version_id
              JOIN content.note_versions p ON p.resource_version_id=c.competing_version_id
              JOIN content.resource_versions pv ON pv.id=p.resource_version_id
              WHERE (b.resource_version_id,b.resource_id,b.vault_id,b.classification)=
                (c.base_version_id,c.resource_id,c.vault_id,c.classification)
                AND (a.resource_id,a.vault_id,a.classification)=(c.resource_id,c.vault_id,c.classification)
                AND (p.resource_id,p.vault_id,p.classification)=(c.resource_id,c.vault_id,c.classification)
                AND bv.revision<av.revision AND bv.revision<pv.revision)
            OR (c.state='open' AND (c.resolution_version_id IS NOT NULL OR c.resolved_at IS NOT NULL))
            OR (c.state='resolved' AND (c.resolved_at IS NULL OR NOT EXISTS(SELECT 1 FROM content.note_versions n
              WHERE (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=
                (c.resolution_version_id,c.resource_id,c.vault_id,c.classification)
                AND n.parent_version_id=c.canonical_version_id AND n.merge_parent_version_id=c.competing_version_id))))) THEN
        RETURN true;
      END IF;

      IF EXISTS(SELECT 1 FROM content.document_versions d WHERE d.vault_id=requested_vault_id AND (
          (d.classification='private' AND octet_length(d.source_digest)=32
            AND d.source_byte_size BETWEEN 0 AND 67108864
            AND d.media_type IN ('application/pdf','text/plain','text/markdown')
            AND btrim(d.title)<>'' AND octet_length(d.title)<=255 AND d.attempt_generation>=0
            AND (d.extraction_format IS NULL OR d.extraction_format=1)
            AND (d.extraction_adapter IS NULL OR d.extraction_adapter=CASE d.media_type
              WHEN 'application/pdf' THEN 'poppler_text' WHEN 'text/plain' THEN 'plain_text'
              WHEN 'text/markdown' THEN 'markdown' END)
            AND (d.extracted_text_digest IS NULL OR octet_length(d.extracted_text_digest)=32)
            AND (d.detected_language IS NULL OR (octet_length(d.detected_language)<=255
              AND content.document_trim_name(d.detected_language)<>''))
            AND (d.failure_code IS NULL OR d.failure_code IN ('invalid_utf8','malformed_document','encrypted_document',
              'no_extractable_text','input_too_large','output_too_large','page_limit','timeout','extractor_failed')))
            IS NOT TRUE
          OR ((d.state='pending' AND d.attempt_job_id IS NULL AND d.attempt_started_at IS NULL
              AND d.attempt_deadline_at IS NULL AND d.extraction_adapter IS NULL AND d.extraction_format IS NULL
              AND d.extracted_text_digest IS NULL AND d.detected_language IS NULL
              AND d.failure_code IS NULL AND d.attempt_finished_at IS NULL)
            OR (d.state='extracting' AND d.attempt_generation>0 AND d.attempt_job_id IS NOT NULL
              AND d.attempt_started_at IS NOT NULL AND d.attempt_deadline_at=d.attempt_started_at+interval '180 seconds'
              AND d.extraction_adapter IS NOT NULL AND d.extraction_format IS NOT NULL
              AND d.extracted_text_digest IS NULL AND d.detected_language IS NULL
              AND d.failure_code IS NULL AND d.attempt_finished_at IS NULL)
            OR (d.state='ready' AND d.attempt_generation>0 AND d.attempt_job_id IS NOT NULL
              AND d.attempt_started_at IS NOT NULL AND d.attempt_deadline_at=d.attempt_started_at+interval '180 seconds'
              AND d.extraction_adapter IS NOT NULL AND d.extraction_format IS NOT NULL
              AND d.extracted_text_digest IS NOT NULL AND d.failure_code IS NULL AND d.attempt_finished_at IS NOT NULL)
            OR (d.state IN ('failed','unsupported') AND d.attempt_generation>0 AND d.attempt_job_id IS NOT NULL
              AND d.attempt_started_at IS NOT NULL AND d.attempt_deadline_at=d.attempt_started_at+interval '180 seconds'
              AND d.extraction_adapter IS NOT NULL AND d.extraction_format IS NOT NULL
              AND d.extracted_text_digest IS NULL AND d.detected_language IS NULL
              AND d.failure_code IS NOT NULL AND d.attempt_finished_at IS NOT NULL)) IS NOT TRUE
          OR (SELECT count(*) FROM content.assets a WHERE a.resource_version_id=d.source_resource_version_id)<>1
          OR NOT EXISTS(SELECT 1 FROM content.assets a
            JOIN content.resource_versions v ON (v.id,v.vault_id,v.classification)=(a.resource_version_id,a.vault_id,a.classification)
            JOIN content.resources r ON (r.id,r.vault_id,r.classification)=(v.resource_id,v.vault_id,v.classification)
            JOIN content.resource_assets ra ON (ra.asset_id,ra.resource_version_id,ra.vault_id,ra.classification)=
              (a.id,v.id,v.vault_id,v.classification)
            JOIN content.asset_objects o ON (o.id,o.vault_id,o.classification)=(d.source_object_id,d.vault_id,d.classification)
            WHERE (a.id,v.id,r.id,r.vault_id,r.classification)=
              (d.source_asset_id,d.source_resource_version_id,d.source_resource_id,d.vault_id,'private')
              AND r.kind='asset' AND (a.asset_object_id IS NULL OR a.asset_object_id=o.id)
              AND o.lifecycle='available' AND o.deleted_at IS NULL AND o.plaintext_byte_size=d.source_byte_size)))
        OR EXISTS(SELECT 1 FROM content.document_versions WHERE vault_id=requested_vault_id GROUP BY source_object_id
          HAVING count(DISTINCT pg_catalog.encode(source_digest,'hex'))<>1 OR count(DISTINCT source_byte_size)<>1)
        OR EXISTS(SELECT 1 FROM content.asset_objects o WHERE o.vault_id=requested_vault_id AND (
          o.format_version IS DISTINCT FROM 1
          OR (o.lifecycle='available' AND (o.deleted_at IS NOT NULL
            OR (o.storage_ref IS DISTINCT FROM o.id::text
              AND o.storage_ref IS DISTINCT FROM 'objects/'||o.vault_id::text||'/'||o.key_domain_id::text||'/hmac-sha256/'||
                pg_catalog.substr(pg_catalog.encode(o.lookup_digest,'hex'),1,2)||'/'||pg_catalog.encode(o.lookup_digest,'hex'))
            OR NOT EXISTS(SELECT 1 FROM content.asset_key_envelopes e JOIN core.domain_key_versions k
              ON (k.id,k.vault_id,k.key_domain_id,k.generation)=
                (e.domain_key_version_id,e.vault_id,e.key_domain_id,e.key_generation)
              JOIN core.key_domains domain ON (domain.id,domain.vault_id,domain.classification)=
                (o.key_domain_id,o.vault_id,o.classification)
              WHERE (e.asset_object_id,e.vault_id,e.key_domain_id,e.classification)=
                (o.id,o.vault_id,o.key_domain_id,o.classification) AND e.algorithm='aes_256_gcm')))))
        OR EXISTS(SELECT 1 FROM content.asset_key_envelopes e WHERE e.vault_id=requested_vault_id
          AND (e.algorithm IS DISTINCT FROM 'aes_256_gcm'
            OR NOT EXISTS(SELECT 1 FROM content.asset_objects o JOIN core.domain_key_versions k
              ON (k.id,k.vault_id,k.key_domain_id,k.generation)=
                (e.domain_key_version_id,e.vault_id,e.key_domain_id,e.key_generation)
              WHERE (o.id,o.vault_id,o.key_domain_id,o.classification)=
                (e.asset_object_id,e.vault_id,e.key_domain_id,e.classification)))) THEN
        RETURN true;
      END IF;

      -- Validate bounded ready text per immutable version; never concatenate the
      -- owner's entire history into one value. Encoding errors fail closed.
      BEGIN
        IF EXISTS(SELECT 1 FROM content.document_fragments f
          JOIN content.document_versions d ON d.resource_version_id=f.resource_version_id
          WHERE f.vault_id=requested_vault_id AND (
            d.state IS DISTINCT FROM 'ready' OR f.classification IS DISTINCT FROM 'private'
            OR octet_length(f.text)>65536 OR position(chr(13) in f.text)>0
            OR f.digest IS DISTINCT FROM pg_catalog.sha256(pg_catalog.convert_to(f.text,'UTF8'))
            OR f.locator IS DISTINCT FROM content.document_canonical_locator(f.locator)
            OR f.id IS DISTINCT FROM content.document_fragment_id(f.resource_version_id,f.locator,f.ordinal,f.digest)
            OR ((f.locator->>'kind') IN ('fragment',CASE d.media_type
              WHEN 'application/pdf' THEN 'pdf' WHEN 'text/plain' THEN 'text'
              WHEN 'text/markdown' THEN 'markdown' END)) IS NOT TRUE
            OR ((f.locator->>'kind')='fragment' AND
              content.document_json_integer(f.locator->'ordinal',0) IS DISTINCT FROM f.ordinal))) THEN RETURN true; END IF;

        FOR document IN SELECT resource_version_id,extracted_text_digest FROM content.document_versions
          WHERE vault_id=requested_vault_id AND state='ready'
        LOOP
          SELECT count(*),coalesce(sum(pg_catalog.octet_length(text)),0) INTO amount,total_bytes
          FROM content.document_fragments WHERE resource_version_id=document.resource_version_id;
          IF amount NOT BETWEEN 1 AND 4096 OR total_bytes NOT BETWEEN 1 AND 16777216 THEN RETURN true; END IF;
          bytes:=pg_catalog.decode('','hex'); amount:=0;
          FOR fragment IN SELECT ordinal,text FROM content.document_fragments
            WHERE resource_version_id=document.resource_version_id ORDER BY ordinal
          LOOP
            IF fragment.ordinal IS DISTINCT FROM amount THEN RETURN true; END IF;
            bytes:=bytes||pg_catalog.convert_to(fragment.text,'UTF8'); amount:=amount+1;
          END LOOP;
          IF pg_catalog.sha256(bytes) IS DISTINCT FROM document.extracted_text_digest THEN RETURN true; END IF;
        END LOOP;
      EXCEPTION WHEN check_violation OR invalid_parameter_value OR invalid_text_representation THEN
        RETURN true;
      END;

      IF EXISTS(SELECT 1 FROM content.note_attachments a WHERE a.vault_id=requested_vault_id AND (
          a.classification IS DISTINCT FROM 'private' OR a.role IS DISTINCT FROM 'source'
          OR NOT EXISTS(SELECT 1 FROM content.resources r
            WHERE (r.id,r.vault_id,r.classification,r.kind)=(a.target_resource_id,a.vault_id,a.classification,a.target_kind))
          OR (a.target_kind='note' AND NOT EXISTS(SELECT 1 FROM content.note_versions n
            WHERE (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=
              (a.target_resource_version_id,a.target_resource_id,a.vault_id,a.classification)))
          OR (a.target_kind='document' AND NOT EXISTS(SELECT 1 FROM content.document_versions d
            WHERE (d.resource_version_id,d.resource_id,d.vault_id,d.classification)=
              (a.target_resource_version_id,a.target_resource_id,a.vault_id,a.classification) AND d.state='ready'))
          OR (a.target_kind='asset' AND (SELECT count(*) FROM content.assets x JOIN content.resource_assets ra
            ON (ra.asset_id,ra.resource_version_id,ra.vault_id,ra.classification)=(x.id,x.resource_version_id,x.vault_id,x.classification)
            WHERE (x.resource_version_id,x.vault_id,x.classification)=
              (a.target_resource_version_id,a.vault_id,a.classification))<>1)))
        OR EXISTS(SELECT 1 FROM content.note_citations c WHERE c.vault_id=requested_vault_id
          AND (c.classification IS DISTINCT FROM 'private' OR NOT EXISTS(SELECT 1 FROM content.document_fragments f
            WHERE (f.id,f.resource_version_id,f.resource_id,f.vault_id,f.classification)=
              (c.fragment_id,c.source_resource_version_id,c.source_resource_id,c.vault_id,c.classification)
              AND f.locator=c.locator)))
        OR EXISTS(SELECT 1 FROM content.note_versions n
          CROSS JOIN LATERAL(SELECT count(*) amount,min(ordinal) first,max(ordinal) last
            FROM content.note_attachments WHERE note_resource_version_id=n.resource_version_id) a
          CROSS JOIN LATERAL(SELECT count(*) amount,min(ordinal) first,max(ordinal) last
            FROM content.note_citations WHERE note_resource_version_id=n.resource_version_id) c
          LEFT JOIN content.note_source_set_seals seal ON seal.note_resource_version_id=n.resource_version_id
          WHERE n.vault_id=requested_vault_id AND (a.amount>100 OR c.amount>100
            OR (a.amount>0 AND (a.first<>0 OR a.last<>a.amount-1))
            OR (c.amount>0 AND (c.first<>0 OR c.last<>c.amount-1))
            OR (SELECT count(*) FROM (
              SELECT target_resource_id,target_resource_version_id FROM content.note_attachments WHERE note_resource_version_id=n.resource_version_id
              UNION SELECT source_resource_id,source_resource_version_id FROM content.note_citations WHERE note_resource_version_id=n.resource_version_id) targets)>100
            OR seal.note_resource_version_id IS NULL
            OR (seal.note_resource_id,seal.vault_id,seal.classification,seal.attachment_count,seal.citation_count)
              IS DISTINCT FROM (n.resource_id,n.vault_id,n.classification,a.amount,c.amount)))
        OR EXISTS(SELECT 1 FROM content.note_source_set_seals s WHERE s.vault_id=requested_vault_id
          AND NOT EXISTS(SELECT 1 FROM content.note_versions n
            WHERE (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=
              (s.note_resource_version_id,s.note_resource_id,s.vault_id,s.classification)))
        OR EXISTS(SELECT 1 FROM content.tags t WHERE t.vault_id=requested_vault_id AND t.classification IS DISTINCT FROM 'private')
        OR EXISTS(SELECT 1 FROM content.resource_tags t WHERE t.vault_id=requested_vault_id AND t.classification IS DISTINCT FROM 'private')
        OR EXISTS(SELECT 1 FROM content.relationships r WHERE r.vault_id=requested_vault_id
          AND (r.classification IS DISTINCT FROM 'private' OR (r.type IN ('related_to','references','derived_from')) IS NOT TRUE))
        OR EXISTS(SELECT 1 FROM content.relationships e JOIN content.resources r ON r.id=e.target_resource_id
          WHERE e.vault_id=requested_vault_id AND r.kind='asset' AND e.target_resource_version_id IS NOT NULL
            AND (SELECT count(*) FROM content.assets a JOIN content.resource_assets ra
              ON (ra.asset_id,ra.resource_version_id,ra.vault_id,ra.classification)=
                (a.id,a.resource_version_id,a.vault_id,a.classification)
              JOIN content.resource_versions v ON (v.id,v.vault_id,v.classification)=
                (a.resource_version_id,a.vault_id,a.classification)
              WHERE (v.id,v.resource_id,v.vault_id,v.classification)=
                (e.target_resource_version_id,e.target_resource_id,e.vault_id,e.classification))<>1)
        OR EXISTS(SELECT 1 FROM (
          SELECT resource_id FROM content.resource_tags WHERE vault_id=requested_vault_id
          UNION SELECT source_resource_id FROM content.relationships WHERE vault_id=requested_vault_id
          UNION SELECT target_resource_id FROM content.relationships WHERE vault_id=requested_vault_id) selected
          JOIN content.resources r ON r.id=selected.resource_id
          WHERE r.kind='asset' AND NOT EXISTS(SELECT 1 FROM content.resource_versions v
            JOIN content.assets a ON (a.resource_version_id,a.vault_id,a.classification)=(v.id,v.vault_id,v.classification)
            JOIN content.resource_assets ra ON (ra.asset_id,ra.resource_version_id,ra.vault_id,ra.classification)=
              (a.id,v.id,v.vault_id,v.classification)
            WHERE (v.resource_id,v.vault_id,v.classification)=(r.id,r.vault_id,r.classification)
              AND (SELECT count(*) FROM content.assets WHERE resource_version_id=v.id)=1)) THEN
        RETURN true;
      END IF;

      RETURN false;
    END
    $function$
    """)
  end
end
