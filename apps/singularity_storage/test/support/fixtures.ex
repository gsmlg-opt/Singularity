defmodule Singularity.Storage.Fixtures do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias Singularity.Storage.MigrationRepo

  def reset_bootstrap_state! do
    with_owner(fn ->
      SQL.query!(
        MigrationRepo,
        "TRUNCATE TABLE identity.people CASCADE",
        [],
        log: false
      )
    end)
  end

  def two_vaults! do
    with_owner(fn ->
      %{one: vault_fixture!("one"), two: vault_fixture!("two")}
    end)
  end

  def revoke_membership!(%{principal_id: principal_id, vault_id: vault_id}) do
    with_owner(fn ->
      SQL.query!(
        MigrationRepo,
        """
        UPDATE core.vault_members
        SET revoked_at = CURRENT_TIMESTAMP
        WHERE principal_id = $1 AND vault_id = $2
        """,
        [principal_id, vault_id],
        log: false
      )
    end)
  end

  def disable_account!(%{account_id: account_id}) do
    with_owner(fn ->
      SQL.query!(
        MigrationRepo,
        "UPDATE identity.accounts SET status = 'disabled' WHERE id = $1",
        [account_id],
        log: false
      )
    end)
  end

  def set_auth_limits!(login_max_attempts, source_max_attempts) do
    with_owner(fn ->
      SQL.query!(
        MigrationRepo,
        """
        UPDATE identity.security_settings
        SET
          login_max_attempts = $1,
          source_max_attempts = $2,
          updated_at = CURRENT_TIMESTAMP
        WHERE singleton
        """,
        [login_max_attempts, source_max_attempts],
        log: false
      )
    end)
  end

  def outbox_event!(fixture) do
    with_owner(fn ->
      event_id = uuid()
      correlation_id = uuid()

      SQL.query!(
        MigrationRepo,
        """
        INSERT INTO core.outbox_events (
          id,
          event_type,
          idempotency_key,
          vault_id,
          principal_id,
          required_capability,
          principal_authorization_epoch,
          vault_authorization_epoch,
          classification,
          correlation_id,
          expected_entity_revision,
          envelope_version,
          payload,
          occurred_at
        ) VALUES (
          $1,
          'asset.verify_requested',
          $2,
          $3,
          $4,
          'asset.verify',
          7,
          23,
          'private',
          $5,
          0,
          1,
          $6::text::jsonb,
          CURRENT_TIMESTAMP
        )
        """,
        [
          event_id,
          "outbox-#{Ecto.UUID.generate()}",
          fixture.vault_id,
          fixture.principal_id,
          correlation_id,
          JSON.encode!(%{"asset_id" => Ecto.UUID.load!(fixture.asset_id)})
        ],
        log: false
      )

      %{id: event_id, correlation_id: correlation_id}
    end)
  end

  def with_owner(fun) do
    {:ok, pid} = MigrationRepo.start_link(pool_size: 2)

    try do
      {:ok, result} =
        MigrationRepo.transaction(fn ->
          SQL.query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner", [], log: false)
          fun.()
        end)

      result
    after
      Supervisor.stop(pid)
    end
  end

  defp vault_fixture!(label) do
    person_id = uuid()
    account_id = uuid()
    credential_id = uuid()
    principal_id = uuid()
    vault_id = uuid()
    resource_id = uuid()
    resource_version_id = uuid()
    asset_id = uuid()
    session_id = uuid()
    token = "session-token-#{label}-#{Ecto.UUID.generate()}"
    token_digest = :crypto.hash(:sha256, token)
    normalized_login = "#{label}-#{Ecto.UUID.generate()}@example.test"

    query!(
      "INSERT INTO identity.people (id, display_name) VALUES ($1, $2)",
      [person_id, "Person #{label}"]
    )

    query!(
      "INSERT INTO identity.accounts (id, person_id) VALUES ($1, $2)",
      [account_id, person_id]
    )

    query!(
      """
      INSERT INTO identity.credentials (
        id, account_id, normalized_login, verifier
      ) VALUES ($1, $2, $3, $4)
      """,
      [credential_id, account_id, normalized_login, "verifier-#{label}"]
    )

    query!(
      """
      INSERT INTO identity.principals (id, account_id, kind)
      VALUES ($1, $2, 'owner')
      """,
      [principal_id, account_id]
    )

    query!("INSERT INTO core.vaults (id) VALUES ($1)", [vault_id])

    query!(
      """
      INSERT INTO core.vault_members (principal_id, vault_id)
      VALUES ($1, $2)
      """,
      [principal_id, vault_id]
    )

    query!(
      """
      INSERT INTO content.resources (id, vault_id, classification, title)
      VALUES ($1, $2, 'private', $3)
      """,
      [resource_id, vault_id, "Resource #{label}"]
    )

    query!(
      """
      INSERT INTO content.resource_versions (
        id, resource_id, vault_id, classification, revision
      ) VALUES ($1, $2, $3, 'private', 0)
      """,
      [resource_version_id, resource_id, vault_id]
    )

    query!(
      """
      INSERT INTO content.assets (
        id, vault_id, resource_version_id, classification, state
      ) VALUES ($1, $2, $3, 'private', 'staging')
      """,
      [asset_id, vault_id, resource_version_id]
    )

    query!(
      """
      INSERT INTO identity.sessions (
        id,
        account_id,
        credential_id,
        principal_id,
        vault_id,
        token_digest,
        expires_at
      ) VALUES ($1, $2, $3, $4, $5, $6, CURRENT_TIMESTAMP + interval '1 hour')
      """,
      [session_id, account_id, credential_id, principal_id, vault_id, token_digest]
    )

    query!(
      """
      INSERT INTO content.asset_search_documents (
        asset_id,
        resource_version_id,
        vault_id,
        classification,
        state,
        resource_title,
        original_filename
      ) VALUES ($1, $2, $3, 'private', 'staging', $4, $5)
      """,
      [asset_id, resource_version_id, vault_id, "Resource #{label}", "#{label}.bin"]
    )

    %{
      account_id: account_id,
      asset_id: asset_id,
      credential_id: credential_id,
      normalized_login: normalized_login,
      principal_id: principal_id,
      resource_id: resource_id,
      resource_version_id: resource_version_id,
      session_id: session_id,
      token: token,
      token_digest: token_digest,
      vault_id: vault_id,
      verifier: "verifier-#{label}"
    }
  end

  defp query!(statement, parameters) do
    SQL.query!(MigrationRepo, statement, parameters, log: false)
  end

  defp uuid do
    Ecto.UUID.generate()
    |> Ecto.UUID.dump!()
  end
end
