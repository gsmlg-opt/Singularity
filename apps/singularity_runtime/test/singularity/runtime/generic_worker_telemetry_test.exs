defmodule Singularity.Runtime.Observability.GenericWorkerTelemetryTest do
  use ExUnit.Case, async: true

  alias Singularity.Runtime.Observability.Telemetry
  alias Singularity.Storage.Jobs.GenericWorker

  @events [[:singularity, :job, :retry], [:singularity, :job, :failure]]
  @secret "CANARY_GENERIC_WORKER_TELEMETRY_CONTENT"

  setup do
    id = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(id) end)
    assert :ok = :telemetry.attach_many(id, @events, &__MODULE__.forward/4, self())
    :ok
  end

  def forward(event, measurements, metadata, owner) do
    if self() == owner, do: send(owner, {:derived, event, measurements, metadata})
    :ok
  end

  for representation <- [:canonical, :module, :legacy],
      placement <- [:top_level, :nested],
      outcome <- [:retry, :final_exception, :cancelled, :discard] do
    @tag representation: representation, placement: placement, outcome: outcome
    test "#{representation} #{placement} #{outcome} emits only bounded fields", context do
      worker = worker(context.representation)
      attempt = if context.outcome == :final_exception, do: 3, else: 2
      fields = %{worker: worker, queue: "asset_verify", attempt: attempt, max_attempts: 3}
      metadata = if context.placement == :nested, do: %{job: fields}, else: fields

      metadata =
        Map.merge(metadata, %{
          args: %{"payload" => @secret},
          reason: RuntimeError.exception(@secret),
          stacktrace: [@secret],
          plaintext: @secret
        })

      {source, metadata} =
        if context.outcome in [:cancelled, :discard],
          do: {[:oban, :job, :stop], Map.put(metadata, :state, context.outcome)},
          else: {[:oban, :job, :exception], metadata}

      expected_event =
        if context.outcome == :retry,
          do: [:singularity, :job, :retry],
          else: [:singularity, :job, :failure]

      assert :ok = Telemetry.handle_event(source, %{duration: 12, unsafe: @secret}, metadata, nil)
      assert_receive {:derived, ^expected_event, measurements, safe}
      assert measurements == %{count: 1}

      assert safe == %{
               attempt: attempt,
               max_attempts: 3,
               queue: :asset_verify,
               worker: :generic_worker
             }

      refute_receive {:derived, _, _, _}, 0
    end
  end

  test "unknown queue remains bounded and top-level fields retain precedence" do
    metadata = %{
      worker: worker(:canonical),
      queue: @secret,
      attempt: 2,
      max_attempts: 3,
      job: %{worker: "Other.Worker", queue: "asset_verify", attempt: 3, max_attempts: 9}
    }

    assert :ok = Telemetry.handle_event([:oban, :job, :exception], %{}, metadata, nil)
    assert_receive {:derived, [:singularity, :job, :retry], measurements, safe}
    assert measurements == %{count: 1}
    assert safe == %{attempt: 2, max_attempts: 3, queue: :unknown, worker: :generic_worker}
    refute_receive {:derived, _, _, _}, 0
  end

  test "unrelated and lookalike names are rejected, including top-level override" do
    for name <- [
          nil,
          "Other.Worker",
          "Singularity.Storage.Jobs.GenericWorkerExtra",
          "Elixir.Elixir.Singularity.Storage.Jobs.GenericWorker",
          " GenericWorker",
          "singularity.storage.jobs.GenericWorker"
        ] do
      metadata = %{worker: name, queue: "asset_verify", attempt: 2, max_attempts: 3}
      assert :ok = Telemetry.handle_event([:oban, :job, :exception], %{}, metadata, nil)
      refute_receive {:derived, _, _, _}, 0
    end

    metadata = %{
      worker: "Other.Worker",
      attempt: 2,
      max_attempts: 3,
      job: %{worker: worker(:canonical), attempt: 2, max_attempts: 3}
    }

    assert :ok = Telemetry.handle_event([:oban, :job, :exception], %{}, metadata, nil)
    refute_receive {:derived, _, _, _}, 0
  end

  test "invalid attempts and nonterminal stop outcomes remain ignored" do
    for {attempt, maximum} <- [
          {nil, 3},
          {0, 3},
          {-1, 3},
          {"2", 3},
          {2, nil},
          {2, 0},
          {2, "3"}
        ] do
      metadata = %{worker: worker(:canonical), attempt: attempt, max_attempts: maximum}
      assert :ok = Telemetry.handle_event([:oban, :job, :exception], %{}, metadata, nil)
      refute_receive {:derived, _, _, _}, 0
    end

    for state <- [:success, :snoozed, :discarded] do
      metadata = %{worker: worker(:canonical), attempt: 2, max_attempts: 3, state: state}
      assert :ok = Telemetry.handle_event([:oban, :job, :stop], %{}, metadata, nil)
      refute_receive {:derived, _, _, _}, 0
    end
  end

  defp worker(:canonical), do: Oban.Worker.to_string(GenericWorker)
  defp worker(:module), do: GenericWorker
  defp worker(:legacy), do: "Elixir.Singularity.Storage.Jobs.GenericWorker"
end
