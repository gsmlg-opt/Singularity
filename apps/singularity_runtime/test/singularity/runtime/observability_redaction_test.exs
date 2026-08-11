defmodule Singularity.Runtime.Observability.RedactionTest do
  use ExUnit.Case, async: false

  alias Singularity.Runtime.Observability.LoggerMetadata
  alias Singularity.Runtime.Observability.Redactor

  @secret "CANARY_PASSWORD_8e4a"
  @correlation_id "00000000-0000-4000-8000-000000001601"
  @principal_id "00000000-0000-4000-8000-000000001602"
  @vault_id "00000000-0000-4000-8000-000000001603"
  @asset_id "00000000-0000-4000-8000-000000001604"

  defmodule RawHandler do
    def adding_handler(config), do: {:ok, config}
    def removing_handler(_config), do: :ok

    def changing_config(_set_or_update, _old_config, new_config),
      do: {:ok, new_config}

    def log(event, %{config: %{receiver: receiver}}) do
      send(receiver, {:raw_logger_event, event})
    end
  end

  test "redact/1 recursively redacts sensitive atom and string keys" do
    input = %{
      "upload-token" => @secret,
      asset_id: "asset-1",
      password: @secret,
      nested: [
        %{domain_dedup_key: @secret, vault_key: @secret, safe: "visible"},
        [backup_passphrase: @secret]
      ]
    }

    assert Redactor.redact(input) == %{
             "upload-token" => "[REDACTED]",
             asset_id: "asset-1",
             password: "[REDACTED]",
             nested: [
               %{
                 domain_dedup_key: "[REDACTED]",
                 vault_key: "[REDACTED]",
                 safe: "visible"
               },
               [backup_passphrase: "[REDACTED]"]
             ]
           }
  end

  test "LoggerJSON redactor callback protects nested structured messages" do
    {LoggerJSON.Formatters.Basic, formatter} =
      LoggerJSON.Formatters.Basic.new(
        metadata: LoggerMetadata.allowed_keys(),
        redactors: [Redactor.new([])]
      )

    event = %{
      level: :info,
      meta: %{
        correlation_id: "correlation-1",
        password: @secret,
        arbitrary: @secret,
        time: System.system_time(:microsecond)
      },
      msg:
        {:report,
         %{
           operation: "asset.download",
           payload: %{authorization: @secret, result: "completed"}
         }}
    }

    encoded =
      event
      |> LoggerJSON.Formatters.Basic.format(formatter)
      |> IO.iodata_to_binary()
      |> JSON.decode!()

    assert encoded["metadata"] == %{"correlation_id" => "correlation-1"}

    assert encoded["message"] == %{
             "operation" => "asset.download",
             "payload" => %{
               "authorization" => "[REDACTED]",
               "result" => "completed"
             }
           }

    refute inspect(encoded) =~ @secret
  end

  test "logger metadata is default-deny and keeps only permitted opaque fields" do
    metadata = %{
      correlation_id: @correlation_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      asset_id: @asset_id,
      operation: :asset_download,
      result: :completed,
      password: @secret,
      arbitrary: "must-not-appear"
    }

    assert LoggerMetadata.sanitize(metadata) == %{
             correlation_id: @correlation_id,
             principal_id: @principal_id,
             vault_id: @vault_id,
             asset_id: @asset_id,
             operation: :asset_download,
             result: :completed
           }

    assert LoggerMetadata.sanitize(%{
             correlation_id: @secret,
             operation: @secret,
             result: @secret
           }) == %{}
  end

  test "structured logging is sanitized before Logger handlers receive the event" do
    handler_id = :singularity_observability_redaction_test
    previous_metadata = Logger.metadata()

    Logger.metadata(
      arbitrary: @secret,
      password: @secret,
      principal_id: @principal_id
    )

    on_exit(fn -> Logger.reset_metadata(previous_metadata) end)

    _ = :logger.remove_handler(handler_id)

    assert :ok =
             :logger.add_handler(handler_id, RawHandler, %{
               config: %{receiver: self()},
               level: :all
             })

    on_exit(fn -> :logger.remove_handler(handler_id) end)

    assert :ok =
             LoggerMetadata.log(
               :warning,
               %{
                 operation: :asset_download,
                 result: :completed,
                 payload: %{
                   domain_dedup_key: @secret,
                   arbitrary: @secret
                 }
               },
               %{
                 arbitrary: @secret,
                 correlation_id: @correlation_id,
                 password: @secret
               }
             )

    assert Logger.metadata()[:password] == @secret
    assert_receive {:raw_logger_event, event}
    refute inspect(event, limit: :infinity, printable_limit: :infinity) =~ @secret

    assert event.meta.correlation_id == @correlation_id
    assert event.meta.principal_id == @principal_id
    refute Map.has_key?(event.meta, :arbitrary)
    refute Map.has_key?(event.meta, :password)

    assert {:report,
            %{
              operation: :asset_download,
              result: :completed
            }} = event.msg
  end

  test "the default LoggerJSON handler uses the explicit allowlist and redactor" do
    assert [
             formatter:
               {LoggerJSON.Formatters.Basic,
                [
                  metadata: metadata,
                  redactors: [{Redactor, []}]
                ]}
           ] = Application.fetch_env!(:logger, :default_handler)

    assert metadata == LoggerMetadata.allowed_keys()
    refute metadata in [:all, nil]
  end

  test "repository query logging is disabled before SQL parameters reach Logger" do
    repos = [
      Singularity.Storage.MigrationRepo,
      Singularity.Storage.RequestRepo,
      Singularity.Storage.PreAuthRepo,
      Singularity.Storage.DispatcherRepo,
      Singularity.Storage.WorkerRepo
    ]

    for repo <- repos do
      assert Application.fetch_env!(:singularity_storage, repo)[:log] == false

      options = repo.default_options(:all)
      assert Keyword.has_key?(options, :telemetry_event)
      assert Keyword.fetch!(options, :telemetry_event) == nil
    end
  end
end
