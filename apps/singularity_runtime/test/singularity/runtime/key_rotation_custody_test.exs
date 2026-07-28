defmodule Singularity.Runtime.KeyRotationCustodyTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Storage.Crypto.KeyWrapper

  @session_id "session-rotation"
  @principal_id "principal-rotation"
  @vault_id "vault-rotation"
  @vault_key_version_id "vault-version-4"
  @next_vault_key_version_id "vault-version-5"
  @key_domain_id "domain-primary"
  @domain_key_version_id "domain-primary-version-5"
  @next_domain_key_version_id "domain-primary-version-6"
  @principal_authorization_epoch 7
  @vault_authorization_epoch 11

  @vault_key :binary.copy(<<0xA1>>, 32)
  @other_domain_key :binary.copy(<<0xB3>>, 32)
  @domain_key :binary.copy(<<0xB2>>, 32)
  @domain_dedup_key :binary.copy(<<0xD4>>, 32)
  @object_dek_one :binary.copy(<<0xC1>>, 32)
  @object_dek_two :binary.copy(<<0xC2>>, 32)
  @vault_kek :binary.copy(<<0xE1>>, 32)
  @next_key :binary.copy(<<0xF1>>, 32)

  defmodule VerificationFailingWrapper do
    use Agent

    alias Singularity.Core.Error
    alias Singularity.Storage.Crypto.KeyWrapper

    def start_link(_options) do
      Agent.start_link(fn -> MapSet.new() end)
    end

    def wrap(agent, wrapping_key, raw_key, metadata) do
      case KeyWrapper.wrap(wrapping_key, raw_key, metadata) do
        {:ok, %{encoded: encoded}} = result ->
          Agent.update(agent, &MapSet.put(&1, encoded))
          result

        error ->
          error
      end
    end

    def unwrap(agent, wrapping_key, encoded, metadata) do
      if Agent.get(agent, &MapSet.member?(&1, encoded)) and
           metadata == %{
             purpose: :object_dek,
             generation: 6,
             aad: "object:object-two"
           } do
        {:error, Error.new(:integrity_failure)}
      else
        KeyWrapper.unwrap(wrapping_key, encoded, metadata)
      end
    end
  end

  setup do
    owner = self()

    custodian =
      start_custodian!(fn 32 ->
        send(owner, {:random_bytes, 32})
        @next_key
      end)

    assert :ok = activate!(custodian, unlocked_session())

    {:ok, custodian: custodian}
  end

  test "vault preparation verifies the password wrapper and rewraps every active domain",
       %{custodian: custodian} do
    request = vault_rotation_request()

    assert {:ok, plan} =
             KeyCustodian.prepare_vault_rotation(custodian, request)

    assert %{
             next_vault_key_version_id: @next_vault_key_version_id,
             next_vault_key_version_generation: 4,
             next_vault_wrapper_generation: 10,
             vault_wrapper: %{
               generation: 10,
               algorithm: "aes_256_gcm",
               wrapped_key: wrapped_vault_key
             },
             domain_versions: rewrapped_domains
           } = plan

    assert length(rewrapped_domains) == 2

    assert {:ok, @next_key} =
             KeyWrapper.unwrap(@vault_kek, wrapped_vault_key, %{
               purpose: :vault_key,
               generation: 10,
               aad: @vault_id
             })

    assert_rewrapped_domain!(
      rewrapped_domains,
      @key_domain_id,
      @domain_key_version_id,
      5,
      @domain_key,
      hd(request.active_domain_versions).wrapped_key
    )

    secondary = List.last(request.active_domain_versions)

    assert_rewrapped_domain!(
      rewrapped_domains,
      "domain-secondary",
      "domain-secondary-version-8",
      8,
      @other_domain_key,
      secondary.wrapped_key
    )

    assert {:error, %Error{code: :integrity_failure}} =
             KeyWrapper.unwrap(@vault_kek, wrapped_vault_key, %{
               purpose: :vault_key,
               generation: 10,
               aad: @vault_id <> "-wrong"
             })

    assert_received {:random_bytes, 32}
    refute_receive {:random_bytes, _size}
    refute_raw_keys(plan)
  end

  test "vault preparation fails closed on a wrong KEK or incomplete active-domain entry",
       %{custodian: custodian} do
    request = vault_rotation_request()

    assert {:error, %Error{code: :integrity_failure}} =
             KeyCustodian.prepare_vault_rotation(
               custodian,
               %{request | vault_kek: :binary.copy(<<0xEE>>, 32)}
             )

    assert {:error, %Error{code: :invalid}} =
             KeyCustodian.prepare_vault_rotation(
               custodian,
               %{request | next_vault_key_version_generation: 5}
             )

    assert {:error, %Error{code: :invalid}} =
             KeyCustodian.prepare_vault_rotation(
               custodian,
               %{request | next_vault_wrapper_generation: 11}
             )

    [first | rest] = request.active_domain_versions
    incomplete = Map.delete(first, :wrapped_key)

    assert {:error, %Error{code: :invalid}} =
             KeyCustodian.prepare_vault_rotation(
               custodian,
               %{request | active_domain_versions: [incomplete | rest]}
             )

    assert {:error, %Error{code: :invalid}} =
             KeyCustodian.prepare_vault_rotation(
               custodian,
               %{request | active_domain_versions: [first | :improper]}
             )

    corrupt = %{first | wrapped_key: "not-an-authenticated-wrapper"}

    assert {:error, %Error{code: :integrity_failure}} =
             KeyCustodian.prepare_vault_rotation(
               custodian,
               %{request | active_domain_versions: [corrupt | rest]}
             )

    duplicate = %{List.last(rest) | id: first.id}

    assert {:error, %Error{code: :invalid}} =
             KeyCustodian.prepare_vault_rotation(
               custodian,
               %{request | active_domain_versions: [first, duplicate]}
             )

    refute_receive {:random_bytes, _size}
    assert Process.alive?(custodian)
  end

  test "vault preparation requires the exact unlocked-session binding",
       %{custodian: custodian} do
    request = vault_rotation_request()

    for changed <- [
          %{request | session_id: "different-session"},
          %{request | principal_id: "different-principal"},
          %{request | vault_id: "different-vault"},
          %{request | principal_authorization_epoch: 8},
          %{request | vault_authorization_epoch: 12}
        ] do
      assert {:error, %Error{}} =
               KeyCustodian.prepare_vault_rotation(custodian, changed)
    end

    refute_receive {:random_bytes, _size}
  end

  test "domain preparation verifies retained hierarchy and rewraps every supplied envelope",
       %{custodian: custodian} do
    request = domain_rotation_request()

    assert {:ok, plan} =
             KeyCustodian.prepare_domain_rotation(custodian, request)

    assert %{
             next_domain_key_version_id: @next_domain_key_version_id,
             next_domain_key_generation: 6,
             domain_wrapper: %{
               vault_key_version_id: @vault_key_version_id,
               algorithm: "aes_256_gcm",
               wrapped_key: wrapped_domain_key
             },
             dedup_wrapper: %{
               algorithm: "aes_256_gcm",
               wrapped_key: wrapped_dedup_key
             },
             asset_envelopes: rewrapped_envelopes
           } = plan

    assert {:ok, @next_key} =
             KeyWrapper.unwrap(@vault_key, wrapped_domain_key, %{
               purpose: :domain_key,
               generation: 6,
               aad: @vault_id <> ":" <> @key_domain_id
             })

    assert {:ok, @domain_dedup_key} =
             KeyWrapper.unwrap(@next_key, wrapped_dedup_key, %{
               purpose: :domain_dedup_key,
               generation: 6,
               aad: @key_domain_id
             })

    assert_rewrapped_envelope!(
      rewrapped_envelopes,
      "envelope-one",
      "object-one",
      @object_dek_one
    )

    assert_rewrapped_envelope!(
      rewrapped_envelopes,
      "envelope-two",
      "object-two",
      @object_dek_two
    )

    assert_received {:random_bytes, 32}
    refute_receive {:random_bytes, _size}
    refute_raw_keys(plan)
  end

  test "domain preparation fails closed on malformed, duplicate, or corrupt envelopes",
       %{custodian: custodian} do
    request = domain_rotation_request()
    [first, second] = request.active_asset_envelopes

    assert {:error, %Error{code: :integrity_failure}} =
             KeyCustodian.prepare_domain_rotation(
               custodian,
               %{
                 request
                 | current_domain_wrapper:
                     Map.put(
                       request.current_domain_wrapper,
                       :wrapped_key,
                       "not-an-authenticated-wrapper"
                     )
               }
             )

    assert {:error, %Error{code: :integrity_failure}} =
             KeyCustodian.prepare_domain_rotation(
               custodian,
               %{
                 request
                 | current_dedup_wrapper:
                     Map.put(
                       request.current_dedup_wrapper,
                       :wrapped_key,
                       "not-an-authenticated-wrapper"
                     )
               }
             )

    assert {:error, %Error{code: :invalid}} =
             KeyCustodian.prepare_domain_rotation(
               custodian,
               %{request | active_asset_envelopes: [Map.delete(first, :wrapped_dek), second]}
             )

    assert {:error, %Error{code: :invalid}} =
             KeyCustodian.prepare_domain_rotation(
               custodian,
               %{request | active_asset_envelopes: [first | :improper]}
             )

    duplicate = %{second | id: first.id}

    assert {:error, %Error{code: :invalid}} =
             KeyCustodian.prepare_domain_rotation(
               custodian,
               %{request | active_asset_envelopes: [first, duplicate]}
             )

    corrupt = %{second | wrapped_dek: "not-an-authenticated-wrapper"}

    assert {:error, %Error{code: :integrity_failure}} =
             KeyCustodian.prepare_domain_rotation(
               custodian,
               %{request | active_asset_envelopes: [first, corrupt]}
             )

    mismatched_cached =
      start_custodian!(fn 32 -> @next_key end)

    assert :ok =
             activate!(
               mismatched_cached,
               unlocked_session(object_keys: %{{"object-one", 5} => :binary.copy(<<0xCC>>, 32)})
             )

    assert {:error, %Error{code: :integrity_failure}} =
             KeyCustodian.prepare_domain_rotation(
               mismatched_cached,
               request
             )

    refute_receive {:random_bytes, _size}
    assert Process.alive?(custodian)
  end

  test "every newly produced wrapper is verified before a plan is returned" do
    wrapper = start_supervised!({VerificationFailingWrapper, []}, id: make_ref())

    custodian =
      start_custodian!(
        fn 32 -> @next_key end,
        key_wrapper: {VerificationFailingWrapper, wrapper}
      )

    assert :ok = activate!(custodian, unlocked_session())

    assert {:error, %Error{code: :integrity_failure}} =
             KeyCustodian.prepare_domain_rotation(
               custodian,
               domain_rotation_request()
             )

    assert Process.alive?(custodian)
  end

  defp start_custodian!(random_bytes, overrides \\ []) do
    options =
      %{
        authorization: __MODULE__,
        clock: __MODULE__,
        context: %{},
        idle_lock: nil,
        key_reader: __MODULE__,
        key_wrapper: KeyWrapper,
        lease_supervisor: self(),
        object_key_loader: __MODULE__,
        random_bytes: random_bytes
      }
      |> Map.merge(Map.new(overrides))

    start_supervised!(Supervisor.child_spec({KeyCustodian, options}, id: make_ref()))
  end

  defp activate!(custodian, session) do
    with {:ok, pending} <- KeyCustodian.prepare_unlock(custodian, session) do
      KeyCustodian.activate_unlock(custodian, pending)
    end
  end

  defp unlocked_session(overrides \\ []) do
    %{
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      principal_authorization_epoch: @principal_authorization_epoch,
      vault_authorization_epoch: @vault_authorization_epoch,
      vault_key: @vault_key,
      domain_key: @domain_key,
      domain_dedup_key: @domain_dedup_key,
      key_domain_id: @key_domain_id,
      domain_key_version_id: @domain_key_version_id,
      domain_key_generation: 5,
      domain_classification: :private,
      object_keys: %{{"object-one", 5} => @object_dek_one}
    }
    |> Map.merge(Map.new(overrides))
  end

  defp vault_rotation_request do
    %{
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      principal_authorization_epoch: @principal_authorization_epoch,
      vault_authorization_epoch: @vault_authorization_epoch,
      vault_kek: @vault_kek,
      current_vault_wrapper: %{
        vault_key_version_id: @vault_key_version_id,
        generation: 9,
        algorithm: "aes_256_gcm",
        wrapped_key: wrap!(@vault_kek, @vault_key, :vault_key, 9, @vault_id)
      },
      current_vault_key_version_generation: 3,
      next_vault_key_version_id: @next_vault_key_version_id,
      next_vault_key_version_generation: 4,
      next_vault_wrapper_generation: 10,
      active_domain_versions: [
        %{
          key_domain_id: @key_domain_id,
          id: @domain_key_version_id,
          generation: 5,
          algorithm: "aes_256_gcm",
          wrapped_key:
            wrap!(
              @vault_key,
              @domain_key,
              :domain_key,
              5,
              @vault_id <> ":" <> @key_domain_id
            )
        },
        %{
          key_domain_id: "domain-secondary",
          id: "domain-secondary-version-8",
          generation: 8,
          algorithm: "aes_256_gcm",
          wrapped_key:
            wrap!(
              @vault_key,
              @other_domain_key,
              :domain_key,
              8,
              @vault_id <> ":domain-secondary"
            )
        }
      ]
    }
  end

  defp domain_rotation_request do
    %{
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      principal_authorization_epoch: @principal_authorization_epoch,
      vault_authorization_epoch: @vault_authorization_epoch,
      key_domain_id: @key_domain_id,
      current_domain_wrapper: %{
        id: @domain_key_version_id,
        vault_key_version_id: @vault_key_version_id,
        generation: 5,
        algorithm: "aes_256_gcm",
        wrapped_key:
          wrap!(
            @vault_key,
            @domain_key,
            :domain_key,
            5,
            @vault_id <> ":" <> @key_domain_id
          )
      },
      current_dedup_wrapper: %{
        algorithm: "aes_256_gcm",
        wrapped_key:
          wrap!(
            @domain_key,
            @domain_dedup_key,
            :domain_dedup_key,
            5,
            @key_domain_id
          )
      },
      next_domain_key_version_id: @next_domain_key_version_id,
      next_domain_key_generation: 6,
      active_asset_envelopes: [
        %{
          id: "envelope-one",
          asset_object_id: "object-one",
          domain_key_version_id: @domain_key_version_id,
          classification: :private,
          algorithm: "aes_256_gcm",
          key_generation: 5,
          wrapped_dek:
            wrap!(
              @domain_key,
              @object_dek_one,
              :object_dek,
              5,
              "object:object-one"
            )
        },
        %{
          id: "envelope-two",
          asset_object_id: "object-two",
          domain_key_version_id: @domain_key_version_id,
          classification: :private,
          algorithm: "aes_256_gcm",
          key_generation: 5,
          wrapped_dek:
            wrap!(
              @domain_key,
              @object_dek_two,
              :object_dek,
              5,
              "object:object-two"
            )
        }
      ]
    }
  end

  defp assert_rewrapped_domain!(
         domains,
         key_domain_id,
         domain_key_version_id,
         generation,
         expected_key,
         expected_wrapped_key
       ) do
    assert %{
             id: ^domain_key_version_id,
             key_domain_id: ^key_domain_id,
             generation: ^generation,
             algorithm: "aes_256_gcm",
             expected_wrapped_key: ^expected_wrapped_key,
             wrapped_key: wrapped_key
           } =
             Enum.find(domains, &(&1.key_domain_id == key_domain_id))

    assert {:ok, ^expected_key} =
             KeyWrapper.unwrap(@next_key, wrapped_key, %{
               purpose: :domain_key,
               generation: generation,
               aad: @vault_id <> ":" <> key_domain_id
             })
  end

  defp assert_rewrapped_envelope!(
         envelopes,
         envelope_id,
         object_id,
         expected_dek
       ) do
    assert %{
             expected_envelope_id: ^envelope_id,
             asset_object_id: ^object_id,
             expected_key_generation: 5,
             classification: :private,
             key_generation: 6,
             algorithm: "aes_256_gcm",
             wrapped_dek: wrapped_dek
           } =
             Enum.find(
               envelopes,
               &(&1.expected_envelope_id == envelope_id)
             )

    assert {:ok, ^expected_dek} =
             KeyWrapper.unwrap(@next_key, wrapped_dek, %{
               purpose: :object_dek,
               generation: 6,
               aad: "object:" <> object_id
             })
  end

  defp wrap!(wrapping_key, raw_key, purpose, generation, aad) do
    assert {:ok, %{encoded: encoded}} =
             KeyWrapper.wrap(wrapping_key, raw_key, %{
               purpose: purpose,
               generation: generation,
               aad: aad
             })

    encoded
  end

  defp refute_raw_keys(plan) do
    raw_keys = [
      @vault_key,
      @domain_key,
      @other_domain_key,
      @domain_dedup_key,
      @object_dek_one,
      @object_dek_two,
      @vault_kek,
      @next_key
    ]

    refute Enum.any?(leaves(plan), &(&1 in raw_keys))
  end

  defp leaves(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&leaves/1)

  defp leaves(value) when is_list(value), do: Enum.flat_map(value, &leaves/1)
  defp leaves(value), do: [value]
end
