defmodule Singularity.Storage.DocumentLifecycleTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  alias Singularity.Core.DocumentFragment

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    KnowledgeTestGrants,
    MigrationRepo,
    ScopedRepo
  }

  @locator %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}
  @max 9_223_372_036_854_775_807
  @signatures [
    "claim_document_extraction(uuid,bigint,uuid,text,integer)",
    "complete_document_extraction(uuid,uuid,bigint,jsonb,bytea,text)",
    "fail_document_extraction(uuid,uuid,bigint,text,text)",
    "reset_document_extraction(uuid,bigint,text,integer)",
    "recover_document_extraction(uuid,bigint)"
  ]

  test "lifecycle functions are owned by the table owner, hardened and ungranted" do
    for signature <- @signatures do
      assert %{rows: [[true, true, config]]} =
               query!(
                 RequestRepo,
                 """
                 SELECT p.prosecdef, p.proowner = c.relowner, p.proconfig
                 FROM pg_proc p CROSS JOIN pg_class c
                 WHERE p.oid = to_regprocedure($1) AND c.oid = 'content.document_versions'::regclass
                 """,
                 ["content." <> signature]
               )

      assert "search_path=pg_catalog, content, core, identity" in config

      for role <-
            ~w(singularity_web singularity_worker singularity_dispatcher singularity_pre_auth) do
        assert %{rows: [[false]]} =
                 query!(RequestRepo, "SELECT has_function_privilege($1,$2,'EXECUTE')", [
                   role,
                   "content." <> signature
                 ])
      end

      assert %{rows: []} =
               query!(
                 RequestRepo,
                 """
                 SELECT a.grantee FROM pg_proc p
                 CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
                 WHERE p.oid = to_regprocedure($1) AND a.grantee = 0
                 """,
                 ["content." <> signature]
               )
    end
  end

  test "claim increments once, completion seals all fragments and exact replay does not mutate" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    fragments = [fragment(document, 0, "hello"), fragment(document, 1, "\nworld")]

    KnowledgeTestGrants.with_lifecycle_grants(fn ->
      assert %{
               "state" => "extracting",
               "attempt_generation" => 1,
               "extraction_adapter" => "plain",
               "extraction_format" => 1
             } = claim(source, document)

      assert state(document) == claim(source, document)

      conflict(fn ->
        invoke(
          RequestRepo,
          source,
          "claim",
          [document.resource_version_id, 0, KnowledgeFixtures.uuid(), "plain", 1],
          "uuid,bigint,uuid,text,integer"
        )
      end)

      conflict(fn -> complete(source, document, fragments, 0) end)
      ready = complete(source, document, fragments)
      assert ready["state"] == "ready"
      assert ready["attempt_finished_at"] != nil
      assert ready == complete(source, document, fragments)

      assert stored_fragments(document) ==
               Enum.map(fragments, &Map.take(&1, ~w(id ordinal text locator)))

      conflict(fn -> complete(source, document, [fragment(document, 0, "different")]) end)
      conflict(fn -> complete(source, document, fragments, 1, "fr") end)
      conflict(fn -> reset(source, document, 1) end)
      conflict(fn -> fail(source, document, 1, "failed", "timeout") end)
      assert state(document) == ready
    end)
  end

  test "failed and unsupported attempts reset without losing identity or reusing a generation" do
    for outcome <- ["failed", "unsupported"] do
      source = KnowledgeFixtures.source!()
      document = KnowledgeFixtures.document!(source)
      before = state(document)

      KnowledgeTestGrants.with_lifecycle_grants(fn ->
        conflict(fn -> reset(source, document, 0) end)
        claim(source, document)
        conflict(fn -> fail(source, document, 0, outcome, "timeout") end)
        failed = fail(source, document, 1, outcome, "timeout")
        assert failed["state"] == outcome
        assert failed["failure_code"] == "timeout"
        assert failed["attempt_finished_at"] != nil
        assert failed["attempt_job_id"] == Ecto.UUID.load!(document.resource_version_id)
        assert failed["attempt_started_at"] != nil
        assert failed["attempt_deadline_at"] != nil
        assert failed["source_object_id"] == before["source_object_id"]
        assert failed["extracted_text_digest"] == nil
        assert failed["detected_language"] == nil
        assert stored_fragments(document) == []
        conflict(fn -> reset(source, document, 0) end)
        if outcome == "unsupported", do: conflict(fn -> reset(source, document, 1) end)

        pending =
          reset(source, document, 1, if(outcome == "unsupported", do: "new", else: "plain"))

        assert pending["state"] == "pending"
        assert pending["attempt_generation"] == 1

        for key <-
              ~w(attempt_job_id attempt_started_at attempt_deadline_at extraction_adapter extraction_format extracted_text_digest detected_language failure_code attempt_finished_at),
            do: assert(pending[key] == nil)

        for key <-
              ~w(resource_id resource_version_id vault_id source_asset_id source_digest title inserted_at),
            do: assert(pending[key] == before[key])

        assert %{"attempt_generation" => 2} = claim(source, document, 1)
        conflict(fn -> complete(source, document, [fragment(document, 0, "ok")], 1) end)
      end)
    end
  end

  test "expired attempt is fenced and recovery permits a fresh job" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    first_job = document.resource_version_id
    next_job = KnowledgeFixtures.uuid()
    body = [fragment(document, 0, "fresh")]

    KnowledgeTestGrants.with_lifecycle_grants(fn ->
      first = claim(source, document)
      assert first["attempt_job_id"] == Ecto.UUID.load!(first_job)

      assert DateTime.diff(
               DateTime.from_iso8601(first["attempt_deadline_at"]) |> elem(1),
               DateTime.from_iso8601(first["attempt_started_at"]) |> elem(1),
               :microsecond
             ) == 180_000_000

      Fixtures.with_owner(fn ->
        query!(MigrationRepo, "SET CONSTRAINTS ALL IMMEDIATE")

        query!(
          MigrationRepo,
          "ALTER TABLE content.document_versions DISABLE TRIGGER document_versions_lifecycle_guard"
        )

        query!(
          MigrationRepo,
          "WITH previous AS (SELECT clock_timestamp() - interval '181 seconds' AS started) UPDATE content.document_versions SET attempt_started_at = previous.started, attempt_deadline_at = previous.started + interval '180 seconds' FROM previous WHERE resource_version_id = $1",
          [document.resource_version_id]
        )

        query!(
          MigrationRepo,
          "ALTER TABLE content.document_versions ENABLE TRIGGER document_versions_lifecycle_guard"
        )
      end)

      conflict(fn -> complete(source, document, body) end)
      conflict(fn -> fail(source, document, 1, "failed", "timeout") end)
      conflict(fn -> claim(source, document) end)

      recovered =
        invoke(RequestRepo, source, "recover", [document.resource_version_id, 1], "uuid,bigint")

      assert recovered["state"] == "pending"
      assert recovered["attempt_generation"] == 2
      assert recovered["attempt_job_id"] == nil
      conflict(fn -> complete(source, document, body) end)
      conflict(fn -> fail(source, document, 1, "failed", "timeout") end)

      claimed =
        invoke(
          RequestRepo,
          source,
          "claim",
          [document.resource_version_id, 2, next_job, "plain", 1],
          "uuid,bigint,uuid,text,integer"
        )

      assert claimed["attempt_generation"] == 3

      ready =
        invoke(
          RequestRepo,
          source,
          "complete",
          [document.resource_version_id, next_job, 3, body, :crypto.hash(:sha256, "fresh"), "en"],
          "uuid,uuid,bigint,jsonb,bytea,text"
        )

      assert ready["state"] == "ready"
      assert ready["attempt_job_id"] == Ecto.UUID.load!(next_job)
      assert ready["source_object_id"] == first["source_object_id"]
      assert ready["attempt_started_at"] == claimed["attempt_started_at"]
      assert ready["attempt_deadline_at"] == claimed["attempt_deadline_at"]

      assert ready ==
               invoke(
                 RequestRepo,
                 source,
                 "complete",
                 [
                   document.resource_version_id,
                   next_job,
                   3,
                   body,
                   :crypto.hash(:sha256, "fresh"),
                   "en"
                 ],
                 "uuid,uuid,bigint,jsonb,bytea,text"
               )

      conflict(fn -> complete(source, document, body, 3) end)

      Fixtures.with_owner(fn ->
        query!(MigrationRepo, "SET CONSTRAINTS ALL IMMEDIATE")

        query!(
          MigrationRepo,
          "ALTER TABLE content.document_versions DISABLE TRIGGER document_versions_lifecycle_guard"
        )

        query!(
          MigrationRepo,
          "WITH previous AS (SELECT clock_timestamp() - interval '181 seconds' AS started) UPDATE content.document_versions SET attempt_started_at = previous.started, attempt_deadline_at = previous.started + interval '180 seconds' FROM previous WHERE resource_version_id = $1",
          [document.resource_version_id]
        )

        query!(
          MigrationRepo,
          "ALTER TABLE content.document_versions ENABLE TRIGGER document_versions_lifecycle_guard"
        )
      end)

      sealed = state(document)
      assert sealed["attempt_deadline_at"] < DateTime.to_iso8601(DateTime.utc_now())

      assert sealed ==
               invoke(
                 RequestRepo,
                 source,
                 "complete",
                 [
                   document.resource_version_id,
                   next_job,
                   3,
                   body,
                   :crypto.hash(:sha256, "fresh"),
                   "en"
                 ],
                 "uuid,uuid,bigint,jsonb,bytea,text"
               )
    end)
  end

  test "EXECUTE alone cannot authorize missing, cross-owner or revoked scope for any operation" do
    source = KnowledgeFixtures.source!()
    other = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)

    KnowledgeTestGrants.with_lifecycle_grants(fn ->
      for repo <- [RequestRepo, WorkerRepo],
          scope <- [nil, other, %{source | principal_id: other.principal_id}] do
        for {name, args, casts} <- calls(document) do
          denied(fn -> invoke(repo, scope, name, args, casts) end)
        end
      end

      Fixtures.revoke_membership!(source)

      for {name, args, casts} <- calls(document), repo <- [RequestRepo, WorkerRepo] do
        denied(fn -> invoke(repo, source, name, args, casts) end)
      end

      assert state(document)["state"] == "pending"
    end)
  end

  test "claim validates metadata and refuses bigint exhaustion" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)

    KnowledgeTestGrants.with_lifecycle_grants(fn ->
      for adapter <- [nil, "", " ", String.duplicate("é", 128)] do
        invalid(fn ->
          invoke(
            RequestRepo,
            source,
            "claim",
            [document.resource_version_id, 0, document.resource_version_id, adapter, 1],
            "uuid,bigint,uuid,text,integer"
          )
        end)
      end

      for format <- [nil, 0, -1] do
        invalid(fn ->
          invoke(
            RequestRepo,
            source,
            "claim",
            [document.resource_version_id, 0, document.resource_version_id, "plain", format],
            "uuid,bigint,uuid,text,integer"
          )
        end)
      end

      exhausted = insert_exhausted(document)
      conflict(fn -> claim(source, exhausted, @max) end)
      assert state(exhausted)["attempt_generation"] == @max
    end)
  end

  test "revoked principals and disabled accounts invalidate every lifecycle entrypoint" do
    for revocation <- [:principal, :account] do
      source = KnowledgeFixtures.source!()
      document = KnowledgeFixtures.document!(source)

      Fixtures.with_owner(fn ->
        case revocation do
          :principal ->
            query!(
              MigrationRepo,
              "UPDATE identity.principals SET revoked_at = CURRENT_TIMESTAMP WHERE id = $1",
              [source.principal_id]
            )

          :account ->
            query!(
              MigrationRepo,
              "UPDATE identity.accounts SET status = 'disabled' WHERE id = $1",
              [source.account_id]
            )
        end
      end)

      KnowledgeTestGrants.with_lifecycle_grants(fn ->
        for repo <- [RequestRepo, WorkerRepo],
            {name, args, casts} <- calls(document),
            do: denied(fn -> invoke(repo, source, name, args, casts) end)
      end)
    end
  end

  test "fragment schema has a create contract and named constraints without a mutable changeset" do
    module = Singularity.Storage.Schema.Content.DocumentFragment
    assert Code.ensure_loaded?(module)
    assert function_exported?(module, :create_changeset, 2)
    refute function_exported?(module, :update_changeset, 2)
    changeset = apply(module, :create_changeset, [struct(module), %{unexpected: "private"}])
    refute changeset.valid?
    assert changeset.constraints != []
    refute Map.has_key?(changeset.changes, :unexpected)
  end

  test "completion validates every fragment and leaves no partial set on rejection" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    good = fragment(document, 0, "hello")

    malformed = [
      [],
      nil,
      %{},
      [Map.put(good, "extra", true)],
      [Map.put(good, "id", String.duplicate("0", 64))],
      [Map.put(good, "digest", String.duplicate("0", 64))],
      [Map.put(good, "ordinal", 1)],
      [good, good],
      [fragment(document, 0, "")],
      [fragment(document, 0, "a\rb")],
      [fragment(document, 0, String.duplicate("é", 32_769))],
      [good, Map.put(fragment(document, 1, "tail"), "digest", "bad")]
    ]

    KnowledgeTestGrants.with_lifecycle_grants(fn ->
      claim(source, document)

      for fragments <- malformed do
        invalid(fn ->
          complete_raw(source, document, fragments, :crypto.hash(:sha256, "hello"), nil)
        end)

        assert state(document)["state"] == "extracting"
        assert stored_fragments(document) == []
      end

      for language <- ["", " ", String.duplicate("é", 128)] do
        invalid(fn ->
          complete_raw(source, document, [good], :crypto.hash(:sha256, "hello"), language)
        end)
      end

      invalid(fn ->
        complete_raw(source, document, [good], :crypto.hash(:sha256, "wrong"), nil)
      end)

      for {outcome, code} <- [
            {"ready", "timeout"},
            {"failed", "private message"},
            {"unsupported", nil}
          ] do
        invalid(fn -> fail(source, document, 1, outcome, code) end)
      end

      assert complete(source, document, [good])["state"] == "ready"
    end)
  end

  test "SQL locator encoding and fragment identity match the independent core vector" do
    Fixtures.with_owner(fn ->
      assert %{rows: [[encoding, id]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT encode(content.document_locator_encoding($1),'hex'),
                   content.document_fragment_id($2,$1,0,$3)
                 """,
                 [
                   @locator,
                   Ecto.UUID.dump!("00000000-0000-4000-8000-000000000001"),
                   :crypto.hash(:sha256, "hello\n")
                 ]
               )

      assert encoding ==
               "000000000000000131000000000000000474657874000000000000000131000000000000000131"

      assert id == "a5e06997d69433d9a127780ef4d01c4e7147691745f5fcac15b230d3c3e48a48"
      locator = %{"version" => 1, "kind" => "markdown", "heading_path" => ["e\u0301"]}

      assert %{rows: [[encoded]]} =
               query!(MigrationRepo, "SELECT content.document_locator_encoding($1)", [locator])

      assert encoded == Singularity.Core.SourceLocator.encode(locator)
    end)
  end

  test "SQL rejects unknown locator fields, NULL holes, numeric coercion and invalid ranges" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    good = fragment(document, 0, "hello")

    locators = [
      nil,
      %{},
      Map.put(@locator, "page", 1),
      Map.put(@locator, "version", nil),
      Map.put(@locator, "kind", "unknown"),
      Map.delete(@locator, "end_line"),
      %{"version" => 1, "kind" => "pdf", "page" => 1, "start_char" => 1},
      %{"version" => 1, "kind" => "markdown", "heading_path" => List.duplicate("a", 65)},
      %{"version" => 1, "kind" => "markdown", "heading_path" => [String.duplicate("é", 128)]},
      %{"version" => 1, "kind" => "fragment", "ordinal" => 1}
    ]

    locators =
      locators ++
        for value <- [nil, 0, -1, 1.0, "1", @max + 1], do: Map.put(@locator, "start_line", value)

    KnowledgeTestGrants.with_lifecycle_grants(fn ->
      claim(source, document)

      for locator <- locators do
        invalid(fn ->
          complete_raw(
            source,
            document,
            [Map.put(good, "locator", locator)],
            :crypto.hash(:sha256, "hello"),
            nil
          )
        end)
      end

      assert stored_fragments(document) == []
    end)
  end

  test "valid locator kinds match core encoding while malformed ranges fail independently" do
    valid = [
      @locator,
      %{"version" => 1, "kind" => "pdf", "page" => @max},
      %{"version" => 1, "kind" => "pdf", "page" => 1, "start_char" => 0, "end_char" => @max},
      %{"version" => 1, "kind" => "markdown", "heading_path" => []},
      %{
        "version" => 1,
        "kind" => "markdown",
        "heading_path" => ["A"],
        "start_line" => 1,
        "end_line" => @max
      },
      %{"version" => 1, "kind" => "fragment", "ordinal" => @max}
    ]

    for locator <- valid do
      Fixtures.with_owner(fn ->
        assert %{rows: [[encoded]]} =
                 query!(MigrationRepo, "SELECT content.document_locator_encoding($1)", [locator])

        assert encoded == Singularity.Core.SourceLocator.encode(locator)
      end)
    end

    for locator <- [
          Map.put(@locator, "start_line", 2),
          %{"version" => 1, "kind" => "pdf", "page" => 0},
          %{"version" => 1, "kind" => "pdf", "page" => 1, "start_char" => 1, "end_char" => 1},
          %{"version" => 1, "kind" => "pdf", "page" => 1, "start_char" => nil, "end_char" => nil},
          %{"version" => 1, "kind" => "markdown", "heading_path" => [nil]},
          Map.put(@locator, "end_line", 1.0),
          Map.put(@locator, "version", 1.0),
          Map.put(@locator, "start_line", 1.0),
          Map.put(@locator, "version", nil),
          Map.put(@locator, "kind", nil),
          Map.put(@locator, "start_line", nil),
          Map.delete(@locator, "end_line"),
          Map.put(@locator, "page", 1),
          Map.put(@locator, "unexpected", nil)
        ] do
      invalid(fn ->
        Fixtures.with_owner(fn ->
          query!(MigrationRepo, "SELECT content.document_locator_encoding($1)", [locator])
        end)
      end)
    end
  end

  test "completion enforces aggregate fragment count and byte bounds without partial insertion" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)

    KnowledgeTestGrants.with_lifecycle_grants(fn ->
      claim(source, document)
      too_many = Enum.map(0..4096, &fragment(document, &1, "a"))
      invalid(fn -> complete(source, document, too_many) end)
      assert stored_fragments(document) == []
      assert state(document)["state"] == "extracting"

      # Every fragment fits 64 KiB; the aggregate exceeds 16 MiB by one byte.
      text = String.duplicate("a", 65_536)

      too_large =
        Enum.map(0..255, &fragment(document, &1, text)) ++ [fragment(document, 256, "a")]

      invalid(fn -> complete(source, document, too_large) end)
      assert stored_fragments(document) == []
      assert state(document)["state"] == "extracting"
    end)
  end

  test "completion rejects canonical locators for another media kind and accepts ordinal fallback" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)

    KnowledgeTestGrants.with_lifecycle_grants(fn ->
      claim(source, document)

      for locator <- [
            %{"version" => 1, "kind" => "pdf", "page" => 1},
            %{"version" => 1, "kind" => "markdown", "heading_path" => []}
          ] do
        # IDs use the actual valid locator so media compatibility is isolated.
        fragment = fragment(document, 0, "hello", locator)
        invalid(fn -> complete(source, document, [fragment]) end)
        assert stored_fragments(document) == []
      end

      fallback =
        fragment(document, 0, "hello", %{"version" => 1, "kind" => "fragment", "ordinal" => 0})

      assert complete(source, document, [fallback])["state"] == "ready"
      assert stored_fragments(document) == [Map.take(fallback, ~w(id ordinal text locator))]
    end)
  end

  test "immutable identity and pinned source updates fail at the statement before commit" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)

    assignments = [
      {"resource_id", KnowledgeFixtures.uuid()},
      {"resource_version_id", KnowledgeFixtures.uuid()},
      {"source_asset_id", KnowledgeFixtures.uuid()},
      {"source_resource_id", KnowledgeFixtures.uuid()},
      {"source_resource_version_id", KnowledgeFixtures.uuid()},
      {"source_object_id", KnowledgeFixtures.uuid()},
      {"source_digest", :crypto.hash(:sha256, "different")},
      {"source_byte_size", 13},
      {"media_type", "application/pdf"},
      {"created_by_principal_id", KnowledgeFixtures.uuid()}
    ]

    KnowledgeTestGrants.with_direct_mutation_grants(fn ->
      for repo <- [RequestRepo, WorkerRepo], {column, value} <- assignments do
        assert {:error, :expected_immutable_rejection} =
                 ScopedRepo.transact(repo, source, fn scoped ->
                   rejected("document_versions_immutable_check", fn ->
                     query!(
                       scoped,
                       "UPDATE content.document_versions SET #{column} = $2 WHERE resource_version_id = $1",
                       [document.resource_version_id, value]
                     )
                   end)

                   scoped.rollback(:expected_immutable_rejection)
                 end)
      end
    end)
  end

  test "deferred completion guards reject partial pending fragments and empty ready versions" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)

    rejected("document_versions_completion_check", fn ->
      Fixtures.with_owner(fn ->
        insert_fragment(document, fragment(document, 0, "hello"))
      end)
    end)

    KnowledgeTestGrants.with_lifecycle_grants(fn -> claim(source, document) end)

    rejected("document_versions_completion_check", fn ->
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          """
          UPDATE content.document_versions SET state = 'ready',
            extracted_text_digest = $2, attempt_finished_at = CURRENT_TIMESTAMP
          WHERE resource_version_id = $1
          """,
          [document.resource_version_id, :crypto.hash(:sha256, "hello")]
        )
      end)
    end)

    KnowledgeTestGrants.with_lifecycle_grants(fn ->
      complete(source, document, [fragment(document, 0, "hello")])
    end)

    rejected("document_fragments_insert_state_check", fn ->
      Fixtures.with_owner(fn ->
        insert_fragment(document, fragment(document, 1, "tail"))
      end)
    end)
  end

  test "accidental runtime grants cannot mutate lifecycle, immutable identity or sealed fragments" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)

    KnowledgeTestGrants.with_direct_mutation_grants(fn ->
      for repo <- [RequestRepo, WorkerRepo],
          assignment <- ["state = 'extracting'", "attempt_generation = 1"] do
        rejected("document_versions_lifecycle_guard_check", fn ->
          ScopedRepo.transact(repo, source, fn scoped ->
            query!(scoped, "SELECT set_config('singularity.document_lifecycle', 'on', true)")

            query!(
              scoped,
              "UPDATE content.document_versions SET #{assignment} WHERE resource_version_id = $1",
              [document.resource_version_id]
            )
          end)
        end)
      end

      rejected("document_versions_immutable_check", fn ->
        ScopedRepo.transact(RequestRepo, source, fn repo ->
          query!(
            repo,
            "UPDATE content.document_versions SET title = 'changed' WHERE resource_version_id = $1",
            [document.resource_version_id]
          )
        end)
      end)

      rejected("document_versions_immutable_check", fn ->
        ScopedRepo.transact(RequestRepo, source, fn repo ->
          query!(repo, "DELETE FROM content.document_versions WHERE resource_version_id = $1", [
            document.resource_version_id
          ])
        end)
      end)
    end)

    KnowledgeTestGrants.with_lifecycle_grants(fn ->
      claim(source, document)
      complete(source, document, [fragment(document, 0, "hello")])
    end)

    KnowledgeTestGrants.with_direct_mutation_grants(fn ->
      for repo <- [RequestRepo, WorkerRepo],
          statement <- [
            "UPDATE content.document_fragments SET text = 'changed' WHERE resource_version_id = $1",
            "DELETE FROM content.document_fragments WHERE resource_version_id = $1"
          ] do
        rejected("document_fragments_immutable_check", fn ->
          ScopedRepo.transact(repo, source, fn scoped ->
            query!(scoped, statement, [document.resource_version_id])
          end)
        end)
      end
    end)
  end

  defp calls(document) do
    id = document.resource_version_id

    [
      {"claim", [id, 0, id, "plain", 1], "uuid,bigint,uuid,text,integer"},
      {"complete",
       [id, id, 1, [fragment(document, 0, "hello")], :crypto.hash(:sha256, "hello"), nil],
       "uuid,uuid,bigint,jsonb,bytea,text"},
      {"fail", [id, id, 1, "failed", "timeout"], "uuid,uuid,bigint,text,text"},
      {"reset", [id, 1, "plain", 1], "uuid,bigint,text,integer"},
      {"recover", [id, 1], "uuid,bigint"}
    ]
  end

  defp invoke(repo, scope, name, args, casts) do
    sql_args =
      casts
      |> String.split(",")
      |> Enum.with_index(1)
      |> Enum.map_join(",", fn {type, index} -> "$#{index}::#{type}" end)

    run = fn scoped ->
      %{rows: [[row]]} =
        query!(
          scoped,
          "SELECT to_jsonb(result) FROM content.#{name}_document_extraction(#{sql_args}) result",
          args
        )

      row
    end

    if scope, do: ScopedRepo.transact(repo, scope, run), else: run.(repo)
  end

  defp claim(scope, document, generation \\ 0),
    do:
      invoke(
        RequestRepo,
        scope,
        "claim",
        [document.resource_version_id, generation, document.resource_version_id, "plain", 1],
        "uuid,bigint,uuid,text,integer"
      )

  defp fail(scope, document, generation, outcome, code),
    do:
      invoke(
        RequestRepo,
        scope,
        "fail",
        [document.resource_version_id, document.resource_version_id, generation, outcome, code],
        "uuid,uuid,bigint,text,text"
      )

  defp reset(scope, document, generation, adapter \\ "plain"),
    do:
      invoke(
        RequestRepo,
        scope,
        "reset",
        [document.resource_version_id, generation, adapter, 1],
        "uuid,bigint,text,integer"
      )

  defp complete(scope, document, fragments, generation \\ 1, language \\ "en"),
    do:
      invoke(
        RequestRepo,
        scope,
        "complete",
        [
          document.resource_version_id,
          document.resource_version_id,
          generation,
          fragments,
          :crypto.hash(:sha256, Enum.map(fragments, & &1["text"])),
          language
        ],
        "uuid,uuid,bigint,jsonb,bytea,text"
      )

  defp complete_raw(scope, document, fragments, digest, language),
    do:
      invoke(
        RequestRepo,
        scope,
        "complete",
        [
          document.resource_version_id,
          document.resource_version_id,
          1,
          fragments,
          digest,
          language
        ],
        "uuid,uuid,bigint,jsonb,bytea,text"
      )

  defp fragment(document, ordinal, text, locator \\ @locator) do
    digest = :crypto.hash(:sha256, text)

    %{
      "id" =>
        DocumentFragment.id(
          Ecto.UUID.load!(document.resource_version_id),
          locator,
          ordinal,
          digest
        ),
      "ordinal" => ordinal,
      "text" => text,
      "digest" => Base.encode16(digest, case: :lower),
      "locator" => locator
    }
  end

  defp state(document),
    do:
      Fixtures.with_owner(fn ->
        %{rows: [[row]]} =
          query!(
            MigrationRepo,
            "SELECT to_jsonb(d) FROM content.document_versions d WHERE resource_version_id = $1",
            [document.resource_version_id]
          )

        row
      end)

  defp insert_exhausted(template) do
    document = %{
      template
      | resource_id: KnowledgeFixtures.uuid(),
        resource_version_id: KnowledgeFixtures.uuid()
    }

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resources (id,vault_id,classification,kind,current_version_id,title) VALUES ($1,$2,'private','document',$3,'Document')",
        [document.resource_id, document.vault_id, document.resource_version_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions (id,resource_id,vault_id,classification,revision) VALUES ($1,$2,$3,'private',0)",
        [document.resource_version_id, document.resource_id, document.vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.document_versions
          (resource_version_id,resource_id,vault_id,classification,source_asset_id,source_resource_id,
           source_resource_version_id,source_object_id,source_digest,source_byte_size,media_type,title,
           created_by_principal_id,state,attempt_generation,inserted_at)
        SELECT $1,$2,vault_id,classification,source_asset_id,source_resource_id,
           source_resource_version_id,source_object_id,source_digest,source_byte_size,media_type,title,
           created_by_principal_id,'pending',$3,CURRENT_TIMESTAMP
        FROM content.document_versions WHERE resource_version_id = $4
        """,
        [document.resource_version_id, document.resource_id, @max, template.resource_version_id]
      )
    end)

    document
  end

  defp insert_fragment(document, fragment) do
    query!(
      MigrationRepo,
      """
      INSERT INTO content.document_fragments
        (id,resource_id,resource_version_id,vault_id,classification,ordinal,text,digest,locator,inserted_at)
      VALUES ($1,$2,$3,$4,'private',$5,$6,$7,$8,CURRENT_TIMESTAMP)
      """,
      [
        fragment["id"],
        document.resource_id,
        document.resource_version_id,
        document.vault_id,
        fragment["ordinal"],
        fragment["text"],
        Base.decode16!(fragment["digest"], case: :lower),
        fragment["locator"]
      ]
    )
  end

  defp stored_fragments(document),
    do:
      Fixtures.with_owner(fn ->
        %{rows: rows} =
          query!(
            MigrationRepo,
            "SELECT jsonb_build_object('id',id,'ordinal',ordinal,'text',text,'locator',locator) FROM content.document_fragments WHERE resource_version_id = $1 ORDER BY ordinal",
            [document.resource_version_id]
          )

        List.flatten(rows)
      end)

  defp conflict(fun), do: rejected("document_extraction_conflict_check", fun)
  defp invalid(fun), do: rejected("document_extraction_input_check", fun)

  defp denied(fun),
    do: rejected("document_extraction_authority_check", fun, :insufficient_privilege)

  defp rejected(constraint, fun, code \\ :check_violation) do
    error = assert_raise Postgrex.Error, fun
    assert error.postgres.code == code
    assert error.postgres.constraint == constraint
  end
end
