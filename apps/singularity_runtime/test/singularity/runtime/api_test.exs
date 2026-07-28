defmodule Singularity.Runtime.ApiTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Retrieval.AssetSearchPage
  alias Singularity.Runtime.Api
  alias Singularity.Runtime.DTO.AssetSummary
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

  test "create_upload_grant keeps its reusable token outside the safe grant DTO" do
    upload_token = Base.url_encode64(@upload_token, padding: false)

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
               state: :uploaded,
               state_revision: 1
             },
             stage: %AssetStage{
               asset_id: @asset_id,
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

    handle = Api.upload_handle(make_ref())

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

  test "finish_upload normalizes the sealed repository result into a safe response" do
    secret_canary = "WRAPPED_STAGE_KEY_CANARY"

    api =
      api(
        finish_upload: fn _handle ->
          {:ok,
           %{
             asset: %StoredAsset{
               id: @asset_id,
               state: :uploaded,
               state_revision: 1
             },
             stage: %AssetStage{
               asset_id: @asset_id,
               state: :sealed,
               state_revision: 1,
               dek_wrapper: secret_canary
             }
           }}
        end
      )

    handle = Api.upload_handle(make_ref())

    assert {:ok, result} = Api.finish_upload(api, handle, "")

    assert result == %{
             asset_id: @asset_id,
             state: :uploaded,
             state_revision: 1
           }

    refute inspect(result) =~ secret_canary
    refute Map.has_key?(result, :stage)
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

    handle = Api.upload_handle(make_ref())

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

  defp api(overrides) do
    defaults = %{
      abandon_upload: fn _handle, _reason -> :ok end,
      append_upload: fn _handle, _chunk -> :ok end,
      begin_upload: fn _session, _grant, _owner -> {:error, Error.new(:invalid)} end,
      create_upload_grant: fn _session, _attrs, _csrf -> {:error, Error.new(:invalid)} end,
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
      resolve_session: fn _token -> {:error, Error.new(:unauthenticated)} end,
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
end
