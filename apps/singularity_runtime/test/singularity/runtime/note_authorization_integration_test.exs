defmodule Singularity.Runtime.NoteAuthorizationIntegrationTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Core.NoteSaveResult
  alias Singularity.Retrieval.NoteSearchPage
  alias Singularity.Runtime.AuthorizationDependencies
  alias Singularity.Runtime.Authorize
  alias Singularity.Runtime.Notes.Create
  alias Singularity.Runtime.Notes.Delete
  alias Singularity.Runtime.Notes.Export
  alias Singularity.Runtime.Notes.Get
  alias Singularity.Runtime.Notes.History
  alias Singularity.Runtime.Notes.Merge
  alias Singularity.Runtime.Notes.Restore
  alias Singularity.Runtime.Notes.Save
  alias Singularity.Runtime.Notes.Search
  alias Singularity.Runtime.Notes.Trash
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.AuthorizationLock
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.IdentityRepository
  alias Singularity.Storage.Postgres.NoteRepository
  alias Singularity.Storage.NoteFixtures
  alias Singularity.Storage.RequestRepo
  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.VaultLock

  defmodule Custodian do
    def assert_unlocked(
          _owner,
          _session_id,
          _principal_id,
          _vault_id,
          _principal_epoch,
          _vault_epoch
        ),
        do: :ok
  end

  defmodule SearchAdapter do
    def search(_owner, _store, _repo, _query),
      do: {:ok, %NoteSearchPage{items: [], next_cursor: nil}}
  end

  defmodule Store do
  end

  defmodule AuditSink do
    def append(_owner, _repo, _event), do: :ok
  end

  defmodule Repository do
    @behaviour Singularity.Domains.Notes.Repository

    def get(_repo, vault_id, resource_id) do
      %{vault_id: ^vault_id, resource_id: ^resource_id} = row = Process.get(:auth_note_row)
      {:ok, row}
    end

    def get_version(_repo, vault_id, resource_id, version_id) do
      row = Process.get(:auth_note_version)

      if row.vault_id == vault_id and row.resource_id == resource_id and
           row.resource_version_id == version_id,
         do: {:ok, row},
         else: {:error, Error.new(:not_found)}
    end

    def get_conflict(_repo, vault_id, resource_id, conflict_id) do
      row = Process.get(:auth_note_row)
      competing = Process.get(:auth_note_version)

      {:ok,
       %{
         conflict: %{
           conflict_id: conflict_id,
           resource_id: resource_id,
           vault_id: vault_id,
           classification: :private,
           base_version_id: row.parent_version_id,
           observed_canonical_version_id: row.resource_version_id,
           competing_version_id: competing.resource_version_id,
           state: :open,
           resolution_version_id: nil,
           created_at: row.updated_at,
           resolved_at: nil
         },
         current: row,
         competing: %{competing | canonical?: false, conflict_state: :open}
       }}
    end

    def history(_repo, _vault_id, _resource_id, _params),
      do: {:ok, %{items: [], next_cursor: :done}}

    def trash(_repo, _vault_id, _params), do: {:ok, %{items: [], next_cursor: :done}}

    @impl true
    def create(_repo, _intent), do: saved()

    @impl true
    def save(_repo, _intent), do: saved()

    @impl true
    def merge(_repo, _intent), do: saved()

    @impl true
    def tombstone(_repo, _intent) do
      row = Process.get(:auth_note_row)

      {:ok,
       %{
         resource_id: row.resource_id,
         canonical_version_id: row.resource_version_id,
         state: :tombstoned
       }}
    end

    @impl true
    def restore(_repo, _intent) do
      row = Process.get(:auth_note_row)

      {:ok,
       %{
         resource_id: row.resource_id,
         canonical_version_id: row.resource_version_id,
         state: :restored
       }}
    end

    defp saved do
      row = Process.get(:auth_note_row)

      NoteSaveResult.saved(%{
        resource_id: row.resource_id,
        canonical_version_id: row.resource_version_id,
        submitted_version_id: row.resource_version_id
      })
    end
  end

  setup do
    raw = Fixtures.two_vaults!().one
    vault_id = load_uuid(raw.vault_id)
    resource_id = Ecto.UUID.generate()
    version_id = Ecto.UUID.generate()
    competing_id = Ecto.UUID.generate()

    Process.put(:auth_note_row, canonical_row(vault_id, resource_id, version_id))
    Process.put(:auth_note_version, version_row(vault_id, resource_id, competing_id, version_id))

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE core.vaults SET locked = false WHERE id = $1", [raw.vault_id])

      for capability <- ["note.export", "note.read", "note.write"] do
        query!(
          MigrationRepo,
          "INSERT INTO core.capabilities (id, name) VALUES ($1, $2) ON CONFLICT (name) DO NOTHING",
          [dump!(Ecto.UUID.generate()), capability]
        )
      end
    end)

    principals = %{
      read_only: create_principal!(raw.vault_id, ["note.read"]),
      write_only: create_principal!(raw.vault_id, ["note.write"]),
      export_only: create_principal!(raw.vault_id, ["note.export"]),
      read_export: create_principal!(raw.vault_id, ["note.export", "note.read"])
    }

    assert {:ok, authorization} =
             AuthorizationDependencies.new(%{
               store: IdentityRepository,
               custodian: {Custodian, self()}
             })

    runtime = %{
      audit: {AuditSink, self()},
      authorization: authorization,
      authorization_lock: AuthorizationLock,
      authorizer: Authorize,
      fingerprint_secret: :binary.copy(<<0xC7>>, 32),
      mutation_fingerprint: Singularity.Runtime.Notes.MutationFingerprint,
      note_repository: Repository,
      note_search: {SearchAdapter, self()},
      note_search_store: Store,
      notes: Singularity.Domains.Notes,
      operation_scope: OperationScope,
      request_repo: RequestRepo,
      scoped_repo: ScopedRepo,
      vault_lock: VaultLock
    }

    on_exit(fn ->
      Process.delete(:auth_note_row)
      Process.delete(:auth_note_version)
    end)

    {:ok,
     runtime: runtime,
     principals: principals,
     resource_id: resource_id,
     version_id: version_id,
     competing_id: competing_id,
     conflict_id: Ecto.UUID.generate()}
  end

  test "same-vault principals receive only their exact read write and export authority",
       context do
    %{runtime: runtime, principals: principals} = context

    for result <- read_operations(runtime, session(principals.read_only), context) do
      assert {:ok, _value} = result
    end

    assert {:error, %Error{code: :forbidden}} =
             Export.run(runtime, session(principals.read_only), context.resource_id)

    for result <- write_operations(runtime, session(principals.read_only), context) do
      assert {:error, %Error{code: :forbidden}} = result
    end

    for result <- write_operations(runtime, session(principals.write_only), context) do
      assert {:ok, _value} = result
    end

    for result <- read_operations(runtime, session(principals.write_only), context) do
      assert {:error, %Error{code: :forbidden}} = result
    end

    assert {:error, %Error{code: :forbidden}} =
             Export.run(runtime, session(principals.export_only), context.resource_id)

    for result <- read_operations(runtime, session(principals.export_only), context) do
      assert {:error, %Error{code: :forbidden}} = result
    end

    for result <- write_operations(runtime, session(principals.export_only), context) do
      assert {:error, %Error{code: :forbidden}} = result
    end

    for result <- read_operations(runtime, session(principals.read_export), context) do
      assert {:ok, _value} = result
    end

    assert {:ok, _export} =
             Export.run(runtime, session(principals.read_export), context.resource_id)

    for result <- write_operations(runtime, session(principals.read_export), context) do
      assert {:error, %Error{code: :forbidden}} = result
    end
  end

  test "revocation and principal or vault epoch changes deny stale sessions", context do
    %{runtime: runtime, principals: principals} = context

    read_session = session(principals.read_only)
    assert {:ok, _page} = Search.run(runtime, read_session, %{})

    revoke_capability!(principals.read_only, "note.read")
    increment_principal_epoch!(principals.read_only.principal_id)

    assert {:error, %Error{code: :forbidden}} = Search.run(runtime, read_session, %{})

    write_session = session(principals.write_only)

    assert {:ok, _note} =
             Create.run(runtime, write_session, %{
               mutation_id: Ecto.UUID.generate(),
               title: "Authorized",
               markdown: "# Authorized"
             })

    revoke_capability!(principals.write_only, "note.write")

    assert {:error, %Error{code: :forbidden}} =
             Create.run(runtime, write_session, %{
               mutation_id: Ecto.UUID.generate(),
               title: "Denied",
               markdown: "# Denied"
             })

    export_session = session(principals.read_export)
    assert {:ok, _export} = Export.run(runtime, export_session, context.resource_id)

    revoke_capability!(principals.read_export, "note.export")

    assert {:error, %Error{code: :forbidden}} =
             Export.run(runtime, export_session, context.resource_id)

    grant_capability!(principals.read_export, "note.export")
    current_export_session = session(principals.read_export)
    assert {:ok, _export} = Export.run(runtime, current_export_session, context.resource_id)

    increment_vault_epoch!(principals.read_export.vault_id)

    assert {:error, %Error{code: :forbidden}} =
             Export.run(runtime, current_export_session, context.resource_id)
  end

  test "accepted Delete replay returns true without a second durable mutation", context do
    note = NoteFixtures.note!()

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE core.vaults SET locked = false WHERE id = $1", [
        dump!(note.vault_id)
      ])
    end)

    grant_capability!(note, "note.write")
    note_session = session(note)

    runtime = %{
      context.runtime
      | note_repository: NoteRepository,
        notes: Singularity.Domains.Notes,
        mutation_fingerprint: Singularity.Runtime.Notes.MutationFingerprint,
        fingerprint_secret: :binary.copy(<<0xD8>>, 32)
    }

    mutation_id = Ecto.UUID.generate()

    attrs = %{
      mutation_id: mutation_id,
      expected_current_version_id: note.initial_version_id
    }

    before = mutation_surfaces(note, mutation_id)
    assert {:ok, true} = Delete.run(runtime, note_session, note.resource_id, attrs)
    after_first = mutation_surfaces(note, mutation_id)

    assert %{
             deleted_at: %DateTime{},
             versions: versions,
             receipts: 1,
             audits: 1,
             outbox: 1
           } = after_first

    assert versions == before.versions

    assert {:ok, true} = Delete.run(runtime, note_session, note.resource_id, attrs)
    assert mutation_surfaces(note, mutation_id) == after_first
  end

  defp read_operations(runtime, principal_session, context) do
    [
      Search.run(runtime, principal_session, %{}),
      Get.run(runtime, principal_session, context.resource_id),
      Get.version(runtime, principal_session, context.resource_id, context.competing_id),
      Get.conflict(runtime, principal_session, context.resource_id, context.conflict_id),
      History.run(runtime, principal_session, context.resource_id, %{limit: 20, cursor: nil}),
      Trash.run(runtime, principal_session, %{limit: 20, cursor: nil})
    ]
  end

  defp write_operations(runtime, principal_session, context) do
    [
      Create.run(runtime, principal_session, %{
        mutation_id: Ecto.UUID.generate(),
        title: "Create",
        markdown: "# Create"
      }),
      Save.run(runtime, principal_session, context.resource_id, %{
        mutation_id: Ecto.UUID.generate(),
        resource_id: context.resource_id,
        base_version_id: context.version_id,
        title: "Save",
        markdown: "# Save"
      }),
      Merge.run(runtime, principal_session, context.resource_id, %{
        mutation_id: Ecto.UUID.generate(),
        resource_id: context.resource_id,
        conflict_id: context.conflict_id,
        expected_current_version_id: context.version_id,
        competing_version_id: context.competing_id,
        title: "Merge",
        markdown: "# Merge"
      }),
      Delete.run(runtime, principal_session, context.resource_id, %{
        mutation_id: Ecto.UUID.generate(),
        expected_current_version_id: context.version_id
      }),
      Restore.run(runtime, principal_session, context.resource_id, %{
        mutation_id: Ecto.UUID.generate()
      })
    ]
  end

  defp create_principal!(vault_id, capabilities) do
    ids = %{
      person_id: Ecto.UUID.generate(),
      account_id: Ecto.UUID.generate(),
      credential_id: Ecto.UUID.generate(),
      principal_id: Ecto.UUID.generate(),
      session_id: Ecto.UUID.generate(),
      vault_id: load_uuid(vault_id)
    }

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "INSERT INTO identity.people (id, display_name) VALUES ($1, $2)", [
        dump!(ids.person_id),
        "Notes capability principal"
      ])

      query!(MigrationRepo, "INSERT INTO identity.accounts (id, person_id) VALUES ($1, $2)", [
        dump!(ids.account_id),
        dump!(ids.person_id)
      ])

      query!(
        MigrationRepo,
        "INSERT INTO identity.credentials (id, account_id, normalized_login, verifier) VALUES ($1, $2, $3, $4)",
        [
          dump!(ids.credential_id),
          dump!(ids.account_id),
          "notes-#{ids.principal_id}@example.test",
          "verifier"
        ]
      )

      query!(
        MigrationRepo,
        "INSERT INTO identity.principals (id, account_id, kind) VALUES ($1, $2, 'owner')",
        [dump!(ids.principal_id), dump!(ids.account_id)]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.vault_members (principal_id, vault_id) VALUES ($1, $2)",
        [dump!(ids.principal_id), vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO identity.sessions (
          id, account_id, credential_id, principal_id, vault_id, token_digest, expires_at
        ) VALUES ($1, $2, $3, $4, $5, $6, CURRENT_TIMESTAMP + interval '1 hour')
        """,
        [
          dump!(ids.session_id),
          dump!(ids.account_id),
          dump!(ids.credential_id),
          dump!(ids.principal_id),
          vault_id,
          :crypto.hash(:sha256, ids.session_id)
        ]
      )

      for capability <- capabilities do
        query!(
          MigrationRepo,
          """
          INSERT INTO core.principal_capabilities (principal_id, vault_id, capability_id)
          SELECT $1, $2, id FROM core.capabilities WHERE name = $3
          """,
          [dump!(ids.principal_id), vault_id, capability]
        )
      end
    end)

    ids
  end

  defp session(principal) do
    %{rows: [[principal_epoch, vault_epoch]]} =
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          """
          SELECT principal.authorization_epoch, vault.authorization_epoch
          FROM identity.principals AS principal
          JOIN core.vaults AS vault ON vault.id = $2
          WHERE principal.id = $1
          """,
          [dump!(principal.principal_id), dump!(principal.vault_id)]
        )
      end)

    %SessionContext{
      session_id: principal.session_id,
      account_id: principal.account_id,
      principal_id: principal.principal_id,
      vault_id: principal.vault_id,
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second),
      principal_authorization_epoch: principal_epoch,
      vault_authorization_epoch: vault_epoch,
      authorization_epoch: principal_epoch,
      unlocked?: true
    }
  end

  defp revoke_capability!(principal, capability) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE core.principal_capabilities AS assignment
        SET revoked_at = CURRENT_TIMESTAMP
        FROM core.capabilities AS capability
        WHERE assignment.capability_id = capability.id
          AND assignment.principal_id = $1
          AND assignment.vault_id = $2
          AND capability.name = $3
        """,
        [dump!(principal.principal_id), dump!(principal.vault_id), capability]
      )
    end)
  end

  defp grant_capability!(principal, capability) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.principal_capabilities (principal_id, vault_id, capability_id)
        SELECT $1, $2, capability.id
        FROM core.capabilities AS capability
        WHERE capability.name = $3
        ON CONFLICT (principal_id, vault_id, capability_id)
        DO UPDATE SET revoked_at = NULL
        """,
        [dump!(principal.principal_id), dump!(principal.vault_id), capability]
      )
    end)
  end

  defp increment_principal_epoch!(principal_id) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE identity.principals SET authorization_epoch = authorization_epoch + 1 WHERE id = $1",
        [dump!(principal_id)]
      )
    end)
  end

  defp increment_vault_epoch!(vault_id) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE core.vaults SET authorization_epoch = authorization_epoch + 1 WHERE id = $1",
        [dump!(vault_id)]
      )
    end)
  end

  defp mutation_surfaces(note, mutation_id) do
    Fixtures.with_owner(fn ->
      %{rows: [[deleted_at, versions, receipts, audits, outbox]]} =
        query!(
          MigrationRepo,
          """
          SELECT
            resource.deleted_at,
            (SELECT count(*) FROM content.resource_versions WHERE resource_id = resource.id),
            (
              SELECT count(*) FROM content.note_mutation_receipts
              WHERE vault_id = resource.vault_id AND mutation_id = $2
            ),
            (
              SELECT count(*) FROM audit.events
              WHERE vault_id = resource.vault_id
                AND target_id = resource.id
                AND operation = 'note.delete'
            ),
            (
              SELECT count(*) FROM core.outbox_events
              WHERE vault_id = resource.vault_id AND causation_id = $2
            )
          FROM content.resources AS resource
          WHERE resource.id = $1
          """,
          [dump!(note.resource_id), dump!(mutation_id)]
        )

      %{
        deleted_at: deleted_at,
        versions: versions,
        receipts: receipts,
        audits: audits,
        outbox: outbox
      }
    end)
  end

  defp canonical_row(vault_id, resource_id, version_id) do
    %{
      resource_id: resource_id,
      resource_version_id: version_id,
      vault_id: vault_id,
      classification: :private,
      title: "Authorized note",
      markdown: "# Authorized note",
      revision: 1,
      updated_at: ~U[2026-08-18 09:00:00.000000Z],
      deleted_at: nil,
      deleted?: false,
      created_by_principal_id: Process.get(:auth_note_principal, Ecto.UUID.generate()),
      inserted_at: ~U[2026-08-18 08:00:00.000000Z],
      parent_version_id: Ecto.UUID.generate(),
      merge_parent_version_id: nil,
      canonical?: true,
      open_conflict_count: 0
    }
  end

  defp version_row(vault_id, resource_id, version_id, parent_id) do
    %{
      resource_id: resource_id,
      resource_version_id: version_id,
      vault_id: vault_id,
      classification: :private,
      title: "Competing note",
      markdown: "# Competing note",
      revision: 2,
      created_by_principal_id: Ecto.UUID.generate(),
      inserted_at: ~U[2026-08-18 08:30:00.000000Z],
      parent_version_id: parent_id,
      merge_parent_version_id: nil,
      canonical?: false,
      conflict_state: :open
    }
  end

  defp dump!(uuid), do: Ecto.UUID.dump!(uuid)
  defp load_uuid(uuid), do: Ecto.UUID.load!(uuid)
end
