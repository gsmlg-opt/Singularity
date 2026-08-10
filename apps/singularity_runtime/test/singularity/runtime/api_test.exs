defmodule Singularity.Runtime.ApiTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Retrieval.AssetSearchPage
  alias Singularity.Runtime.Api
  alias Singularity.Runtime.DTO.AssetSummary
  alias Singularity.Runtime.DTO.BackupStatus
  alias Singularity.Runtime.DTO.SearchPage
  alias Singularity.Runtime.DTO.Session
  alias Singularity.Runtime.DTO.UploadGrant
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.Schema.Content.Asset, as: StoredAsset
  alias Singularity.Storage.Schema.Content.AssetStage

  @session_id "00000000-0000-4000-8000-000000000601"
  @account_id "00000000-0000-4000-8000-000000000602"
  @principal_id "00000000-0000-4000-8000-000000000603"
  @vault_id "00000000-0000-4000-8000-000000000604"
  @grant_id "00000000-0000-4000-8000-000000000605"
  @asset_id "00000000-0000-4000-8000-000000000606"
  @resource_version_id "00000000-0000-4000-8000-000000000607"
  @backup_operation_id "00000000-0000-4000-8000-000000000608"
  @other_backup_operation_id "00000000-0000-4000-8000-000000000609"
  @opaque_token :binary.copy(<<0xA7>>, 32)
  @upload_token :binary.copy(<<0xB8>>, 32)
  @csrf_token "csrf-token-issued-for-this-exact-grant"

  test "login returns an encoded cookie identifier separately from a complete safe DTO" do
    test_pid = self()

    api =
      api(
        login: fn attrs ->
          assert {:ok, _correlation_id} =
                   Ecto.UUID.cast(attrs.correlation_id)

          refute Map.has_key?(attrs, :request_id)
          send(test_pid, {:login, attrs})
          {:ok, %{opaque_token: @opaque_token, session: %{id: @session_id}}}
        end,
        resolve_session: fn @opaque_token -> {:ok, session_context(false)} end
      )

    assert {:ok, opaque_id, dto} =
             Api.login(api, %{
               login: "owner@example.test",
               password: "secret",
               source: "127.0.0.1",
               correlation_id: "not-a-uuid",
               request_id: "plug-request-id"
             })

    assert opaque_id == Base.url_encode64(@opaque_token, padding: false)
    assert dto.__struct__ == Session
    assert dto == session_dto(false)
    refute Map.has_key?(Map.from_struct(dto), :opaque_token)
    assert_receive {:login, %{login: "owner@example.test"}}
  end

  test "resolve, unlock, logout, and lower errors use only DTOs and stable atoms" do
    opaque_id = Base.url_encode64(@opaque_token, padding: false)
    test_pid = self()

    api =
      api(
        resolve_session: fn @opaque_token -> {:ok, session_context(false)} end,
        unlock: fn context, "password" ->
          send(test_pid, {:unlock, context})
          {:ok, SessionContext.unlocked(context)}
        end,
        logout: fn context ->
          send(test_pid, {:logout, context})
          :ok
        end
      )

    assert {:ok, locked} = Api.resolve_session(api, opaque_id)
    assert locked == session_dto(false)

    assert {:ok, unlocked} = Api.unlock(api, locked, "password")
    assert unlocked == session_dto(true)
    assert_receive {:unlock, %SessionContext{account_id: @account_id}}

    assert :ok = Api.logout(api, unlocked)
    assert_receive {:logout, %SessionContext{session_id: @session_id}}

    assert {:error, :unauthenticated} =
             Api.resolve_session(
               api(resolve_session: fn _token -> {:error, Error.new(:unauthenticated)} end),
               opaque_id
             )

    assert {:error, :invalid} = Api.resolve_session(api, "not-a-token")
  end

  test "list_assets normalizes retrieval values into exact runtime DTOs" do
    updated_at = ~U[2026-07-28 06:00:00.000000Z]

    page = %AssetSearchPage{
      items: [
        %{
          asset_id: @asset_id,
          resource_version_id: @resource_version_id,
          title: "Annual report",
          original_filename: "report.pdf",
          detected_media_type: "application/pdf",
          state: :ready,
          state_revision: 4,
          label: "private",
          progress: nil,
          failure: nil,
          updated_at: updated_at,
          vault_id: @vault_id
        }
      ],
      next_cursor: "next-page"
    }

    api = api(list_assets: fn _session, %{q: "report"} -> {:ok, page} end)

    assert {:ok, result} =
             Api.list_assets(api, session_dto(true), %{q: "report"})

    assert result.__struct__ == SearchPage
    assert result.next_cursor == "next-page"
    assert [summary] = result.items
    assert summary.__struct__ == AssetSummary

    assert Map.from_struct(summary) == %{
             id: @asset_id,
             resource_version_id: @resource_version_id,
             title: "Annual report",
             original_filename: "report.pdf",
             detected_media_type: "application/pdf",
             state: :ready,
             state_revision: 4,
             label: "private",
             progress: nil,
             failure: nil,
             updated_at: updated_at
           }
  end

  test "list_assets accepts the real pending search projection without inventing lifecycle values" do
    updated_at = ~U[2026-07-28 06:00:00.000000Z]

    page = %AssetSearchPage{
      items: [
        %{
          asset_id: @asset_id,
          resource_version_id: @resource_version_id,
          vault_id: @vault_id,
          classification: :sensitive,
          state: :uploaded,
          state_revision: 1,
          detected_media_type: nil,
          resource_title: "Pending report",
          original_filename: "report.pdf",
          failure: %{
            code: "storage_unavailable",
            retryable: true,
            operation: "asset_verify",
            attempt: 2
          },
          updated_at: updated_at
        }
      ],
      next_cursor: nil
    }

    api = api(list_assets: fn _session, %{} -> {:ok, page} end)

    assert {:ok,
            %SearchPage{
              items: [
                %AssetSummary{
                  id: @asset_id,
                  resource_version_id: @resource_version_id,
                  title: "Pending report",
                  original_filename: "report.pdf",
                  detected_media_type: nil,
                  state: :uploaded,
                  state_revision: 1,
                  label: "sensitive",
                  progress: nil,
                  failure: %{
                    code: "storage_unavailable",
                    retryable: true,
                    operation: "asset_verify",
                    attempt: 2
                  },
                  updated_at: ^updated_at
                }
              ],
              next_cursor: nil
            }} = Api.list_assets(api, session_dto(true), %{})
  end

  test "subscribe_assets validates a complete unlocked session and subscribes only its vault" do
    test_pid = self()

    api =
      api(
        subscribe_assets: fn vault_id ->
          send(test_pid, {:subscribe_assets, vault_id})
          :ok
        end
      )

    assert :ok = Api.subscribe_assets(api, session_dto(true))
    assert_receive {:subscribe_assets, @vault_id}

    assert {:error, :vault_locked} =
             Api.subscribe_assets(api, session_dto(false))

    invalid_session = %{session_dto(true) | principal_id: "not-a-uuid"}

    assert {:error, :integrity_failure} =
             Api.subscribe_assets(api, invalid_session)

    refute_receive {:subscribe_assets, _other_vault}
  end

  test "subscribe_assets requires live authorization before registry subscription" do
    test_pid = self()

    api =
      api(
        authorize_asset_subscription: fn context ->
          send(test_pid, {:authorize_asset_subscription, context})
          {:error, Error.new(:forbidden)}
        end,
        subscribe_assets: fn vault_id ->
          send(test_pid, {:subscribe_assets, vault_id})
          :ok
        end
      )

    assert {:error, :forbidden} =
             Api.subscribe_assets(api, session_dto(true))

    assert_receive {:authorize_asset_subscription,
                    %SessionContext{
                      principal_id: @principal_id,
                      vault_id: @vault_id,
                      unlocked?: true
                    }}

    refute_receive {:subscribe_assets, @vault_id}
  end

  test "asset_summary converts authorization context and emits one strict safe DTO" do
    test_pid = self()
    secret_canary = "ASSET_SUMMARY_SECRET_CANARY"
    updated_at = ~U[2026-07-28 06:00:00.000000Z]

    projection = %{
      asset_id: @asset_id,
      resource_version_id: @resource_version_id,
      vault_id: @vault_id,
      classification: :restricted,
      state: :processing,
      state_revision: 4,
      detected_media_type: "application/pdf",
      resource_title: "Annual report",
      original_filename: "annual.pdf",
      progress: %{kind: :indeterminate},
      failure: %{
        code: "storage_unavailable",
        retryable: true,
        operation: "asset_metadata",
        attempt: 2
      },
      updated_at: updated_at,
      storage_ref: secret_canary,
      wrapped_key: secret_canary
    }

    api =
      api(
        asset_summary: fn context, @asset_id ->
          send(test_pid, {:asset_summary, context})
          {:ok, projection}
        end
      )

    assert {:ok, %AssetSummary{} = summary} =
             Api.asset_summary(api, session_dto(true), @asset_id)

    assert_receive {:asset_summary,
                    %SessionContext{
                      vault_id: @vault_id,
                      principal_id: @principal_id,
                      unlocked?: true
                    }}

    assert Map.from_struct(summary) == %{
             id: @asset_id,
             resource_version_id: @resource_version_id,
             title: "Annual report",
             original_filename: "annual.pdf",
             detected_media_type: "application/pdf",
             state: :processing,
             state_revision: 4,
             label: "restricted",
             progress: %{kind: :indeterminate},
             failure: %{
               code: "storage_unavailable",
               retryable: true,
               operation: "asset_metadata",
               attempt: 2
             },
             updated_at: updated_at
           }

    refute Map.has_key?(Map.from_struct(summary), :vault_id)
    refute inspect(summary) =~ secret_canary
  end

  test "asset_summary fails closed on invalid input, cross-vault output, and stable errors" do
    test_pid = self()

    assert {:error, :invalid} =
             Api.asset_summary(
               api(
                 asset_summary: fn _context, _asset_id ->
                   send(test_pid, :asset_summary_called)
                   {:ok, %{}}
                 end
               ),
               session_dto(true),
               "not-a-uuid"
             )

    refute_received :asset_summary_called

    cross_vault =
      asset_projection(%{
        vault_id: "00000000-0000-4000-8000-000000000699"
      })

    assert {:error, :integrity_failure} =
             Api.asset_summary(
               api(asset_summary: fn _context, @asset_id -> {:ok, cross_vault} end),
               session_dto(true),
               @asset_id
             )

    assert {:error, :not_found} =
             Api.asset_summary(
               api(
                 asset_summary: fn _context, @asset_id ->
                   {:error, Error.new(:not_found)}
                 end
               ),
               session_dto(true),
               @asset_id
             )
  end

  test "retry_asset forwards the revision, maps accepted and stale, and publishes only accepted" do
    test_pid = self()

    accepted_api =
      api(
        retry_asset: fn context, @asset_id, 7 ->
          send(test_pid, {:retry_asset, context})
          {:ok, :accepted}
        end,
        publish_asset: fn vault_id, asset_id ->
          send(test_pid, {:publish_asset, vault_id, asset_id})
          raise "notification registry unavailable"
        end
      )

    assert {:ok, true} =
             Api.retry_asset(
               accepted_api,
               session_dto(false),
               @asset_id,
               7
             )

    assert_receive {:retry_asset,
                    %SessionContext{
                      principal_id: @principal_id,
                      vault_id: @vault_id
                    }}

    assert_receive {:publish_asset, @vault_id, @asset_id}

    stale_api =
      api(
        retry_asset: fn _context, @asset_id, 6 -> {:ok, :stale} end,
        publish_asset: fn _vault_id, _asset_id ->
          send(test_pid, :stale_published)
          :ok
        end
      )

    assert {:ok, false} =
             Api.retry_asset(stale_api, session_dto(false), @asset_id, 6)

    refute_receive :stale_published
  end

  test "delete_asset accepts only a bound tombstone result and preserves indistinguishable conflicts" do
    test_pid = self()
    secret_canary = "DELETE_RESULT_SECRET_CANARY"

    accepted_api =
      api(
        delete_asset: fn context, @asset_id, 4 ->
          send(test_pid, {:delete_asset, context})

          {:ok,
           %{
             id: @asset_id,
             state: :pending_delete,
             state_revision: 5,
             storage_ref: secret_canary
           }}
        end,
        publish_asset: fn vault_id, asset_id ->
          send(test_pid, {:delete_publish, vault_id, asset_id})
          :ok
        end
      )

    assert {:ok, true} =
             Api.delete_asset(
               accepted_api,
               session_dto(false),
               @asset_id,
               4
             )

    assert_receive {:delete_asset,
                    %SessionContext{
                      principal_id: @principal_id,
                      vault_id: @vault_id
                    }}

    assert_receive {:delete_publish, @vault_id, @asset_id}

    revision_conflict =
      Error.new(:conflict,
        details: %{reason: :state_revision_mismatch}
      )

    assert {:ok, false} =
             Api.delete_asset(
               api(
                 delete_asset: fn _context, @asset_id, 3 ->
                   {:error, revision_conflict}
                 end
               ),
               session_dto(false),
               @asset_id,
               3
             )

    assert {:error, :conflict} =
             Api.delete_asset(
               api(
                 delete_asset: fn _context, @asset_id, 2 ->
                   {:error, Error.new(:conflict)}
                 end
               ),
               session_dto(false),
               @asset_id,
               2
             )

    refute inspect({:ok, true}) =~ secret_canary
  end

  test "asset mutations reject malformed identifiers and revisions before durable work" do
    test_pid = self()

    config =
      api(
        retry_asset: fn _context, _asset_id, _revision ->
          send(test_pid, :retry_called)
          {:ok, :accepted}
        end,
        delete_asset: fn _context, _asset_id, _revision ->
          send(test_pid, :delete_called)
          {:ok, %{id: @asset_id, state: :pending_delete, state_revision: 1}}
        end
      )

    for {asset_id, revision} <- [
          {"not-a-uuid", 0},
          {@asset_id, -1},
          {@asset_id, "0"}
        ] do
      assert {:error, :invalid} =
               Api.retry_asset(
                 config,
                 session_dto(false),
                 asset_id,
                 revision
               )

      assert {:error, :invalid} =
               Api.delete_asset(
                 config,
                 session_dto(false),
                 asset_id,
                 revision
               )
    end

    refute_received :retry_called
    refute_received :delete_called
  end

  test "create_upload_grant keeps its reusable token outside the safe grant DTO and publishes only its canonical hint" do
    upload_token = Base.url_encode64(@upload_token, padding: false)
    test_pid = self()

    api =
      api(
        create_upload_grant: fn _session, %{filename: "report.pdf"}, csrf_token ->
          assert csrf_token == @csrf_token

          {:ok,
           %{
             grant_id: @grant_id,
             asset_id: @asset_id,
             filename: "report.pdf",
             byte_size: 12,
             declared_media_type: "application/pdf",
             classification: :private,
             expires_at: ~U[2026-07-28 06:05:00.000000Z],
             token: upload_token
           }}
        end,
        publish_asset: fn vault_id, asset_id ->
          send(test_pid, {:publish_asset, vault_id, asset_id})
          :ok
        end
      )

    assert {:ok, ^upload_token, grant} =
             Api.create_upload_grant(
               api,
               session_dto(true),
               %{filename: "report.pdf"},
               @csrf_token
             )

    assert grant.__struct__ == UploadGrant

    assert Map.from_struct(grant) == %{
             grant_id: @grant_id,
             asset_id: @asset_id,
             filename: "report.pdf",
             byte_size: 12,
             declared_media_type: "application/pdf",
             classification: :private,
             expires_at: ~U[2026-07-28 06:05:00.000000Z]
           }

    assert_receive {:publish_asset, @vault_id, @asset_id}
  end

  test "create_upload_grant never publishes a hint for a failed or malformed result" do
    test_pid = self()

    publish = fn vault_id, asset_id ->
      send(test_pid, {:publish_asset, vault_id, asset_id})
      :ok
    end

    for result <- [
          {:error, Error.new(:conflict)},
          {:ok, %{asset_id: @asset_id, token: "secret"}}
        ] do
      api =
        api(
          create_upload_grant: fn _session, _attrs, _csrf_token -> result end,
          publish_asset: publish
        )

      assert {:error, _stable} =
               Api.create_upload_grant(
                 api,
                 session_dto(true),
                 %{filename: "report.pdf"},
                 @csrf_token
               )
    end

    refute_received {:publish_asset, _, _}
  end

  test "cancel_upload_grant publishes only an exact cancelled staging asset" do
    test_pid = self()

    cancelled =
      api(
        cancel_upload_grant: fn context, @grant_id ->
          send(test_pid, {:cancel_upload_grant, context})

          {:ok,
           %{
             status: :cancelled,
             grant_id: @grant_id,
             asset_id: @asset_id,
             vault_id: @vault_id
           }}
        end,
        publish_asset: fn vault_id, asset_id ->
          send(test_pid, {:cancel_publish, vault_id, asset_id})
          :ok
        end
      )

    assert {:ok, true} =
             Api.cancel_upload_grant(cancelled, session_dto(false), @grant_id)

    assert_receive {:cancel_upload_grant,
                    %SessionContext{
                      session_id: @session_id,
                      principal_id: @principal_id,
                      vault_id: @vault_id
                    }}

    assert_receive {:cancel_publish, @vault_id, @asset_id}

    in_progress =
      api(
        cancel_upload_grant: fn _context, @grant_id ->
          {:ok,
           %{
             status: :in_progress,
             grant_id: @grant_id,
             asset_id: @asset_id,
             vault_id: @vault_id
           }}
        end,
        publish_asset: fn _vault_id, _asset_id ->
          send(test_pid, :in_progress_published)
          :ok
        end
      )

    assert {:ok, false} =
             Api.cancel_upload_grant(in_progress, session_dto(false), @grant_id)

    refute_received :in_progress_published

    for malformed_result <- [
          %{
            status: :cancelled,
            grant_id: @grant_id,
            asset_id: "wrong-vault-secret",
            vault_id: @vault_id
          },
          %{
            status: :cancelled,
            grant_id: "00000000-0000-4000-8000-000000000699",
            asset_id: @asset_id,
            vault_id: @vault_id
          },
          %{
            status: :cancelled,
            grant_id: @grant_id,
            asset_id: @asset_id,
            vault_id: "00000000-0000-4000-8000-000000000699"
          },
          %{
            status: :cancelled,
            grant_id: @grant_id,
            asset_id: @asset_id,
            vault_id: @vault_id,
            token: "secret"
          }
        ] do
      malformed =
        api(
          cancel_upload_grant: fn _context, @grant_id ->
            {:ok, malformed_result}
          end,
          publish_asset: fn _vault_id, _asset_id ->
            send(test_pid, :malformed_published)
            :ok
          end
        )

      assert {:error, :integrity_failure} =
               Api.cancel_upload_grant(malformed, session_dto(false), @grant_id)
    end

    assert {:error, :invalid} =
             Api.cancel_upload_grant(cancelled, session_dto(false), "not-a-uuid")

    refute_received :malformed_published
  end

  test "begin_upload digests credentials before descriptor custody and keeps them out of the handle" do
    test_pid = self()
    descriptor = upload_descriptor()

    api =
      api(
        load_upload_grant_descriptor: fn context, selector ->
          send(test_pid, {:descriptor, context, selector})
          {:ok, descriptor}
        end,
        begin_upload: fn context, internal_grant, owner ->
          send(test_pid, {:begin_upload, context, internal_grant, owner})
          {:ok, make_ref()}
        end
      )

    request = %{
      upload_token: Base.url_encode64(@upload_token, padding: false),
      csrf_token: @csrf_token,
      content_length: 12,
      declared_media_type: "application/pdf"
    }

    assert {:ok, handle} =
             Api.begin_upload(
               api,
               session_dto(true),
               @grant_id,
               request,
               self()
             )

    assert_receive {:descriptor, %SessionContext{}, selector}
    assert selector.grant_id == @grant_id
    assert selector.session_id == @session_id
    assert selector.principal_id == @principal_id
    assert selector.vault_id == @vault_id
    assert selector.token_digest == :crypto.hash(:sha256, @upload_token)
    assert selector.csrf_token_digest == :crypto.hash(:sha256, @csrf_token)
    assert selector.request_content_length == 12
    assert selector.request_declared_media_type == "application/pdf"
    refute Map.has_key?(selector, :upload_token)
    refute Map.has_key?(selector, :csrf_token)

    assert_receive {:begin_upload, %SessionContext{}, internal, owner}
    assert owner == self()
    assert internal.token_digest == :crypto.hash(:sha256, @upload_token)
    assert internal.csrf_token_digest == :crypto.hash(:sha256, @csrf_token)
    assert internal.request_content_length == 12
    assert internal.request_declared_media_type == "application/pdf"
    refute Map.has_key?(internal, :upload_token)
    refute Map.has_key?(internal, :csrf_token)

    inspected = inspect(handle)
    refute inspected =~ request.upload_token
    refute inspected =~ @csrf_token
  end

  test "upload seam appends the final chunk and end is idempotent abandonment cleanup" do
    test_pid = self()

    api =
      api(
        append_upload: fn handle, chunk ->
          send(test_pid, {:append, handle, chunk})
          :ok
        end,
        finish_upload: fn handle ->
          send(test_pid, {:finish, handle})

          {:ok,
           %{
             asset: %StoredAsset{
               id: @asset_id,
               vault_id: @vault_id,
               state: :uploaded,
               state_revision: 1
             },
             stage: %AssetStage{
               asset_id: @asset_id,
               vault_id: @vault_id,
               state: :sealed,
               state_revision: 1
             }
           }}
        end,
        abandon_upload: fn handle, reason ->
          send(test_pid, {:abandon, handle, reason})
          :ok
        end
      )

    handle = Api.upload_handle(make_ref(), @vault_id, @asset_id)

    assert :ok = Api.append_upload(api, handle, "first")

    assert {:ok, %{asset_id: @asset_id}} =
             Api.finish_upload(api, handle, "last")

    assert_receive {:append, _, "first"}
    assert_receive {:append, _, "last"}
    assert_receive {:finish, _}

    assert :ok = Api.end_upload(api, handle)
    assert :ok = Api.end_upload(api, handle)
    assert_receive {:abandon, _, :controller_ended}
    assert_receive {:abandon, _, :controller_ended}
  end

  test "finish_upload publishes exactly the persisted asset identity and returns only a safe response" do
    secret_canary = "WRAPPED_STAGE_KEY_CANARY"
    test_pid = self()

    api =
      api(
        finish_upload: fn _handle ->
          {:ok,
           %{
             asset: %StoredAsset{
               id: @asset_id,
               vault_id: @vault_id,
               state: :uploaded,
               state_revision: 1
             },
             stage: %AssetStage{
               asset_id: @asset_id,
               vault_id: @vault_id,
               state: :sealed,
               state_revision: 1,
               dek_wrapper: secret_canary
             }
           }}
        end,
        publish_asset: fn vault_id, asset_id ->
          send(test_pid, {:publish_asset, vault_id, asset_id})
          raise "notification registry unavailable"
        end
      )

    handle = Api.upload_handle(make_ref(), @vault_id, @asset_id)

    assert {:ok, result} = Api.finish_upload(api, handle, "")

    assert result == %{
             asset_id: @asset_id,
             state: :uploaded,
             state_revision: 1
           }

    assert_receive {:publish_asset, @vault_id, @asset_id}
    refute_receive {:publish_asset, _, _}
    refute inspect(result) =~ secret_canary
    refute Map.has_key?(result, :vault_id)
    refute Map.has_key?(result, :stage)
  end

  test "finish_upload rejects a durable identity different from the accepted upload grant" do
    test_pid = self()
    other_asset_id = "00000000-0000-4000-8000-000000000608"
    other_vault_id = "00000000-0000-4000-8000-000000000609"

    begin_api =
      api(
        load_upload_grant_descriptor: fn _context, _selector ->
          {:ok, upload_descriptor()}
        end,
        begin_upload: fn _context, _internal_grant, _owner ->
          {:ok, make_ref()}
        end
      )

    assert {:ok, handle} =
             Api.begin_upload(
               begin_api,
               session_dto(true),
               @grant_id,
               %{
                 upload_token: Base.url_encode64(@upload_token, padding: false),
                 csrf_token: @csrf_token,
                 content_length: 12,
                 declared_media_type: "application/pdf"
               },
               self()
             )

    for {asset_id, vault_id} <- [
          {other_asset_id, @vault_id},
          {@asset_id, other_vault_id}
        ] do
      finish_api =
        api(
          finish_upload: fn _upload ->
            {:ok,
             %{
               asset: %StoredAsset{
                 id: asset_id,
                 vault_id: vault_id,
                 state: :uploaded,
                 state_revision: 1
               },
               stage: %AssetStage{
                 asset_id: asset_id,
                 vault_id: @vault_id,
                 state: :sealed,
                 state_revision: 1
               }
             }}
          end,
          publish_asset: fn published_vault_id, published_asset_id ->
            send(test_pid, {:unexpected_publish, published_vault_id, published_asset_id})
            :ok
          end
        )

      assert {:error, :integrity_failure} = Api.finish_upload(finish_api, handle, "")
      refute_received {:unexpected_publish, _, _}
    end
  end

  test "finish_upload rejects a sealed stage bound to a foreign vault" do
    test_pid = self()
    other_vault_id = "00000000-0000-4000-8000-000000000609"

    finish_api =
      api(
        finish_upload: fn _upload ->
          {:ok,
           %{
             asset: %StoredAsset{
               id: @asset_id,
               vault_id: @vault_id,
               state: :uploaded,
               state_revision: 1
             },
             stage: %AssetStage{
               asset_id: @asset_id,
               vault_id: other_vault_id,
               state: :sealed,
               state_revision: 1
             }
           }}
        end,
        publish_asset: fn vault_id, asset_id ->
          send(test_pid, {:unexpected_publish, vault_id, asset_id})
          :ok
        end
      )

    handle = Api.upload_handle(make_ref(), @vault_id, @asset_id)

    assert {:error, :integrity_failure} = Api.finish_upload(finish_api, handle, "")
    refute_received {:unexpected_publish, _, _}
  end

  test "finish_upload never publishes failed or malformed durable results" do
    test_pid = self()

    publish = fn vault_id, asset_id ->
      send(test_pid, {:publish_asset, vault_id, asset_id})
      :ok
    end

    handle = Api.upload_handle(make_ref(), @vault_id, @asset_id)

    assert {:error, :conflict} =
             Api.finish_upload(
               api(
                 finish_upload: fn _handle ->
                   {:error, Error.new(:conflict)}
                 end,
                 publish_asset: publish
               ),
               handle,
               ""
             )

    assert {:error, :integrity_failure} =
             Api.finish_upload(
               api(
                 finish_upload: fn _handle ->
                   {:ok,
                    %{
                      asset: %StoredAsset{
                        id: @asset_id,
                        vault_id: "not-a-uuid",
                        state: :uploaded,
                        state_revision: 1
                      },
                      stage: %AssetStage{
                        asset_id: @asset_id,
                        vault_id: @vault_id,
                        state: :sealed,
                        state_revision: 1
                      }
                    }}
                 end,
                 publish_asset: publish
               ),
               handle,
               ""
             )

    refute_received {:publish_asset, _, _}
  end

  test "begin_upload fails closed if the descriptor leaks credential fields" do
    test_pid = self()

    for {field, value} <- [
          token: "RAW_TOKEN_CANARY",
          token_digest: :binary.copy(<<0xD1>>, 32)
        ] do
      api =
        api(
          load_upload_grant_descriptor: fn _context, _selector ->
            {:ok, Map.put(upload_descriptor(), field, value)}
          end,
          begin_upload: fn _session, _grant, _owner ->
            send(test_pid, :custody_started)
            {:ok, make_ref()}
          end
        )

      assert {:error, :integrity_failure} =
               Api.begin_upload(
                 api,
                 session_dto(true),
                 @grant_id,
                 %{
                   upload_token: Base.url_encode64(@upload_token, padding: false),
                   csrf_token: @csrf_token,
                   content_length: 12,
                   declared_media_type: "application/pdf"
                 },
                 self()
               )
    end

    refute_received :custody_started
  end

  test "begin_upload rejects a request above the configured maximum before descriptor lookup" do
    test_pid = self()

    api =
      api(
        max_upload_bytes: 11,
        load_upload_grant_descriptor: fn _context, _selector ->
          send(test_pid, :descriptor_loaded)
          {:ok, upload_descriptor()}
        end
      )

    assert {:error, :upload_too_large} =
             Api.begin_upload(
               api,
               session_dto(true),
               @grant_id,
               %{
                 upload_token: Base.url_encode64(@upload_token, padding: false),
                 csrf_token: @csrf_token,
                 content_length: 12,
                 declared_media_type: "application/pdf"
               },
               self()
             )

    refute_received :descriptor_loaded
  end

  test "begin_upload rejects an unsupported declared media type before descriptor lookup" do
    test_pid = self()

    api =
      api(
        load_upload_grant_descriptor: fn _context, _selector ->
          send(test_pid, :descriptor_loaded)
          {:ok, upload_descriptor()}
        end
      )

    assert {:error, :unsupported_media_type} =
             Api.begin_upload(
               api,
               session_dto(true),
               @grant_id,
               %{
                 upload_token: Base.url_encode64(@upload_token, padding: false),
                 csrf_token: @csrf_token,
                 content_length: 12,
                 declared_media_type: "text/plain"
               },
               self()
             )

    refute_received :descriptor_loaded
  end

  test "upload preflight conceals credentials but differentiates safe request mismatches" do
    request = %{
      upload_token: Base.url_encode64(@upload_token, padding: false),
      csrf_token: @csrf_token,
      content_length: 12,
      declared_media_type: "application/pdf"
    }

    mappings = [
      {Error.new(:not_found), :forbidden},
      {Error.new(:invalid, details: %{reason: "size_mismatch"}), :integrity_failure},
      {Error.new(:unsupported_media_type), :unsupported_media_type}
    ]

    for {lower_error, public_error} <- mappings do
      api =
        api(
          load_upload_grant_descriptor: fn _context, _selector ->
            {:error, lower_error}
          end
        )

      assert {:error, ^public_error} =
               Api.begin_upload(
                 api,
                 session_dto(true),
                 @grant_id,
                 request,
                 self()
               )
    end

    handle = Api.upload_handle(make_ref(), @vault_id, @asset_id)

    assert {:error, :upload_too_large} =
             Api.append_upload(
               api(
                 append_upload: fn _handle, _chunk ->
                   {:error, Error.new(:upload_too_large)}
                 end
               ),
               handle,
               "chunk"
             )

    assert {:error, :integrity_failure} =
             Api.append_upload(
               api(append_upload: fn _handle, _chunk -> {:error, :size_mismatch} end),
               handle,
               "chunk"
             )
  end

  test "download parses one closed range against authoritative total and exposes no path" do
    test_pid = self()

    api =
      api(
        download_descriptor: fn _session, @asset_id ->
          {:ok,
           %{
             plaintext_byte_size: 10,
             detected_media_type: "application/pdf",
             storage_ref: "must-not-escape"
           }}
        end,
        download: fn _session, @asset_id, range ->
          send(test_pid, {:download, range})
          {:ok, "plain"}
        end
      )

    assert {:ok, response} =
             Api.download(
               api,
               session_dto(true),
               @asset_id,
               "bytes=2-6"
             )

    assert response == %{
             status: 206,
             body: "plain",
             content_length: 5,
             content_range: "bytes 2-6/10",
             detected_media_type: "application/pdf"
           }

    assert_receive {:download, 2..6//1}
    refute Map.has_key?(response, :path)

    for range <- ["bytes=2-", "bytes=-5", "bytes=1-2,4-5", "bytes=10-11"] do
      assert {:error, :range_not_satisfiable} =
               Api.download(api, session_dto(true), @asset_id, range)
    end
  end

  test "request_backup creates only an operation identity then reads one safe status DTO" do
    test_pid = self()
    passphrase = "correct horse battery staple"

    api =
      api(
        request_backup: fn context, ^passphrase ->
          send(test_pid, {:request_backup, context})
          {:ok, %{operation_id: @backup_operation_id}}
        end,
        backup_status: fn context, @backup_operation_id ->
          send(test_pid, {:backup_status, context})
          {:ok, backup_status_record()}
        end
      )

    assert {:ok,
            %BackupStatus{
              operation_id: @backup_operation_id,
              status: :pending,
              requested_at: ~U[2026-08-10 08:00:00.000000Z],
              updated_at: ~U[2026-08-10 08:01:00.000000Z]
            } = dto} = Api.request_backup(api, session_dto(true), passphrase)

    assert_receive {:request_backup, %SessionContext{vault_id: @vault_id, unlocked?: true}}
    assert_receive {:backup_status, %SessionContext{vault_id: @vault_id, unlocked?: true}}

    assert Map.keys(Map.from_struct(dto)) |> Enum.sort() ==
             [:operation_id, :requested_at, :status, :updated_at]

    assert {:ok, ^dto} = Api.backup_status(api, session_dto(true), @backup_operation_id)
  end

  test "request_backup requires live authorization before invoking the secret-bearing request seam" do
    test_pid = self()
    passphrase = "preflight-passphrase-must-not-leak"

    denied_api =
      api(
        authorize_backup_request: fn %SessionContext{} = context ->
          send(test_pid, {:backup_preflight, context})

          {:error,
           Error.new(:forbidden,
             message: "preflight-internal-detail",
             details: %{secret: "preflight-internal-detail"}
           )}
        end,
        request_backup: fn _context, _passphrase ->
          send(test_pid, :unexpected_backup_request)
          {:ok, %{operation_id: @backup_operation_id}}
        end
      )

    assert {:error, :forbidden} =
             Api.request_backup(denied_api, session_dto(true), passphrase)

    assert_receive {:backup_preflight, %SessionContext{} = preflight_context}
    refute inspect(preflight_context) =~ passphrase
    refute_received :unexpected_backup_request

    order_key = {__MODULE__, make_ref()}
    record = fn step -> Process.put(order_key, Process.get(order_key, []) ++ [step]) end

    permitted_api =
      api(
        authorize_backup_request: fn %SessionContext{} ->
          record.(:preflight)
          :ok
        end,
        request_backup: fn %SessionContext{}, ^passphrase ->
          record.(:request)
          {:ok, %{operation_id: @backup_operation_id}}
        end,
        backup_status: fn %SessionContext{}, @backup_operation_id ->
          record.(:status)
          {:ok, backup_status_record()}
        end
      )

    assert {:ok, %BackupStatus{operation_id: @backup_operation_id}} =
             Api.request_backup(permitted_api, session_dto(true), passphrase)

    assert Process.delete(order_key) == [:preflight, :request, :status]

    missing_preflight = Map.delete(permitted_api, :authorize_backup_request)

    assert {:error, :invalid} =
             Api.request_backup(missing_preflight, session_dto(true), passphrase)

    refute Process.get(order_key)
  end

  test "backup facade validates unlocked sessions, passphrases, and operation UUIDs before seams" do
    test_pid = self()

    api =
      api(
        authorize_backup_request: fn _context ->
          send(test_pid, :authorize_backup_request_called)
          :ok
        end,
        request_backup: fn _context, _passphrase ->
          send(test_pid, :request_backup_called)
          {:ok, %{operation_id: @backup_operation_id}}
        end,
        backup_status: fn _context, _operation_id ->
          send(test_pid, :backup_status_called)
          {:ok, backup_status_record()}
        end
      )

    assert {:error, :vault_locked} =
             Api.request_backup(api, session_dto(false), "passphrase")

    assert {:error, :vault_locked} =
             Api.backup_status(api, session_dto(false), @backup_operation_id)

    for passphrase <- ["", nil, 42] do
      assert {:error, :invalid} =
               Api.request_backup(api, session_dto(true), passphrase)
    end

    for operation_id <- ["not-a-uuid", nil, 42] do
      assert {:error, :invalid} =
               Api.backup_status(api, session_dto(true), operation_id)
    end

    assert {:error, :invalid} = Api.request_backup(api, %{}, "passphrase")
    assert {:error, :invalid} = Api.backup_status(api, %{}, @backup_operation_id)

    for forged_datetime <- forged_datetimes() do
      invalid_session = %{session_dto(true) | expires_at: forged_datetime}

      assert {:error, :integrity_failure} =
               Api.request_backup(api, invalid_session, "passphrase")

      assert {:error, :integrity_failure} =
               Api.backup_status(api, invalid_session, @backup_operation_id)
    end

    refute_received :authorize_backup_request_called
    refute_received :request_backup_called
    refute_received :backup_status_called
  end

  test "request_backup rejects anything beyond one exact operation identity" do
    test_pid = self()

    for request_result <- [
          {:ok, %{id: @backup_operation_id}},
          {:ok, %{operation_id: "not-a-uuid"}},
          {:ok, %{operation_id: @backup_operation_id, destination_ref: "/secret/path"}},
          {:ok,
           %BackupStatus{
             operation_id: @backup_operation_id,
             status: :pending,
             requested_at: ~U[2026-08-10 08:00:00Z],
             updated_at: ~U[2026-08-10 08:01:00Z]
           }},
          {:ok, @backup_operation_id}
        ] do
      api =
        api(
          request_backup: fn _context, _passphrase -> request_result end,
          backup_status: fn _context, _operation_id ->
            send(test_pid, :unexpected_status_read)
            {:ok, backup_status_record()}
          end
        )

      assert {:error, :integrity_failure} =
               Api.request_backup(api, session_dto(true), "passphrase")

      refute_received :unexpected_status_read
    end
  end

  test "backup status accepts only persisted states, DateTimes, and exact bound identities" do
    for status <- [:pending, :waiting_for_backup_key, :copying, :sealed, :failed] do
      api =
        api(
          backup_status: fn _context, @backup_operation_id ->
            {:ok, %{backup_status_record() | status: status}}
          end
        )

      assert {:ok, %BackupStatus{status: ^status}} =
               Api.backup_status(api, session_dto(true), @backup_operation_id)
    end

    malformed =
      [
        %{backup_status_record() | operation_id: @other_backup_operation_id},
        %{backup_status_record() | vault_id: Ecto.UUID.generate()},
        %{backup_status_record() | status: "pending"},
        %{backup_status_record() | requested_at: ~N[2026-08-10 08:00:00]},
        %{backup_status_record() | updated_at: nil},
        Map.put(backup_status_record(), :destination_ref, "/secret/path"),
        %BackupStatus{
          operation_id: @backup_operation_id,
          status: :pending,
          requested_at: ~U[2026-08-10 08:00:00Z],
          updated_at: ~U[2026-08-10 08:01:00Z]
        }
      ] ++
        for forged_datetime <- forged_datetimes(),
            field <- [:requested_at, :updated_at] do
          Map.put(backup_status_record(), field, forged_datetime)
        end

    for status_result <- malformed do
      api =
        api(backup_status: fn _context, _operation_id -> {:ok, status_result} end)

      assert {:error, :integrity_failure} =
               Api.backup_status(api, session_dto(true), @backup_operation_id)
    end
  end

  test "backup facade preserves stable errors and contains missing, malformed, raised, and thrown seams" do
    for code <- Error.codes() do
      request_api =
        api(request_backup: fn _context, _passphrase -> {:error, Error.new(code)} end)

      assert {:error, ^code} =
               Api.request_backup(request_api, session_dto(true), "passphrase")

      status_api =
        api(backup_status: fn _context, _operation_id -> {:error, Error.new(code)} end)

      assert {:error, ^code} =
               Api.backup_status(status_api, session_dto(true), @backup_operation_id)
    end

    assert {:error, :invalid} =
             api([])
             |> Map.delete(:request_backup)
             |> Api.request_backup(session_dto(true), "passphrase")

    assert {:error, :invalid} =
             api([])
             |> Map.delete(:backup_status)
             |> Api.backup_status(session_dto(true), @backup_operation_id)

    for bad_request <- [
          fn _context, _passphrase -> {:error, %{secret: "internal"}} end,
          fn _context, _passphrase ->
            {:error, struct(Error, code: :not_a_public_error)}
          end,
          fn _context, _passphrase -> raise "internal" end,
          fn _context, _passphrase -> throw("internal") end
        ] do
      assert {:error, :storage_unavailable} =
               Api.request_backup(
                 api(request_backup: bad_request),
                 session_dto(true),
                 "passphrase"
               )
    end

    for bad_status <- [
          fn _context, _operation_id -> {:error, %{secret: "internal"}} end,
          fn _context, _operation_id -> raise "internal" end,
          fn _context, _operation_id -> throw("internal") end
        ] do
      assert {:error, :storage_unavailable} =
               Api.backup_status(
                 api(backup_status: bad_status),
                 session_dto(true),
                 @backup_operation_id
               )
    end
  end

  defp api(overrides) do
    defaults = %{
      abandon_upload: fn _handle, _reason -> :ok end,
      append_upload: fn _handle, _chunk -> :ok end,
      authorize_asset_subscription: fn _session -> :ok end,
      authorize_backup_request: fn _session -> :ok end,
      begin_upload: fn _session, _grant, _owner -> {:error, Error.new(:invalid)} end,
      asset_summary: fn _session, _asset_id -> {:error, Error.new(:not_found)} end,
      backup_status: fn _session, _operation_id -> {:error, Error.new(:not_found)} end,
      cancel_upload_grant: fn _session, _grant_id -> {:error, Error.new(:invalid)} end,
      create_upload_grant: fn _session, _attrs, _csrf -> {:error, Error.new(:invalid)} end,
      delete_asset: fn _session, _asset_id, _revision ->
        {:error, Error.new(:conflict)}
      end,
      download: fn _session, _asset_id, _range -> {:error, Error.new(:not_found)} end,
      download_descriptor: fn _session, _asset_id -> {:error, Error.new(:not_found)} end,
      finish_upload: fn _handle -> {:error, Error.new(:invalid)} end,
      list_assets: fn _session, _params ->
        {:ok, %AssetSearchPage{items: [], next_cursor: nil}}
      end,
      load_upload_grant_descriptor: fn _session, _selector ->
        {:error, Error.new(:not_found)}
      end,
      login: fn _attrs -> {:error, Error.new(:unauthenticated)} end,
      logout: fn _session -> :ok end,
      publish_asset: fn _vault_id, _asset_id -> :ok end,
      resolve_session: fn _token -> {:error, Error.new(:unauthenticated)} end,
      request_backup: fn _session, _passphrase -> {:error, Error.new(:invalid)} end,
      retry_asset: fn _session, _asset_id, _revision ->
        {:error, Error.new(:conflict)}
      end,
      subscribe_assets: fn _vault_id -> :ok end,
      unlock: fn _session, _password -> {:error, Error.new(:forbidden)} end
    }

    Map.merge(defaults, Map.new(overrides))
  end

  defp session_context(unlocked?) do
    %SessionContext{
      session_id: @session_id,
      account_id: @account_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      expires_at: ~U[2026-07-28 07:00:00.000000Z],
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      authorization_epoch: 7,
      unlocked?: unlocked?
    }
  end

  defp session_dto(unlocked?) do
    struct(Session, %{
      session_id: @session_id,
      account_id: @account_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      expires_at: ~U[2026-07-28 07:00:00.000000Z],
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      authorization_epoch: 7,
      unlocked?: unlocked?
    })
  end

  defp upload_descriptor do
    %{
      grant_id: @grant_id,
      asset_id: @asset_id,
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      filename: "report.pdf",
      byte_size: 12,
      declared_media_type: "application/pdf",
      idempotency_key: "upload-1",
      classification: :private,
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      expires_at: ~U[2026-07-28 06:05:00.000000Z]
    }
  end

  defp asset_projection(overrides) do
    Map.merge(
      %{
        asset_id: @asset_id,
        resource_version_id: @resource_version_id,
        vault_id: @vault_id,
        classification: :private,
        state: :ready,
        state_revision: 4,
        detected_media_type: "application/pdf",
        resource_title: "Annual report",
        original_filename: "annual.pdf",
        progress: nil,
        failure: nil,
        updated_at: ~U[2026-07-28 06:00:00.000000Z]
      },
      overrides
    )
  end

  defp backup_status_record do
    %{
      operation_id: @backup_operation_id,
      vault_id: @vault_id,
      status: :pending,
      requested_at: ~U[2026-08-10 08:00:00.000000Z],
      updated_at: ~U[2026-08-10 08:01:00.000000Z]
    }
  end

  defp forged_datetimes do
    canonical = ~U[2026-08-10 08:00:00.000000Z]

    [
      %{canonical | month: 13},
      %{canonical | month: 2, day: 30},
      %{canonical | utc_offset: 3_600},
      %{canonical | std_offset: 3_600},
      %{canonical | time_zone: "Etc/Forged", zone_abbr: "FORGED"},
      %{canonical | microsecond: :invalid},
      %{canonical | microsecond: {1, 7}},
      %{canonical | microsecond: {1_000_000, 6}}
    ]
  end
end
