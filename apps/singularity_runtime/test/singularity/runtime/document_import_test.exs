defmodule Singularity.Runtime.DocumentImportTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{DocumentSource, DocumentVersion, Error}
  alias Singularity.Runtime.Api
  alias Singularity.Runtime.DTO.Session
  alias Singularity.Storage.Documents.PreparedSource

  @principal "00000000-0000-4000-8000-000000000101"
  @owner "00000000-0000-4000-8000-000000000102"
  @asset "00000000-0000-4000-8000-000000000103"
  @object "00000000-0000-4000-8000-000000000104"
  @source_resource "00000000-0000-4000-8000-000000000105"
  @source_version "00000000-0000-4000-8000-000000000106"
  @mutation "00000000-0000-4000-8000-000000000107"

  defmodule Scope do
    def with_shared_request(owner, _runtime, session, requirement, callback) do
      send(owner, {:import_scope, session, requirement})

      case callback.(:scoped_repo) do
        {:after_commit, after_commit} -> after_commit.()
        result -> result
      end
    end

    def with_read_request(_owner, _runtime, _session, _requirement, callback),
      do: callback.(:scoped_repo)
  end

  defmodule Repository do
    def find_import_receipt_scoped(:scoped_repo, session, mutation_id) do
      send(self(), {:receipt_lookup, session.principal_id, session.vault_id, mutation_id})

      case Process.get(:import_receipt) do
        nil -> {:error, Error.new(:not_found)}
        document -> {:ok, document}
      end
    end

    def create_pending(context, command) do
      send(self(), {:create_pending, context, command})

      document = %DocumentVersion{
        resource_id: command.resource_id,
        resource_version_id: command.resource_version_id,
        owner_scope_id: command.owner_scope_id,
        classification: :private,
        revision: 0,
        source: command.source,
        title: command.title,
        created_by_principal_id: command.principal_id,
        inserted_at: command.inserted_at,
        state: :pending,
        generation: 0
      }

      Process.put(:import_receipt, document)
      {:ok, document}
    end
  end

  defmodule Prepare do
    def prepare(owner, context, %{context: session, asset_id: asset_id}) do
      send(owner, {:prepare, context.repo, asset_id})

      case Process.get(:import_media, "text/plain") do
        media when media in ["text/plain", "text/markdown", "application/pdf"] ->
          binding = %{byte_size: 19}

          with {:ok, %{sha256: digest, byte_size: 19}} <-
                 context.digest_operation.(session, binding) do
            source = %DocumentSource{
              asset_id: asset_id,
              resource_id: "00000000-0000-4000-8000-000000000105",
              resource_version_id: "00000000-0000-4000-8000-000000000106",
              object_id: "00000000-0000-4000-8000-000000000104",
              owner_scope_id: session.owner_scope_id,
              classification: :private,
              digest: digest,
              byte_size: 19,
              media_type: media
            }

            {:ok,
             %PreparedSource{source: source, binding: binding, principal_id: session.principal_id}}
          end

        _ ->
          {:error, Error.new(:unsupported_media_type)}
      end
    end
  end

  defmodule Assets do
    def authorized_object(owner, :scoped_repo, asset_id) do
      send(owner, {:authorized_asset, asset_id})

      if Process.get(:asset_deleted) == true or asset_id != "00000000-0000-4000-8000-000000000103" do
        {:error, Error.new(:not_found)}
      else
        {:ok,
         %{
           asset_id: asset_id,
           vault_id: "00000000-0000-4000-8000-000000000102",
           classification: :private,
           object_id: "00000000-0000-4000-8000-000000000104",
           object_generation: 1
         }}
      end
    end
  end

  defmodule Custodian do
    def lease(owner, %{purpose: :download} = request) do
      send(owner, {:lease, request})
      {:ok, :lease}
    end
  end

  defmodule Reader do
    def read(owner, :lease, :all) do
      send(owner, :read_source)
      {:ok, "authenticated bytes"}
    end
  end

  defmodule Audit do
    def append(_owner, _repo, _event), do: :ok
  end

  setup do
    on_exit(fn ->
      Process.delete(:import_receipt)
      Process.delete(:asset_deleted)
      Process.delete(:import_media)
    end)
  end

  test "creates trusted IDs and digest, then replays after Asset deletion without reading" do
    config = config()
    session = session()

    assert {:ok, first} = Api.import_document(config, session, attrs())
    assert first.title == "Notes"
    assert first.source.digest == :crypto.hash(:sha256, "authenticated bytes")
    assert first.source.asset_id == @asset
    assert first.resource_id not in [@source_resource, @source_version]
    assert first.resource_version_id not in [@source_resource, @source_version]

    assert_receive {:import_scope, _,
                    %{required_capability: "asset.read", requires_unlocked?: true}}

    assert_receive {:receipt_lookup, @principal, @owner, @mutation}
    assert_receive {:prepare, :test_repo, @asset}
    assert_receive {:lease, %{purpose: :download, object_id: @object}}
    assert_receive :read_source
    assert_receive {:create_pending, _, _}

    Process.put(:asset_deleted, true)

    assert {:ok, ^first} =
             Api.import_document(config, session, %{
               "asset_id" => @asset,
               "title" => "Notes",
               "mutation_id" => @mutation
             })

    refute_received :read_source
    refute_received {:create_pending, _, _}
  end

  test "changed replay fields conflict before deleted bytes are read" do
    assert {:ok, _} = Api.import_document(config(), session(), attrs())
    assert_receive :read_source
    Process.put(:asset_deleted, true)

    assert {:error, :conflict} =
             Api.import_document(config(), session(), %{attrs() | title: "Changed"})

    assert {:error, :conflict} =
             Api.import_document(config(), session(), %{attrs() | asset_id: Ecto.UUID.generate()})

    refute_received :read_source
  end

  test "rejects unsupported media, locked session and forged fields" do
    Process.put(:import_media, "image/png")
    assert {:error, :unsupported_media_type} = Api.import_document(config(), session(), attrs())

    assert {:error, :vault_locked} =
             Api.import_document(config(), %{session() | unlocked?: false}, attrs())

    for key <- [:owner_scope_id, :source, :digest, :object_id, :generation] do
      assert {:error, :invalid} =
               Api.import_document(config(), session(), Map.put(attrs(), key, "forged"))
    end

    assert {:error, :invalid} =
             Api.import_document(config(), session(), Map.put(attrs(), "asset_id", @asset))
  end

  test "cross-owner Asset and receipt access fail without exposing a source" do
    foreign = %{session() | vault_id: Ecto.UUID.generate()}

    assert {:error, :integrity_failure} = Api.import_document(config(), foreign, attrs())
    refute_received :read_source

    assert {:ok, _} = Api.import_document(config(), session(), attrs())
    assert_receive :read_source
    assert {:error, :integrity_failure} = Api.import_document(config(), foreign, attrs())
    refute_received :read_source
  end

  test "public import rejects untrusted source and owner fields" do
    assert {:error, :invalid} =
             Api.import_document(%{}, :invalid_session, %{
               asset_id: Ecto.UUID.generate(),
               title: "Notes",
               mutation_id: Ecto.UUID.generate(),
               owner_scope_id: Ecto.UUID.generate()
             })
  end

  defp config,
    do: %{
      import_document: fn session, attrs ->
        Singularity.Runtime.Documents.Import.run(
          %{
            operation_scope: {Scope, self()},
            document_repository: Repository,
            prepare_source: {Prepare, self()},
            assets: {Assets, self()},
            custodian: {Custodian, self()},
            authenticated_reader: {Reader, self()},
            audit: {Audit, self()},
            request_repo: :test_repo,
            fingerprint_secret: :binary.copy("x", 32)
          },
          session,
          attrs
        )
      end
    }

  defp session,
    do: %Session{
      session_id: Ecto.UUID.generate(),
      account_id: nil,
      principal_id: @principal,
      vault_id: @owner,
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second),
      principal_authorization_epoch: 1,
      vault_authorization_epoch: 1,
      authorization_epoch: 1,
      unlocked?: true
    }

  defp attrs, do: %{asset_id: @asset, title: "  Notes  ", mutation_id: @mutation}
end
