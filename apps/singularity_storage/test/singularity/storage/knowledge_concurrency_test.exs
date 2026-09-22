defmodule Singularity.Storage.KnowledgeConcurrencyTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @timeout 10_000

  alias Singularity.Core.{
    DocumentCompletion,
    DocumentFragment,
    DocumentVersion,
    Error,
    SourceLocator
  }

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    KnowledgeTestGrants,
    MigrationRepo,
    ScopedRepo
  }

  alias Singularity.Storage.Postgres.DocumentRepository

  setup do
    source = KnowledgeFixtures.prepared_source!()

    %{
      source: source,
      context: KnowledgeFixtures.document_context(source),
      command: KnowledgeFixtures.document_command(source)
    }
  end

  for mismatch <- [false, true] do
    @mismatch mismatch
    test "overlapping imports serialize receipt ownership (mismatch=#{mismatch})", c do
      grants(fn ->
        gate = make_ref()

        blocker =
          start_connection(gate, :blocker, fn ->
            scoped(c, fn repo ->
              query!(repo, "SELECT id FROM content.assets WHERE id=$1 FOR UPDATE", [
                uuid(c.source.asset_id)
              ])

              checkpoint(gate, :locked)
              {:ok, :released}
            end)
          end)

        try do
          {blocker_pid, blocker_backend} = ready(gate, :blocker)
          send(blocker_pid, {gate, :start})
          assert_receive {^gate, :locked, ^blocker_pid}, @timeout

          retry = %{
            c.command
            | resource_id: Ecto.UUID.generate(),
              resource_version_id: Ecto.UUID.generate(),
              correlation_id: Ecto.UUID.generate(),
              inserted_at: DateTime.add(c.command.inserted_at, 60),
              title: if(@mismatch, do: "Different title", else: c.command.title)
          }

          first =
            start_connection(gate, :first, fn ->
              DocumentRepository.create_pending(c.context, c.command)
            end)

          try do
            {first_pid, first_backend} = ready(gate, :first)
            send(first_pid, {gate, :start})
            blocked_by!(first_backend, blocker_backend)

            second =
              start_connection(gate, :second, fn ->
                DocumentRepository.create_pending(c.context, retry)
              end)

            try do
              {second_pid, second_backend} = ready(gate, :second)

              assert Enum.uniq([blocker_backend, first_backend, second_backend]) == [
                       blocker_backend,
                       first_backend,
                       second_backend
                     ]

              send(second_pid, {gate, :start})
              blocked_by!(second_backend, first_backend)
              send(blocker_pid, {gate, :continue})
              assert {:ok, :released} = Task.await(blocker, @timeout)

              assert {:ok, %DocumentVersion{state: :pending, generation: 0} = winner} =
                       Task.await(first, @timeout)

              assert winner.resource_id == c.command.resource_id
              assert winner.resource_version_id == c.command.resource_version_id

              if @mismatch do
                assert {:error, %Error{code: :conflict}} = Task.await(second, @timeout)
              else
                assert {:ok, ^winner} = Task.await(second, @timeout)
              end

              assert_import_rows(c, retry, 1)
            after
              shutdown(second)
            end
          after
            shutdown(first)
          end
        after
          shutdown(blocker)
        end
      end)
    end
  end

  test "concurrent claims commit exactly one extraction generation", c do
    grants(fn ->
      {:ok, document} = DocumentRepository.create_pending(c.context, c.command)

      race(
        c,
        fn repo ->
          query!(repo, "SELECT content.claim_document_extraction($1,0,$1,'plain',1)", [
            uuid(document.resource_version_id)
          ])
        end,
        fn ->
          DocumentRepository.claim(
            c.context,
            document.resource_version_id,
            0,
            Ecto.UUID.generate(),
            "plain",
            1
          )
        end
      )

      assert {:ok, %DocumentVersion{state: :extracting, generation: 1, fragments: nil}} =
               DocumentRepository.get_version(
                 c.context,
                 document.resource_id,
                 document.resource_version_id
               )

      assert_fragment_count(document, 0)
    end)
  end

  for winner <- [:ready, :failed] do
    @winner winner
    test "#{winner} completion wins a guarded ready/failure collision", c do
      grants(fn ->
        {:ok, document} = DocumentRepository.create_pending(c.context, c.command)

        {:ok, _} =
          DocumentRepository.claim(
            c.context,
            document.resource_version_id,
            0,
            document.resource_version_id,
            "plain",
            1
          )

        ready = completion(document, :ready)
        failed = completion(document, :failed)
        winning = if @winner == :ready, do: ready, else: failed
        losing = if @winner == :ready, do: failed, else: ready

        race(c, &complete_sql(&1, winning), fn ->
          DocumentRepository.complete(c.context, document.resource_version_id, losing)
        end)

        assert {:ok, final} =
                 DocumentRepository.get_version(
                   c.context,
                   document.resource_id,
                   document.resource_version_id
                 )

        assert final.state == @winner
        assert final.generation == 1

        if @winner == :ready do
          assert final.fragments == ready.fragments
          assert final.extracted_text_digest == ready.extracted_text_digest
          assert final.failure_code == nil
          assert_fragment_count(document, 1)
        else
          assert final.fragments == nil
          assert final.extracted_text_digest == nil
          assert final.failure_code == "timeout"
          assert_fragment_count(document, 0)
        end
      end)
    end
  end

  test "reset commits before blocked stale completion and preserves the next generation", c do
    grants(fn ->
      {:ok, document} = DocumentRepository.create_pending(c.context, c.command)

      {:ok, _} =
        DocumentRepository.claim(
          c.context,
          document.resource_version_id,
          0,
          document.resource_version_id,
          "plain",
          1
        )

      {:ok, _} =
        DocumentRepository.complete(
          c.context,
          document.resource_version_id,
          completion(document, :failed)
        )

      stale = completion(document, :ready)

      race(
        c,
        fn repo ->
          query!(repo, "SELECT content.reset_document_extraction($1,1,'plain',1)", [
            uuid(document.resource_version_id)
          ])
        end,
        fn -> DocumentRepository.complete(c.context, document.resource_version_id, stale) end
      )

      assert {:ok, %DocumentVersion{state: :pending, generation: 1, fragments: nil}} =
               DocumentRepository.get_version(
                 c.context,
                 document.resource_id,
                 document.resource_version_id
               )

      assert {:ok, %DocumentVersion{state: :extracting, generation: 2}} =
               DocumentRepository.claim(
                 c.context,
                 document.resource_version_id,
                 1,
                 Ecto.UUID.generate(),
                 "plain",
                 1
               )

      assert {:error, %Error{code: :conflict}} =
               DocumentRepository.complete(c.context, document.resource_version_id, stale)

      assert {:ok, %DocumentVersion{state: :extracting, generation: 2, fragments: nil}} =
               DocumentRepository.get_version(
                 c.context,
                 document.resource_id,
                 document.resource_version_id
               )

      assert_fragment_count(document, 0)
    end)
  end

  test "source deletion after authenticated fixture binding prevents aggregate and receipt creation",
       c do
    grants(fn ->
      gate = make_ref()
      parent = self()
      # This injected digest proves the preparation contract, not live custody.
      context = %{
        c.context
        | digest_operation: fn _, binding ->
            refute RequestRepo.in_transaction?()
            assert binding.asset_id == c.source.asset_id
            send(parent, {gate, :authenticated, self()})
            wait_for(gate, :continue)
            {:ok, %{sha256: c.source.digest, byte_size: c.source.byte_size}}
          end
      }

      task =
        start_connection(gate, :create, fn ->
          DocumentRepository.create_pending(context, c.command)
        end)

      try do
        {pid, _} = ready(gate, :create)
        send(pid, {gate, :start})
        assert_receive {^gate, :authenticated, ^pid}, @timeout

        Fixtures.with_owner(fn ->
          assert %{num_rows: 1} =
                   query!(
                     MigrationRepo,
                     "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
                     [uuid(c.source.resource_id)]
                   )
        end)

        send(pid, {gate, :continue})
        assert {:error, %Error{code: :not_found}} = Task.await(task, @timeout)
        assert_import_rows(c, c.command, 0)
      after
        shutdown(task)
      end
    end)
  end

  defp race(c, first_call, contender) do
    gate = make_ref()

    first =
      start_connection(gate, :first, fn ->
        scoped(c, fn repo ->
          first_call.(repo)
          checkpoint(gate, :locked)
          {:ok, :committed}
        end)
      end)

    try do
      {first_pid, first_backend} = ready(gate, :first)
      send(first_pid, {gate, :start})
      assert_receive {^gate, :locked, ^first_pid}, @timeout
      second = start_connection(gate, :second, contender)

      try do
        {second_pid, second_backend} = ready(gate, :second)
        refute first_backend == second_backend
        send(second_pid, {gate, :start})
        blocked_by!(second_backend, first_backend)
        send(first_pid, {gate, :continue})
        assert {:ok, :committed} = Task.await(first, @timeout)
        assert {:error, %Error{code: :conflict}} = Task.await(second, @timeout)
      after
        shutdown(second)
      end
    after
      shutdown(first)
    end
  end

  defp start_connection(gate, label, fun) do
    parent = self()

    Task.async(fn ->
      RequestRepo.checkout(fn ->
        query!(RequestRepo, "SET lock_timeout='5s'")

        try do
          %{rows: [[backend]]} = query!(RequestRepo, "SELECT pg_backend_pid()")
          send(parent, {gate, :ready, label, self(), backend})
          wait_for(gate, :start)
          result = fun.()

          assert %{rows: [[nil, nil]]} =
                   query!(
                     RequestRepo,
                     "SELECT nullif(current_setting('singularity.principal_id',true),''), nullif(current_setting('singularity.vault_id',true),'')"
                   )

          result
        after
          query!(RequestRepo, "RESET lock_timeout")
        end
      end)
    end)
  end

  defp ready(gate, label) do
    assert_receive {^gate, :ready, ^label, pid, backend}, @timeout
    {pid, backend}
  end

  defp checkpoint(gate, label) do
    # Task.async records its caller for this test-only handshake.
    [parent | _] = Process.get(:"$callers")
    send(parent, {gate, label, self()})
    wait_for(gate, :continue)
  end

  defp wait_for(gate, action) do
    receive do
      {^gate, ^action} -> :ok
    after
      @timeout -> raise "knowledge concurrency barrier timed out"
    end
  end

  defp blocked_by!(waiting, blocking, attempts \\ 200)

  defp blocked_by!(_, _, 0),
    do: flunk("contender did not block on the expected PostgreSQL connection")

  defp blocked_by!(waiting, blocking, attempts) do
    %{rows: [[blocked]]} =
      query!(RequestRepo, "SELECT $2 = ANY(pg_blocking_pids($1))", [waiting, blocking])

    unless blocked do
      Process.sleep(10)
      blocked_by!(waiting, blocking, attempts - 1)
    end
  end

  defp shutdown(task) do
    if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp scoped(c, fun),
    do:
      ScopedRepo.transact(
        RequestRepo,
        %{principal_id: c.context.principal_id, vault_id: c.context.owner_scope_id},
        fun
      )

  defp completion(document, outcome) do
    identity =
      Map.take(document, [:resource_id, :resource_version_id, :owner_scope_id, :classification])

    {:ok, fragment} =
      DocumentFragment.new(
        Map.merge(identity, %{
          ordinal: 0,
          text: "hello",
          locator: %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}
        })
      )

    attrs = %{
      generation: 1,
      outcome: outcome,
      adapter_name: "plain",
      format_version: 1,
      finished_at: DateTime.utc_now(:microsecond),
      media_type: "text/plain"
    }

    attrs =
      if outcome == :ready,
        do: Map.merge(attrs, %{fragments: [fragment], extracted_text_digest: fragment.digest}),
        else: Map.put(attrs, :failure_code, "timeout")

    {:ok, value} = DocumentCompletion.new(Map.merge(identity, attrs))
    value
  end

  defp complete_sql(repo, %{outcome: :failed} = completion),
    do:
      query!(repo, "SELECT content.fail_document_extraction($1,$1,1,'failed','timeout')", [
        uuid(completion.resource_version_id)
      ])

  defp complete_sql(repo, completion) do
    fragments =
      Enum.map(completion.fragments, fn f ->
        %{
          "id" => f.fragment_id,
          "ordinal" => f.ordinal,
          "text" => f.text,
          "digest" => Base.encode16(f.digest, case: :lower),
          "locator" => SourceLocator.to_map(f.locator)
        }
      end)

    query!(repo, "SELECT content.complete_document_extraction($1,$1,1,$2,$3,NULL)", [
      uuid(completion.resource_version_id),
      fragments,
      completion.extracted_text_digest
    ])
  end

  defp assert_import_rows(c, retry, count) do
    Fixtures.with_owner(fn ->
      for table <- ~w(resources resource_versions document_versions) do
        column = if table == "document_versions", do: "resource_version_id", else: "id"

        ids =
          if table == "resources",
            do: [c.command.resource_id, retry.resource_id],
            else: [c.command.resource_version_id, retry.resource_version_id]

        assert %{rows: [[^count]]} =
                 query!(
                   MigrationRepo,
                   "SELECT count(*) FROM content.#{table} WHERE #{column}=ANY($1::uuid[])",
                   [Enum.map(ids, &uuid/1)]
                 )
      end

      assert %{rows: [[^count]]} =
               query!(
                 MigrationRepo,
                 "SELECT count(*) FROM content.document_import_receipts WHERE mutation_id=$1",
                 [uuid(c.command.mutation_id)]
               )

      if count == 1 do
        resource_id = uuid(c.command.resource_id)
        version_id = uuid(c.command.resource_version_id)

        assert %{rows: [["completed", ^resource_id, ^version_id]]} =
                 query!(
                   MigrationRepo,
                   "SELECT state,resource_id,version_id FROM content.document_import_receipts WHERE mutation_id=$1",
                   [uuid(c.command.mutation_id)]
                 )
      end
    end)
  end

  defp assert_fragment_count(document, count) do
    Fixtures.with_owner(fn ->
      assert %{rows: [[^count]]} =
               query!(
                 MigrationRepo,
                 "SELECT count(*) FROM content.document_fragments WHERE resource_version_id=$1",
                 [uuid(document.resource_version_id)]
               )
    end)
  end

  defp grants(fun),
    do:
      KnowledgeTestGrants.with_grants(["document_versions"], fn ->
        KnowledgeTestGrants.with_receipt_grants(fn ->
          KnowledgeTestGrants.with_lifecycle_grants(fn ->
            KnowledgeTestGrants.with_fragment_read_grants(fun)
          end)
        end)
      end)

  defp uuid(value), do: Ecto.UUID.dump!(value)
end
