defmodule Singularity.Storage.Postgres.VaultRepositoryTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Domains.Vaults
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Postgres.VaultRepository
  alias Singularity.Storage.ScopedRepo

  setup do
    %{one: fixture} = Fixtures.two_vaults!()
    fixture = load_ids(fixture)
    capability_id = Ecto.UUID.generate()

    Fixtures.with_owner(fn ->
      query!(
        Singularity.Storage.MigrationRepo,
        "INSERT INTO core.capabilities (id, name) VALUES ($1, 'assets.read') ON CONFLICT DO NOTHING",
        [Ecto.UUID.dump!(capability_id)]
      )

      %{rows: [[persisted_capability_id]]} =
        query!(
          Singularity.Storage.MigrationRepo,
          "SELECT id FROM core.capabilities WHERE name = 'assets.read'"
        )

      query!(
        Singularity.Storage.MigrationRepo,
        """
        INSERT INTO core.principal_capabilities (
          principal_id, vault_id, capability_id
        ) VALUES ($1, $2, $3)
        """,
        [
          Ecto.UUID.dump!(fixture.principal_id),
          Ecto.UUID.dump!(fixture.vault_id),
          persisted_capability_id
        ]
      )
    end)

    {:ok, fixture: fixture}
  end

  test "resolves live membership, exact capabilities, epoch, and lock state", %{fixture: fixture} do
    assert :ok =
             ScopedRepo.transact(
               RequestRepo,
               %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
               fn repo ->
                 Vaults.authorize(
                   %{repository: VaultRepository, context: repo},
                   %{
                     principal_id: fixture.principal_id,
                     vault_id: fixture.vault_id,
                     required_capability: "assets.read",
                     authorization_epoch: 0,
                     requires_unlocked?: false
                   }
                 )
               end
             )
  end

  test "malformed principal and vault UUIDs return invalid without querying", %{fixture: fixture} do
    invalid_uuids = [
      "not-a-uuid",
      <<0, 1>>,
      "warehouse worker",
      String.duplicate("x", 36)
    ]

    for field <- [:principal_id, :vault_id],
        invalid_uuid <- invalid_uuids do
      lookup =
        %{principal_id: fixture.principal_id, vault_id: fixture.vault_id}
        |> Map.put(field, invalid_uuid)

      assert {:error, %Error{code: :invalid}} =
               VaultRepository.resolve_authorization(RequestRepo, lookup)
    end
  end

  defp load_ids(fixture) do
    Map.new(fixture, fn
      {key, value}
      when key in [
             :account_id,
             :asset_id,
             :credential_id,
             :principal_id,
             :resource_id,
             :resource_version_id,
             :session_id,
             :vault_id
           ] ->
        {key, Ecto.UUID.load!(value)}

      pair ->
        pair
    end)
  end
end
