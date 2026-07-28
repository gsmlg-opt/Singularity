defmodule Singularity.Storage.AuditTest do
  use ExUnit.Case, async: true

  alias Singularity.Storage.Schema.Audit.Event

  @fingerprint :crypto.hash(:sha256, "anonymous-login")
  @secret_canaries %{
    "password" => "CANARY_PASSWORD_8e4a",
    "audit_fingerprint_secret" => "CANARY_AUDIT_FINGERPRINT_SECRET_32B",
    "upload_token" => "CANARY_UPLOAD_TOKEN_6b21",
    "csrf" => "CANARY_CSRF_c091",
    "vault_key" => "CANARY_VAULT_KEY_d112",
    "domain_key" => "CANARY_DOMAIN_KEY_a477",
    "domain_dedup_key" => "CANARY_DOMAIN_DEDUP_KEY_b579",
    "dek" => "CANARY_DEK_f862",
    "backup_passphrase" => "CANARY_BACKUP_1d0c"
  }

  test "append changeset accepts exactly the principal actor shape" do
    assert %{valid?: true} =
             changeset(%{
               actor_kind: :principal,
               principal_id: Ecto.UUID.generate(),
               vault_id: Ecto.UUID.generate()
             })

    for overlap <- [
          %{anonymous_fingerprint: @fingerprint},
          %{system_principal_name: "singularity.dispatcher"}
        ] do
      refute Map.merge(principal_actor(), overlap) |> changeset() |> Map.fetch!(:valid?)
    end
  end

  test "append changeset accepts exactly the named system actor shape" do
    assert changeset =
             changeset(%{
               actor_kind: :system,
               system_principal_name: "singularity.dispatcher",
               vault_id: Ecto.UUID.generate()
             })

    assert changeset.valid?

    for overlap <- [
          %{principal_id: Ecto.UUID.generate()},
          %{anonymous_fingerprint: @fingerprint}
        ] do
      attrs =
        Map.merge(
          %{
            actor_kind: :system,
            system_principal_name: "singularity.dispatcher",
            vault_id: Ecto.UUID.generate()
          },
          overlap
        )

      refute changeset(attrs).valid?
    end
  end

  test "append changeset accepts exactly the anonymous actor shape" do
    assert %{valid?: true} =
             changeset(%{
               actor_kind: :anonymous,
               anonymous_fingerprint: @fingerprint
             })

    for overlap <- [
          %{vault_id: Ecto.UUID.generate()},
          %{principal_id: Ecto.UUID.generate()},
          %{system_principal_name: "singularity.dispatcher"}
        ] do
      refute Map.merge(
               %{actor_kind: :anonymous, anonymous_fingerprint: @fingerprint},
               overlap
             )
             |> changeset()
             |> Map.fetch!(:valid?)
    end

    refute changeset(%{actor_kind: :anonymous, anonymous_fingerprint: "short"}).valid?
  end

  test "append changeset requires result, correlation, timestamp, and redacted target" do
    for field <- [:result, :correlation_id, :occurred_at, :target_type, :target_id] do
      attrs = Map.put(valid_attrs(principal_actor()), field, nil)
      refute Event.append_changeset(%Event{}, attrs).valid?
    end
  end

  test "append changeset rejects omitted result and target fields" do
    for field <- [:result, :target_type, :target_id] do
      attrs =
        principal_actor()
        |> valid_attrs()
        |> Map.delete(field)

      refute Event.append_changeset(%Event{}, attrs).valid?
    end
  end

  test "append redacts every server-side secret class before persistence" do
    metadata =
      @secret_canaries
      |> Enum.with_index()
      |> Map.new(fn {{key, canary}, index} ->
        {key, %{"index" => index, "value" => canary}}
      end)
      |> Map.put("safe", "visible")

    attrs =
      principal_actor()
      |> valid_attrs()
      |> Map.put(:metadata, metadata)

    changeset = Event.append_changeset(%Event{}, attrs)

    assert changeset.valid?

    redacted = Ecto.Changeset.get_field(changeset, :metadata)
    assert redacted["safe"] == "visible"

    for {key, canary} <- @secret_canaries do
      assert redacted[key] == "[REDACTED]"
      refute inspect(redacted) =~ canary
    end
  end

  defp changeset(actor_attrs) do
    actor_attrs
    |> valid_attrs()
    |> then(&Event.append_changeset(%Event{}, &1))
  end

  defp valid_attrs(actor_attrs) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        operation: "asset.read",
        result: :completed,
        classification: :private,
        correlation_id: Ecto.UUID.generate(),
        target_type: "asset",
        target_id: Ecto.UUID.generate(),
        metadata: %{},
        occurred_at: DateTime.utc_now(:microsecond)
      },
      actor_attrs
    )
  end

  defp principal_actor do
    %{
      actor_kind: :principal,
      principal_id: Ecto.UUID.generate(),
      vault_id: Ecto.UUID.generate()
    }
  end
end
