defmodule Singularity.Core.IdentityValuesTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Account
  alias Singularity.Core.Device
  alias Singularity.Core.Person
  alias Singularity.Core.Principal
  alias Singularity.Core.Session

  test "identity constructors preserve opaque string identifiers" do
    assert {:ok, %Person{person_id: "person/not-a-uuid"}} =
             Person.new(%{person_id: "person/not-a-uuid"})

    assert {:ok, %Account{account_id: "account-1", person_id: "person/not-a-uuid"}} =
             Account.new(%{account_id: "account-1", person_id: "person/not-a-uuid"})

    assert {:ok,
            %Principal{
              principal_id: "principal-1",
              kind: :owner,
              authorization_epoch: 0
            }} =
             Principal.new(%{
               principal_id: "principal-1",
               kind: :owner,
               authorization_epoch: 0
             })

    assert {:ok, %Device{device_id: "device-1", principal_id: "principal-1"}} =
             Device.new(%{device_id: "device-1", principal_id: "principal-1"})
  end

  test "sessions require a UTC expiration time" do
    assert {:ok, %Session{expires_at: ~U[2026-07-18 09:00:00Z]}} =
             Session.new(%{
               session_id: "session-1",
               account_id: "account-1",
               principal_id: "principal-1",
               expires_at: ~U[2026-07-18 09:00:00Z]
             })

    assert {:error, %{code: :invalid}} =
             Session.new(%{
               session_id: "session-1",
               account_id: "account-1",
               principal_id: "principal-1",
               expires_at: ~N[2026-07-18 09:00:00]
             })
  end

  test "identity values reject blank identifiers, negative epochs, and atom metadata keys" do
    assert {:error, %{code: :invalid}} = Person.new(%{person_id: ""})

    assert {:error, %{code: :invalid}} =
             Principal.new(%{
               principal_id: "principal-1",
               kind: :owner,
               authorization_epoch: -1
             })

    assert {:error, %{code: :invalid}} =
             Device.new(%{
               device_id: "device-1",
               principal_id: "principal-1",
               metadata: %{platform: "linux"}
             })
  end
end
