defmodule Singularity.Web.Architecture.ExportLeaseOwnershipContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)
  # This is an exact reviewed transition, not a new frozen baseline or a
  # module-wide whitelist. Context bytes and all unlisted legacy bytes matter.
  @transitions Jason.decode!(~S'''
               [{"path":"apps/singularity_runtime/lib/singularity/runtime/download_lease.ex","original_sha256":"3ecce1470e11d506435d8213faa1b2c0c012ffb360cb3e4b82f67bdd5277636e","candidate_sha256":"4745d1b11ac40a499913bab80d4cc78e89705deaa3113065983760ecd913b060","hunks":[{"id":1,"range":"-1,3 +1,57 @@","old":"defmodule Singularity.Runtime.DownloadLease do\n  @moduledoc \"\"\"\n  One-use opaque custody for an authenticated full or ranged object read.\n","new":"defmodule Singularity.Runtime.DownloadLease.ExportOwnership do\n  @moduledoc false\n\n  def new do\n    %{\n      deadline_ms: System.monotonic_time(:millisecond) + 5_000,\n      state: :atomics.new(1, signed: false)\n    }\n  end\n\n  def remaining_ms(ticket),\n    do: max(ticket.deadline_ms - System.monotonic_time(:millisecond), 0)\n\n  def status(ticket) do\n    case :atomics.get(ticket.state, 1) do\n      0 -> :pending\n      1 -> :accepted\n      2 -> :cancelled\n    end\n  end\n\n  def accept(ticket) do\n    if remaining_ms(ticket) > 0 do\n      case :atomics.compare_exchange(ticket.state, 1, 0, 1) do\n        result when result in [:ok, 1] ->\n          if remaining_ms(ticket) > 0 and status(ticket) == :accepted do\n            :ok\n          else\n            cancel(ticket)\n            :cancelled\n          end\n\n        2 ->\n          :cancelled\n      end\n    else\n      cancel(ticket)\n      :cancelled\n    end\n  end\n\n  def cancel(ticket) do\n    :atomics.put(ticket.state, 1, 2)\n    :ok\n  end\n\n  def expire_pending(ticket) do\n    case :atomics.compare_exchange(ticket.state, 1, 0, 2) do\n      1 -> :accepted\n      result when result in [:ok, 2] -> :cancelled\n    end\n  end\nend\n\ndefmodule Singularity.Runtime.DownloadLease do\n  @moduledoc \"\"\"\n  One-use opaque custody for an authenticated full or ranged object read.\n","left":"","right":"defmodule Singularity.Runtime.DownloadLease do\n  @moduledoc \"\"\"\n  One-use opaque custody for an authenticated full or ranged object read.\n","old_body":"","new_body":"defmodule Singularity.Runtime.DownloadLease.ExportOwnership do\n  @moduledoc false\n\n  def new do\n    %{\n      deadline_ms: System.monotonic_time(:millisecond) + 5_000,\n      state: :atomics.new(1, signed: false)\n    }\n  end\n\n  def remaining_ms(ticket),\n    do: max(ticket.deadline_ms - System.monotonic_time(:millisecond), 0)\n\n  def status(ticket) do\n    case :atomics.get(ticket.state, 1) do\n      0 -> :pending\n      1 -> :accepted\n      2 -> :cancelled\n    end\n  end\n\n  def accept(ticket) do\n    if remaining_ms(ticket) > 0 do\n      case :atomics.compare_exchange(ticket.state, 1, 0, 1) do\n        result when result in [:ok, 1] ->\n          if remaining_ms(ticket) > 0 and status(ticket) == :accepted do\n            :ok\n          else\n            cancel(ticket)\n            :cancelled\n          end\n\n        2 ->\n          :cancelled\n      end\n    else\n      cancel(ticket)\n      :cancelled\n    end\n  end\n\n  def cancel(ticket) do\n    :atomics.put(ticket.state, 1, 2)\n    :ok\n  end\n\n  def expire_pending(ticket) do\n    case :atomics.compare_exchange(ticket.state, 1, 0, 2) do\n      1 -> :accepted\n      result when result in [:ok, 2] -> :cancelled\n    end\n  end\nend\n\n","old_sha256":"29e35efce402c2668ec9cfba78a7d4501dfd3fbcb46d9138aadcba2e38691a2d","new_sha256":"8ab4c032ab022bdee4df7f771b1b09219f7470015bc119b8ccac2042cc5c8bd8","left_sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","right_sha256":"29e35efce402c2668ec9cfba78a7d4501dfd3fbcb46d9138aadcba2e38691a2d","left_boundary":"BOF","right_boundary":"CONTEXT"},{"id":2,"range":"-9,6 +63,7 @@ defmodule Singularity.Runtime.DownloadLease do","old":"  use GenServer\n\n  alias Singularity.Core.Error\n\n  @lease_seconds 60\n\n","new":"  use GenServer\n\n  alias Singularity.Core.Error\n  alias Singularity.Runtime.DownloadLease.ExportOwnership\n\n  @lease_seconds 60\n\n","left":"  use GenServer\n\n  alias Singularity.Core.Error\n","right":"\n  @lease_seconds 60\n\n","old_body":"","new_body":"  alias Singularity.Runtime.DownloadLease.ExportOwnership\n","old_sha256":"c101a522e3c63798cf1995e394713e61d024e5be3cae0e29edb0c30d4e929199","new_sha256":"210635a4fb3122f6558b3aaaa4547721f7df73e66e9067fa4512714ab94053b2","left_sha256":"f0d59dd0c87523df4c48d84b7a029d4afb9b473e3123f644916c3c4cfeca0432","right_sha256":"d00bb4a02cdc4ef36c6837468e7099d88b7de73ab600c341a2cfe55a17ca9227","left_boundary":"CONTEXT","right_boundary":"CONTEXT"},{"id":3,"range":"-72,6 +127,54 @@ defmodule Singularity.Runtime.DownloadLease do","old":"    do: GenServer.call(lease, :revoke, :infinity)\n\n  @impl true\n  def init(\n        %{\n          authorization: authorization,\n","new":"    do: GenServer.call(lease, :revoke, :infinity)\n\n  @impl true\n  def init(%{\n        authorization: authorization,\n        binding: binding,\n        clock: clock,\n        context: context,\n        custodian: custodian,\n        export_ownership: %{owner_pid: owner, ticket: ticket} = ownership,\n        key_material: <<_::binary-size(32)>> = key_material,\n        key_reader: key_reader\n      })\n      when is_map(binding) and is_pid(custodian) and is_pid(owner) do\n    Process.flag(:trap_exit, true)\n    owner_monitor = Process.monitor(owner)\n    Process.send_after(self(), :export_acquisition_expired, ExportOwnership.remaining_ms(ticket))\n\n    with :ok <- export_acquisition_status(ownership),\n         now = clock.utc_now(context),\n         :ok <- export_acquisition_status(ownership) do\n      custodian_monitor = Process.monitor(custodian)\n      Process.send_after(self(), :expire, @lease_seconds * 1_000)\n\n      {:ok,\n       %{\n         authorization: authorization,\n         binding: binding,\n         clock: clock,\n         custodian: custodian,\n         custodian_monitor: custodian_monitor,\n         expires_at: DateTime.add(now, @lease_seconds, :second),\n         export_ownership: ownership,\n         export_owner_monitor: owner_monitor,\n         key_reader: key_reader,\n         mode: nil,\n         consumer_pid: nil,\n         consumer_monitor: nil,\n         next_index: 0,\n         pending: nil,\n         public_context: Map.delete(context, :key_material),\n         reader_context: Map.put(context, :key_material, key_material),\n         revoked?: false\n       }}\n    else\n      :cancelled ->\n        ExportOwnership.cancel(ticket)\n        {:stop, :normal}\n    end\n  end\n\n  def init(\n        %{\n          authorization: authorization,\n","left":"    do: GenServer.call(lease, :revoke, :infinity)\n\n  @impl true\n","right":"  def init(\n        %{\n          authorization: authorization,\n","old_body":"","new_body":"  def init(%{\n        authorization: authorization,\n        binding: binding,\n        clock: clock,\n        context: context,\n        custodian: custodian,\n        export_ownership: %{owner_pid: owner, ticket: ticket} = ownership,\n        key_material: <<_::binary-size(32)>> = key_material,\n        key_reader: key_reader\n      })\n      when is_map(binding) and is_pid(custodian) and is_pid(owner) do\n    Process.flag(:trap_exit, true)\n    owner_monitor = Process.monitor(owner)\n    Process.send_after(self(), :export_acquisition_expired, ExportOwnership.remaining_ms(ticket))\n\n    with :ok <- export_acquisition_status(ownership),\n         now = clock.utc_now(context),\n         :ok <- export_acquisition_status(ownership) do\n      custodian_monitor = Process.monitor(custodian)\n      Process.send_after(self(), :expire, @lease_seconds * 1_000)\n\n      {:ok,\n       %{\n         authorization: authorization,\n         binding: binding,\n         clock: clock,\n         custodian: custodian,\n         custodian_monitor: custodian_monitor,\n         expires_at: DateTime.add(now, @lease_seconds, :second),\n         export_ownership: ownership,\n         export_owner_monitor: owner_monitor,\n         key_reader: key_reader,\n         mode: nil,\n         consumer_pid: nil,\n         consumer_monitor: nil,\n         next_index: 0,\n         pending: nil,\n         public_context: Map.delete(context, :key_material),\n         reader_context: Map.put(context, :key_material, key_material),\n         revoked?: false\n       }}\n    else\n      :cancelled ->\n        ExportOwnership.cancel(ticket)\n        {:stop, :normal}\n    end\n  end\n\n","old_sha256":"fa781eb855e1417517535179fa3a0282ca6ca48008f408d7f1a6357d00a99048","new_sha256":"667d1ee42f866306ee1804b3bd6f0bb15ec31a7d26d88f26be6bca458a93c3ba","left_sha256":"89b294d73e096c0afa0a05e39dcab8dc64b9f3960947676dfe603f34d3520b0d","right_sha256":"f9b33b96e7d2824be2726b986fb0e9d88af8a19652a16d608ff264000cd971ad","left_boundary":"CONTEXT","right_boundary":"CONTEXT"},{"id":4,"range":"-282,6 +385,9 @@ defmodule Singularity.Runtime.DownloadLease do","old":"  def handle_call(:authenticate_empty_document_original, _from, state),\n    do: {:reply, {:error, Error.new(:invalid)}, state}\n\n  def handle_call(:revoke, _from, %{mode: :document_worker_source} = state),\n    do: {:stop, :normal, :ok, revoke_state(state)}\n\n","new":"  def handle_call(:authenticate_empty_document_original, _from, state),\n    do: {:reply, {:error, Error.new(:invalid)}, state}\n\n  def handle_call(:revoke, _from, %{export_ownership: _ownership} = state),\n    do: {:stop, :normal, :ok, revoke_state(state)}\n\n  def handle_call(:revoke, _from, %{mode: :document_worker_source} = state),\n    do: {:stop, :normal, :ok, revoke_state(state)}\n\n","left":"  def handle_call(:authenticate_empty_document_original, _from, state),\n    do: {:reply, {:error, Error.new(:invalid)}, state}\n\n","right":"  def handle_call(:revoke, _from, %{mode: :document_worker_source} = state),\n    do: {:stop, :normal, :ok, revoke_state(state)}\n\n","old_body":"","new_body":"  def handle_call(:revoke, _from, %{export_ownership: _ownership} = state),\n    do: {:stop, :normal, :ok, revoke_state(state)}\n\n","old_sha256":"ef49e49d94c0404b2d4fbedb4f588d526041ec356cfc4aacc37a1fe147f4fac4","new_sha256":"2edaa5e3b78cb676cdc0a44bdce6cfb6a3fcc70bec93bf473e1e551121905c72","left_sha256":"5981fa663ac56818a05039ee886bdd514a7965e12150ae178ca2654a5ffb5700","right_sha256":"4f75e26f34f4a3c45de565e83c7fdb8dd578ce5550c5be81f348ec03a52c65e6","left_boundary":"CONTEXT","right_boundary":"CONTEXT"},{"id":5,"range":"-426,6 +532,15 @@ defmodule Singularity.Runtime.DownloadLease do","old":"    {:stop, :normal, state |> Map.put(:pending, nil) |> revoke_state()}\n  end\n\n  def handle_info(\n        {:DOWN, monitor, :process, consumer, _reason},\n        %{\n","new":"    {:stop, :normal, state |> Map.put(:pending, nil) |> revoke_state()}\n  end\n\n  def handle_info(\n        {:DOWN, monitor, :process, owner, _reason},\n        %{\n          export_ownership: %{owner_pid: owner},\n          export_owner_monitor: monitor\n        } = state\n      ),\n      do: {:stop, :normal, revoke_state(state)}\n\n  def handle_info(\n        {:DOWN, monitor, :process, consumer, _reason},\n        %{\n","left":"    {:stop, :normal, state |> Map.put(:pending, nil) |> revoke_state()}\n  end\n\n","right":"  def handle_info(\n        {:DOWN, monitor, :process, consumer, _reason},\n        %{\n","old_body":"","new_body":"  def handle_info(\n        {:DOWN, monitor, :process, owner, _reason},\n        %{\n          export_ownership: %{owner_pid: owner},\n          export_owner_monitor: monitor\n        } = state\n      ),\n      do: {:stop, :normal, revoke_state(state)}\n\n","old_sha256":"b6c08e93cee26bf375868841c8c4e924702e91bc9516b32737d3873b77ea2067","new_sha256":"d2058ebf42b0d8911ba2ccae73301bc4c972c3d74c79205eb2ac108fa05c1b5b","left_sha256":"32334fa71bb9ed38ed66b53791ba8d8584e29ac088822af1981a69fd6f6479fa","right_sha256":"8279fd3993f1c045989bb2b2086944aff9a6e79bed1ce3f6bf8a3556c9c9ae2c","left_boundary":"CONTEXT","right_boundary":"CONTEXT"},{"id":6,"range":"-443,6 +558,16 @@ defmodule Singularity.Runtime.DownloadLease do","old":"    {:stop, :normal, revoke_state(state)}\n  end\n\n  def handle_info(:expire, %{mode: :document_worker_source} = state),\n    do: {:stop, :normal, revoke_state(state)}\n\n","new":"    {:stop, :normal, revoke_state(state)}\n  end\n\n  def handle_info(:export_acquisition_expired, %{export_ownership: ownership} = state) do\n    case ExportOwnership.expire_pending(ownership.ticket) do\n      :accepted -> {:noreply, state}\n      :cancelled -> {:stop, :normal, revoke_state(state)}\n    end\n  end\n\n  def handle_info(:expire, %{export_ownership: _ownership} = state),\n    do: {:stop, :normal, revoke_state(state)}\n\n  def handle_info(:expire, %{mode: :document_worker_source} = state),\n    do: {:stop, :normal, revoke_state(state)}\n\n","left":"    {:stop, :normal, revoke_state(state)}\n  end\n\n","right":"  def handle_info(:expire, %{mode: :document_worker_source} = state),\n    do: {:stop, :normal, revoke_state(state)}\n\n","old_body":"","new_body":"  def handle_info(:export_acquisition_expired, %{export_ownership: ownership} = state) do\n    case ExportOwnership.expire_pending(ownership.ticket) do\n      :accepted -> {:noreply, state}\n      :cancelled -> {:stop, :normal, revoke_state(state)}\n    end\n  end\n\n  def handle_info(:expire, %{export_ownership: _ownership} = state),\n    do: {:stop, :normal, revoke_state(state)}\n\n","old_sha256":"97dc2fbc773c85ee7d1121e01ff8b375024681c0c759b180848e643c4f75be17","new_sha256":"168f4cd7ac7b5c1716f434b7c7aac84fcd1fbb3d1137b33fa4676ac37e7c1aed","left_sha256":"400a7611ef6d5ad7943ba33dd4f4e091554ea44d32e3db182774facba2e1078d","right_sha256":"7b78272fcb5ce77fee82ac7e9cf31dfee73208986018fd91ec737c9ce2a963f1","left_boundary":"CONTEXT","right_boundary":"CONTEXT"},{"id":7,"range":"-476,13 +601,15 @@ defmodule Singularity.Runtime.DownloadLease do","old":"      reader_context: state.reader_context\n    }\n\n    reader = fn ->\n      result = perform_read(operation)\n      send(lease, {:download_read_complete, operation_ref, result})\n    end\n\n    {worker, monitor} =\n      if state.mode == :document_worker_source,\n        do: :erlang.spawn_opt(reader, [:link, :monitor]),\n        else: spawn_monitor(reader)\n\n","new":"      reader_context: state.reader_context\n    }\n\n    operation = Map.merge(operation, Map.take(state, [:export_ownership]))\n\n    reader = fn ->\n      result = perform_read(operation)\n      send(lease, {:download_read_complete, operation_ref, result})\n    end\n\n    {worker, monitor} =\n      if state.mode == :document_worker_source or Map.has_key?(state, :export_ownership),\n        do: :erlang.spawn_opt(reader, [:link, :monitor]),\n        else: spawn_monitor(reader)\n\n","left":"      reader_context: state.reader_context\n    }\n\n","right":"        do: :erlang.spawn_opt(reader, [:link, :monitor]),\n        else: spawn_monitor(reader)\n\n","old_body":"    reader = fn ->\n      result = perform_read(operation)\n      send(lease, {:download_read_complete, operation_ref, result})\n    end\n\n    {worker, monitor} =\n      if state.mode == :document_worker_source,\n","new_body":"    operation = Map.merge(operation, Map.take(state, [:export_ownership]))\n\n    reader = fn ->\n      result = perform_read(operation)\n      send(lease, {:download_read_complete, operation_ref, result})\n    end\n\n    {worker, monitor} =\n      if state.mode == :document_worker_source or Map.has_key?(state, :export_ownership),\n","old_sha256":"6c11700c2aff30ae9f31eef8047cdee6e7eb4e26ed897357cd84037b2144e3f5","new_sha256":"b7be13d6e6f7f1dc53d16c39f198d2b236f6688309a93d37b9f2f61b0fa94188","left_sha256":"3a36cc49c169ce1df1ae9a1c54b2ab6265bc0e31525bcbaa5a17fd7d8f30b56d","right_sha256":"c1b989d343d5335d1008e20a94aee863f5246d79c261467f4411ed33e4672c0c","left_boundary":"CONTEXT","right_boundary":"CONTEXT"},{"id":8,"range":"-499,17 +626,20 @@ defmodule Singularity.Runtime.DownloadLease do","old":"  end\n\n  defp perform_read(operation) do\n    with :ok <-\n           operation.authorization.revalidate(\n             operation.public_context,\n             operation.binding\n           ),\n         {:ok, plaintext} <- read_operation(operation),\n         :ok <-\n           operation.authorization.revalidate(\n             operation.public_context,\n             operation.binding\n           ) do\n      {:ok, plaintext}\n    end\n  rescue\n","new":"  end\n\n  defp perform_read(operation) do\n    with :ok <- export_read_status(operation),\n         :ok <-\n           operation.authorization.revalidate(\n             operation.public_context,\n             operation.binding\n           ),\n         :ok <- export_read_status(operation),\n         {:ok, plaintext} <- read_operation(operation),\n         :ok <-\n           operation.authorization.revalidate(\n             operation.public_context,\n             operation.binding\n           ),\n         :ok <- export_read_status(operation) do\n      {:ok, plaintext}\n    end\n  rescue\n","left":"  end\n\n  defp perform_read(operation) do\n","right":"      {:ok, plaintext}\n    end\n  rescue\n","old_body":"    with :ok <-\n           operation.authorization.revalidate(\n             operation.public_context,\n             operation.binding\n           ),\n         {:ok, plaintext} <- read_operation(operation),\n         :ok <-\n           operation.authorization.revalidate(\n             operation.public_context,\n             operation.binding\n           ) do\n","new_body":"    with :ok <- export_read_status(operation),\n         :ok <-\n           operation.authorization.revalidate(\n             operation.public_context,\n             operation.binding\n           ),\n         :ok <- export_read_status(operation),\n         {:ok, plaintext} <- read_operation(operation),\n         :ok <-\n           operation.authorization.revalidate(\n             operation.public_context,\n             operation.binding\n           ),\n         :ok <- export_read_status(operation) do\n","old_sha256":"f3e0a4b78e82449768d2ceb63c92fc96f8e3a1a3df8fc7d4696bce195fc6f040","new_sha256":"2c4a54ce81ae3c9db5d306552f25ea7bda904527d9ff56a329e83cb88a71f595","left_sha256":"918617c858f1d528e2cc86e32edf28ff739bfd2bf74cba3adfbc0a347923d3b3","right_sha256":"a5dc7e63ac029e51d52d996c5e89fdc3c5397d075b116f3eb1017ce61118c32a","left_boundary":"CONTEXT","right_boundary":"CONTEXT"},{"id":9,"range":"-537,6 +667,17 @@ defmodule Singularity.Runtime.DownloadLease do","old":"\n  defp lease_status(%{revoked?: true}), do: :revoked\n\n  defp lease_status(state) do\n    case DateTime.compare(\n           state.clock.utc_now(state.public_context),\n","new":"\n  defp lease_status(%{revoked?: true}), do: :revoked\n\n  defp lease_status(%{export_ownership: _ownership} = state) do\n    with :ok <- export_read_status(state),\n         :lt <- DateTime.compare(state.clock.utc_now(state.public_context), state.expires_at),\n         :ok <- export_read_status(state) do\n      :active\n    else\n      {:error, :waiting_for_unlock} -> :revoked\n      _expired -> :expired\n    end\n  end\n\n  defp lease_status(state) do\n    case DateTime.compare(\n           state.clock.utc_now(state.public_context),\n","left":"\n  defp lease_status(%{revoked?: true}), do: :revoked\n\n","right":"  defp lease_status(state) do\n    case DateTime.compare(\n           state.clock.utc_now(state.public_context),\n","old_body":"","new_body":"  defp lease_status(%{export_ownership: _ownership} = state) do\n    with :ok <- export_read_status(state),\n         :lt <- DateTime.compare(state.clock.utc_now(state.public_context), state.expires_at),\n         :ok <- export_read_status(state) do\n      :active\n    else\n      {:error, :waiting_for_unlock} -> :revoked\n      _expired -> :expired\n    end\n  end\n\n","old_sha256":"e47e44ddd327f8f68ab4d51dca51ca3336ee7c339213bb369bfc5fb83ec17eeb","new_sha256":"c15384efd79b2c417308b8775c621b18ec3607f8148a6a372220a77b8b03f3da","left_sha256":"6b4002db1e9b6ebf866bd3b847d6f2847e364423621eec4b72e636d2a80efa3d","right_sha256":"8e4f6ee551416d5e632b60e1abf876ab28edb55078c00e9889ba1dee55da8b2b","left_boundary":"CONTEXT","right_boundary":"CONTEXT"},{"id":10,"range":"-550,6 +691,9 @@ defmodule Singularity.Runtime.DownloadLease do","old":"  defp revoke_state(%{revoked?: true} = state), do: state\n\n  defp revoke_state(state) do\n    state = cancel_pending(state)\n    _overwritten = overwrite(Map.get(state.reader_context, :key_material))\n\n","new":"  defp revoke_state(%{revoked?: true} = state), do: state\n\n  defp revoke_state(state) do\n    if Map.has_key?(state, :export_ownership),\n      do: ExportOwnership.cancel(state.export_ownership.ticket)\n\n    state = cancel_pending(state)\n    _overwritten = overwrite(Map.get(state.reader_context, :key_material))\n\n","left":"  defp revoke_state(%{revoked?: true} = state), do: state\n\n  defp revoke_state(state) do\n","right":"    state = cancel_pending(state)\n    _overwritten = overwrite(Map.get(state.reader_context, :key_material))\n\n","old_body":"","new_body":"    if Map.has_key?(state, :export_ownership),\n      do: ExportOwnership.cancel(state.export_ownership.ticket)\n\n","old_sha256":"28103edd000643c7439a90d288977ef1e657ff716711680e9cdbe719acc7f388","new_sha256":"e517b1ba49732d7ce6f77fa5948dc771967fb5385c2abd023cd591e3d335dfc2","left_sha256":"1fab46ae7581db14025cc007fcf4755ee43017fcdfb13dceb25fec24147b21b9","right_sha256":"c8cf9ca315b3520b54931719137d6e2dcc0f49e32fb90bec59cb311c071cae37","left_boundary":"CONTEXT","right_boundary":"CONTEXT"},{"id":11,"range":"-560,6 +704,16 @@ defmodule Singularity.Runtime.DownloadLease do","old":"    }\n  end\n\n  defp finish_reader(%{mode: :document_worker_source}, pending) do\n    Process.exit(pending.pid, :kill)\n\n","new":"    }\n  end\n\n  defp finish_reader(%{export_ownership: _ownership}, pending) do\n    Process.exit(pending.pid, :kill)\n\n    receive do\n      {:DOWN, monitor, :process, reader, _reason}\n      when monitor == pending.monitor and reader == pending.pid ->\n        :ok\n    end\n  end\n\n  defp finish_reader(%{mode: :document_worker_source}, pending) do\n    Process.exit(pending.pid, :kill)\n\n","left":"    }\n  end\n\n","right":"  defp finish_reader(%{mode: :document_worker_source}, pending) do\n    Process.exit(pending.pid, :kill)\n\n","old_body":"","new_body":"  defp finish_reader(%{export_ownership: _ownership}, pending) do\n    Process.exit(pending.pid, :kill)\n\n    receive do\n      {:DOWN, monitor, :process, reader, _reason}\n      when monitor == pending.monitor and reader == pending.pid ->\n        :ok\n    end\n  end\n\n","old_sha256":"0cfac8740cb134e25da7eebdaa3160274d5c309448b4eaa44b53cc88ff4b4b55","new_sha256":"f35aeca22af44f5b7901b90c37c90072c9ddfa099f728a6c8e2ac75149f00cbf","left_sha256":"e62a4a51076fe28035111b5a89c55afaba931af5053e588615f3727d41e32659","right_sha256":"63179831b2e5b1a4014ab34538166e8b34cbbe25b8a85360e6a266840db455c9","left_boundary":"CONTEXT","right_boundary":"CONTEXT"},{"id":12,"range":"-596,6 +750,21 @@ defmodule Singularity.Runtime.DownloadLease do","old":"\n  defp valid_range?(_range), do: false\n\n  defp overwrite(secret) when is_binary(secret),\n    do: :binary.copy(<<0>>, byte_size(secret))\n\n","new":"\n  defp valid_range?(_range), do: false\n\n  defp export_acquisition_status(%{owner_pid: owner, ticket: ticket}) do\n    if Process.alive?(owner) and ExportOwnership.status(ticket) != :cancelled and\n         ExportOwnership.remaining_ms(ticket) > 0,\n       do: :ok,\n       else: :cancelled\n  end\n\n  defp export_read_status(%{export_ownership: %{owner_pid: owner, ticket: ticket}}) do\n    if Process.alive?(owner) and ExportOwnership.status(ticket) == :accepted,\n      do: :ok,\n      else: {:error, :waiting_for_unlock}\n  end\n\n  defp export_read_status(_ordinary), do: :ok\n\n  defp overwrite(secret) when is_binary(secret),\n    do: :binary.copy(<<0>>, byte_size(secret))\n\n","left":"\n  defp valid_range?(_range), do: false\n\n","right":"  defp overwrite(secret) when is_binary(secret),\n    do: :binary.copy(<<0>>, byte_size(secret))\n\n","old_body":"","new_body":"  defp export_acquisition_status(%{owner_pid: owner, ticket: ticket}) do\n    if Process.alive?(owner) and ExportOwnership.status(ticket) != :cancelled and\n         ExportOwnership.remaining_ms(ticket) > 0,\n       do: :ok,\n       else: :cancelled\n  end\n\n  defp export_read_status(%{export_ownership: %{owner_pid: owner, ticket: ticket}}) do\n    if Process.alive?(owner) and ExportOwnership.status(ticket) == :accepted,\n      do: :ok,\n      else: {:error, :waiting_for_unlock}\n  end\n\n  defp export_read_status(_ordinary), do: :ok\n\n","old_sha256":"12cb1d99bbb30676d35c1f3e51f42f9c27fb47f078f486aabe6b4edc91b9e249","new_sha256":"49f36de80902e12a3bfa6f7edc564d7b8b648e80c00b2bd66c43c203e7f73fbf","left_sha256":"259f26b0a76a79363179129a07bd4f6f8474a3d35cd5de04186f7b8acc91d602","right_sha256":"cb3ef77ad3a3b854131bdab2941b6034f24a00bd37dd96eb63530801cb607f17","left_boundary":"CONTEXT","right_boundary":"CONTEXT"}]},{"path":"apps/singularity_runtime/lib/singularity/runtime/key_custodian.ex","original_sha256":"33a5eb62e2e8ff951dfddbb65cb029a66654a56bdab51e553a89e7d98d95b7bd","candidate_sha256":"1ce96736cc737fa6d07b72286ae24e1f56b989b665f878d92343c5884f883b6b","hunks":[{"id":1,"range":"-10,6 +10,8 @@ defmodule Singularity.Runtime.KeyCustodian do","old":"  alias Singularity.Core.Error\n  alias Singularity.Runtime.Assets.UploadReconciler\n  alias Singularity.Runtime.BackupKeyLease\n  alias Singularity.Runtime.KeyLease\n  alias Singularity.Runtime.KeyLeaseSupervisor\n  alias Singularity.Storage.Crypto.BackupRecoveryWrapper\n","new":"  alias Singularity.Core.Error\n  alias Singularity.Runtime.Assets.UploadReconciler\n  alias Singularity.Runtime.BackupKeyLease\n  alias Singularity.Runtime.DownloadLease\n  alias Singularity.Runtime.DownloadLease.ExportOwnership\n  alias Singularity.Runtime.KeyLease\n  alias Singularity.Runtime.KeyLeaseSupervisor\n  alias Singularity.Storage.Crypto.BackupRecoveryWrapper\n","left":"  alias Singularity.Core.Error\n  alias Singularity.Runtime.Assets.UploadReconciler\n  alias Singularity.Runtime.BackupKeyLease\n","right":"  alias Singularity.Runtime.KeyLease\n  alias Singularity.Runtime.KeyLeaseSupervisor\n  alias Singularity.Storage.Crypto.BackupRecoveryWrapper\n","old_body":"","new_body":"  alias Singularity.Runtime.DownloadLease\n  alias Singularity.Runtime.DownloadLease.ExportOwnership\n","old_sha256":"dcd957c4144ffe1b1314bc7eca62018b5dbb7cde7a695ee8d91789853a30ea8a","new_sha256":"02b5c4620e92a3ee1971fd715d7135400a61aa030745824c338cc90a626c40bd","left_sha256":"dce89f9091a0e656108230e46fb69f7ef365dc04b278f837b3de53bd8f48ade9","right_sha256":"ec87457f3f473ec9ba187c480d8e8a2470b0b265cd8b5a529cd8bf7bb490e6e4","left_boundary":"CONTEXT","right_boundary":"CONTEXT"},{"id":2,"range":"-244,6 +246,39 @@ defmodule Singularity.Runtime.KeyCustodian do","old":"          {:ok, KeyLease.ref()} | {:error, :waiting_for_unlock | Error.t()}\n  def lease(server, request), do: GenServer.call(server, {:lease, request})\n\n  @spec prepare_upload(GenServer.server(), map()) ::\n          {:ok, map()} | {:error, Error.t()}\n  def prepare_upload(server, request),\n","new":"          {:ok, KeyLease.ref()} | {:error, :waiting_for_unlock | Error.t()}\n  def lease(server, request), do: GenServer.call(server, {:lease, request})\n\n  @spec export_lease(GenServer.server(), map()) ::\n          {:ok, pid()} | {:error, :waiting_for_unlock | Error.t()}\n  def export_lease(server, request) do\n    ticket = ExportOwnership.new()\n\n    try do\n      case GenServer.call(\n             server,\n             {:export_lease, request, ticket},\n             ExportOwnership.remaining_ms(ticket)\n           ) do\n        {:ok, lease} when is_pid(lease) ->\n          case ExportOwnership.accept(ticket) do\n            :ok ->\n              {:ok, lease}\n\n            :cancelled ->\n              ExportOwnership.cancel(ticket)\n              revoke_failed_export(lease)\n              {:error, Error.new(:storage_unavailable, retryable?: true)}\n          end\n\n        {:error, _reason} = error ->\n          ExportOwnership.cancel(ticket)\n          error\n      end\n    catch\n      :exit, _reason ->\n        ExportOwnership.cancel(ticket)\n        {:error, Error.new(:storage_unavailable, retryable?: true)}\n    end\n  end\n\n  @spec prepare_upload(GenServer.server(), map()) ::\n          {:ok, map()} | {:error, Error.t()}\n  def prepare_upload(server, request),\n","left":"          {:ok, KeyLease.ref()} | {:error, :waiting_for_unlock | Error.t()}\n  def lease(server, request), do: GenServer.call(server, {:lease, request})\n\n","right":"  @spec prepare_upload(GenServer.server(), map()) ::\n          {:ok, map()} | {:error, Error.t()}\n  def prepare_upload(server, request),\n","old_body":"","new_body":"  @spec export_lease(GenServer.server(), map()) ::\n          {:ok, pid()} | {:error, :waiting_for_unlock | Error.t()}\n  def export_lease(server, request) do\n    ticket = ExportOwnership.new()\n\n    try do\n      case GenServer.call(\n             server,\n             {:export_lease, request, ticket},\n             ExportOwnership.remaining_ms(ticket)\n           ) do\n        {:ok, lease} when is_pid(lease) ->\n          case ExportOwnership.accept(ticket) do\n            :ok ->\n              {:ok, lease}\n\n            :cancelled ->\n              ExportOwnership.cancel(ticket)\n              revoke_failed_export(lease)\n              {:error, Error.new(:storage_unavailable, retryable?: true)}\n          end\n\n        {:error, _reason} = error ->\n          ExportOwnership.cancel(ticket)\n          error\n      end\n    catch\n      :exit, _reason ->\n        ExportOwnership.cancel(ticket)\n        {:error, Error.new(:storage_unavailable, retryable?: true)}\n    end\n  end\n\n","old_sha256":"db983089a64c7a5df68a4005e4f3c20b11ac5e75c22f45829ac5d99367ec401a","new_sha256":"953298d926415cf47262a667fe0022268524d972d9cffdfd41c30cc479c114ea","left_sha256":"f1e50c9852a3d96615acb4f8b86ba5c5316ef5f87ab3cac66b2454a5cdc900a7","right_sha256":"cf9fee409ddc646f32ac1ccf3103338d684a04b3c6f18b8740435f0b188650b2","left_boundary":"CONTEXT","right_boundary":"CONTEXT"},{"id":3,"range":"-773,6 +808,87 @@ defmodule Singularity.Runtime.KeyCustodian do","old":"    end\n  end\n\n  def handle_call({:lease, %{\"purpose\" => purpose}}, _from, state)\n      when purpose in [:document_extraction_source, \"document_extraction_source\"],\n      do: {:reply, {:error, Error.new(:invalid)}, state}\n","new":"    end\n  end\n\n  def handle_call(\n        {:export_lease, %{purpose: :download} = request, ticket},\n        {owner, _tag},\n        state\n      ) do\n    with :ok <- validate_export_download_request(request),\n         :ok <- export_acquisition_status(owner, ticket),\n         binding = Map.take(request, @request_fields),\n         %{\n           principal_id: principal_id,\n           vault_id: vault_id,\n           principal_authorization_epoch: principal_authorization_epoch,\n           vault_authorization_epoch: vault_authorization_epoch\n         } = session <-\n           Map.get(state.sessions, binding.session_id),\n         false <- matching_revocation?(state, session),\n         true <- vault_id == binding.vault_id,\n         true <- principal_id == binding.principal_id,\n         true <-\n           principal_authorization_epoch ==\n             binding.principal_authorization_epoch,\n         true <-\n           vault_authorization_epoch ==\n             binding.vault_authorization_epoch,\n         {:ok, %{object_dek: object_dek, reader_binding: reader_binding}} <-\n           object_key(state, session, binding),\n         :ok <- export_acquisition_status(owner, ticket),\n         reader_context = Map.put(state.context, :object_binding, reader_binding),\n         {:ok, lease} <-\n           start_download_lease(state, binding, object_dek, reader_context, %{\n             export_ownership: %{owner_pid: owner, ticket: ticket}\n           }) do\n      {:reply, {:ok, lease}, register_lease(state, binding, lease)}\n    else\n      nil -> {:reply, {:error, :waiting_for_unlock}, state}\n      true -> {:reply, {:error, :waiting_for_unlock}, state}\n      false -> {:reply, {:error, :waiting_for_unlock}, state}\n      {:error, :waiting_for_unlock} -> {:reply, {:error, :waiting_for_unlock}, state}\n      {:error, %Error{}} = error -> {:reply, error, state}\n      {:error, _reason} -> {:reply, {:error, Error.new(:storage_unavailable)}, state}\n    end\n  end\n\n  def handle_call(\n        {:export_lease, %{purpose: :document_source, access: :request} = request, ticket},\n        {owner, _tag},\n        state\n      ) do\n    with :ok <- validate_document_request(request, @document_request_fields),\n         :ok <- export_acquisition_status(owner, ticket),\n         %{} = session <- Map.get(state.sessions, request.session_id),\n         true <-\n           metadata_session_matches?(\n             state,\n             session,\n             request,\n             state.adapters.clock.utc_now(state.context)\n           ),\n         binding = Map.take(request, @document_request_fields),\n         :ok <- export_acquisition_status(owner, ticket),\n         {:ok, %{object_dek: object_dek, reader_binding: reader_binding}} <-\n           object_key(state, session, binding),\n         :ok <- export_acquisition_status(owner, ticket),\n         reader_context = Map.put(state.context, :object_binding, reader_binding),\n         {:ok, lease} <-\n           start_download_lease(state, binding, object_dek, reader_context, %{\n             export_ownership: %{owner_pid: owner, ticket: ticket}\n           }) do\n      {:reply, {:ok, lease}, register_lease(state, request.session_id, lease)}\n    else\n      nil -> {:reply, {:error, :waiting_for_unlock}, state}\n      false -> {:reply, {:error, :waiting_for_unlock}, state}\n      {:error, :waiting_for_unlock} -> {:reply, {:error, :waiting_for_unlock}, state}\n      {:error, %Error{}} = error -> {:reply, error, state}\n      {:error, _reason} -> {:reply, {:error, Error.new(:storage_unavailable)}, state}\n    end\n  end\n\n  def handle_call({:export_lease, _request, _ticket}, _from, state),\n    do: {:reply, {:error, Error.new(:invalid)}, state}\n\n  def handle_call({:lease, %{\"purpose\" => purpose}}, _from, state)\n      when purpose in [:document_extraction_source, \"document_extraction_source\"],\n      do: {:reply, {:error, Error.new(:invalid)}, state}\n","left":"    end\n  end\n\n","right":"  def handle_call({:lease, %{\"purpose\" => purpose}}, _from, state)\n      when purpose in [:document_extraction_source, \"document_extraction_source\"],\n      do: {:reply, {:error, Error.new(:invalid)}, state}\n","old_body":"","new_body":"  def handle_call(\n        {:export_lease, %{purpose: :download} = request, ticket},\n        {owner, _tag},\n        state\n      ) do\n    with :ok <- validate_export_download_request(request),\n         :ok <- export_acquisition_status(owner, ticket),\n         binding = Map.take(request, @request_fields),\n         %{\n           principal_id: principal_id,\n           vault_id: vault_id,\n           principal_authorization_epoch: principal_authorization_epoch,\n           vault_authorization_epoch: vault_authorization_epoch\n         } = session <-\n           Map.get(state.sessions, binding.session_id),\n         false <- matching_revocation?(state, session),\n         true <- vault_id == binding.vault_id,\n         true <- principal_id == binding.principal_id,\n         true <-\n           principal_authorization_epoch ==\n             binding.principal_authorization_epoch,\n         true <-\n           vault_authorization_epoch ==\n             binding.vault_authorization_epoch,\n         {:ok, %{object_dek: object_dek, reader_binding: reader_binding}} <-\n           object_key(state, session, binding),\n         :ok <- export_acquisition_status(owner, ticket),\n         reader_context = Map.put(state.context, :object_binding, reader_binding),\n         {:ok, lease} <-\n           start_download_lease(state, binding, object_dek, reader_context, %{\n             export_ownership: %{owner_pid: owner, ticket: ticket}\n           }) do\n      {:reply, {:ok, lease}, register_lease(state, binding, lease)}\n    else\n      nil -> {:reply, {:error, :waiting_for_unlock}, state}\n      true -> {:reply, {:error, :waiting_for_unlock}, state}\n      false -> {:reply, {:error, :waiting_for_unlock}, state}\n      {:error, :waiting_for_unlock} -> {:reply, {:error, :waiting_for_unlock}, state}\n      {:error, %Error{}} = error -> {:reply, error, state}\n      {:error, _reason} -> {:reply, {:error, Error.new(:storage_unavailable)}, state}\n    end\n  end\n\n  def handle_call(\n        {:export_lease, %{purpose: :document_source, access: :request} = request, ticket},\n        {owner, _tag},\n        state\n      ) do\n    with :ok <- validate_document_request(request, @document_request_fields),\n         :ok <- export_acquisition_status(owner, ticket),\n         %{} = session <- Map.get(state.sessions, request.session_id),\n         true <-\n           metadata_session_matches?(\n             state,\n             session,\n             request,\n             state.adapters.clock.utc_now(state.context)\n           ),\n         binding = Map.take(request, @document_request_fields),\n         :ok <- export_acquisition_status(owner, ticket),\n         {:ok, %{object_dek: object_dek, reader_binding: reader_binding}} <-\n           object_key(state, session, binding),\n         :ok <- export_acquisition_status(owner, ticket),\n         reader_context = Map.put(state.context, :object_binding, reader_binding),\n         {:ok, lease} <-\n           start_download_lease(state, binding, object_dek, reader_context, %{\n             export_ownership: %{owner_pid: owner, ticket: ticket}\n           }) do\n      {:reply, {:ok, lease}, register_lease(state, request.session_id, lease)}\n    else\n      nil -> {:reply, {:error, :waiting_for_unlock}, state}\n      false -> {:reply, {:error, :waiting_for_unlock}, state}\n      {:error, :waiting_for_unlock} -> {:reply, {:error, :waiting_for_unlock}, state}\n      {:error, %Error{}} = error -> {:reply, error, state}\n      {:error, _reason} -> {:reply, {:error, Error.new(:storage_unavailable)}, state}\n    end\n  end\n\n  def handle_call({:export_lease, _request, _ticket}, _from, state),\n    do: {:reply, {:error, Error.new(:invalid)}, state}\n\n","old_sha256":"e96d4fe646bab70a3a57d132ad20fa85ed85520262a483fb9603c11be90ee1db","new_sha256":"317a3ce3d7a27effaa5df065e2ebca3279b02d81ed4cae81e91c31b9d2a23d66","left_sha256":"4a461ce4c20faa4cef7f4e962d2b771e99132db3b6663259a0240b60a0aa93ef","right_sha256":"94e193d6df28814db9aac3da25c7da1144a7d45d874ed33dd0e02eb189465c93","left_boundary":"CONTEXT","right_boundary":"CONTEXT"},{"id":4,"range":"-1488,6 +1604,41 @@ defmodule Singularity.Runtime.KeyCustodian do","old":"    )\n  end\n\n  defp validate_vault_rotation_request(request) when is_map(request) do\n    with true <- exact_keys?(request, @vault_rotation_fields),\n         true <- valid_rotation_binding?(request),\n","new":"    )\n  end\n\n  defp revoke_failed_export(lease) do\n    monitor = Process.monitor(lease)\n\n    try do\n      :ok = DownloadLease.revoke(lease)\n    catch\n      :exit, _reason ->\n        receive do\n          {:DOWN, ^monitor, :process, ^lease, _reason} -> :ok\n        end\n    end\n\n    Process.demonitor(monitor, [:flush])\n    :ok\n  end\n\n  defp export_acquisition_status(owner, ticket) do\n    if Process.alive?(owner) and ExportOwnership.status(ticket) != :cancelled and\n         ExportOwnership.remaining_ms(ticket) > 0 do\n      :ok\n    else\n      ExportOwnership.cancel(ticket)\n      {:error, Error.new(:storage_unavailable, retryable?: true)}\n    end\n  end\n\n  defp validate_export_download_request(request) do\n    with :ok <- validate_download_request(request),\n         true <- exact_keys?(request, [:purpose | @request_fields]) do\n      :ok\n    else\n      _invalid -> {:error, Error.new(:invalid)}\n    end\n  end\n\n  defp validate_vault_rotation_request(request) when is_map(request) do\n    with true <- exact_keys?(request, @vault_rotation_fields),\n         true <- valid_rotation_binding?(request),\n","left":"    )\n  end\n\n","right":"  defp validate_vault_rotation_request(request) when is_map(request) do\n    with true <- exact_keys?(request, @vault_rotation_fields),\n         true <- valid_rotation_binding?(request),\n","old_body":"","new_body":"  defp revoke_failed_export(lease) do\n    monitor = Process.monitor(lease)\n\n    try do\n      :ok = DownloadLease.revoke(lease)\n    catch\n      :exit, _reason ->\n        receive do\n          {:DOWN, ^monitor, :process, ^lease, _reason} -> :ok\n        end\n    end\n\n    Process.demonitor(monitor, [:flush])\n    :ok\n  end\n\n  defp export_acquisition_status(owner, ticket) do\n    if Process.alive?(owner) and ExportOwnership.status(ticket) != :cancelled and\n         ExportOwnership.remaining_ms(ticket) > 0 do\n      :ok\n    else\n      ExportOwnership.cancel(ticket)\n      {:error, Error.new(:storage_unavailable, retryable?: true)}\n    end\n  end\n\n  defp validate_export_download_request(request) do\n    with :ok <- validate_download_request(request),\n         true <- exact_keys?(request, [:purpose | @request_fields]) do\n      :ok\n    else\n      _invalid -> {:error, Error.new(:invalid)}\n    end\n  end\n\n","old_sha256":"dbb8855e79f7e04ffcda7bc6230447841561ad7e7f8ad6965b4a481f56cebe7d","new_sha256":"f504a4ce411ab12561d0512010b4a73333c5abd002b494a85058c084808c39ad","left_sha256":"3ec9a43fe654eb29259cad693b8153f87837b7c9900a8c88eeb585728b71289b","right_sha256":"a004daa449692a5878c901adbf6346d75d48afda8a845f7c494655c37bbeb7f4","left_boundary":"CONTEXT","right_boundary":"CONTEXT"}]}]
               ''')
  @original_manifest ~S'''
  91e002d6d186e3422371e3e613cd5944d36605024e1f17d54767e5d92dd06832  apps/singularity_core/lib/singularity/core/key_deriver.ex
  817d559c817c3f5a4dfd9dbdddc9d6d654ee5670cb0cc0550d66d185efc9922c  apps/singularity_core/lib/singularity/core/key_wrapper.ex
  57569c2d28ee36dca9af2a5ca916e99f867c60c8f8caefaa121201ce0320b997  apps/singularity_runtime/lib/singularity/runtime/backup_vault.ex
  3ecce1470e11d506435d8213faa1b2c0c012ffb360cb3e4b82f67bdd5277636e  apps/singularity_runtime/lib/singularity/runtime/download_lease.ex
  33a5eb62e2e8ff951dfddbb65cb029a66654a56bdab51e553a89e7d98d95b7bd  apps/singularity_runtime/lib/singularity/runtime/key_custodian.ex
  f9d073b3f8fb2ec7cfad9cdc7e221c43a52903b50c4e332341622f71a65315f5  apps/singularity_runtime/lib/singularity/runtime/restore_integrity_lease.ex
  6d16cae7f2765348c276d5df6ed96e5c4eea610f5d1c42c62094c989e635e3fc  apps/singularity_runtime/lib/singularity/runtime/restore_vault.ex
  73f59954893e0408fe1d7a88a13f17a378f6ac89c80663248a1aaffb8fbab21c  apps/singularity_storage/lib/singularity/storage/backup/bundle_reader.ex
  78e21cf1ecaa4a25df4ba3b1ca877dfb8d975de0893f3b9b71bbf472b4225065  apps/singularity_storage/lib/singularity/storage/backup/bundle_writer.ex
  2f8223eead8b66121936c671b115710dd87a3a380a256407dc4e0d8f15c6e462  apps/singularity_storage/lib/singularity/storage/backup/local_destination.ex
  ba0722ca85ce0a1259ce650927aa53ed728db0b28467adf308c3ada5a03036e8  apps/singularity_storage/lib/singularity/storage/backup/logical_schema.ex
  992ef89fb52a91ccaa0d7cf2b3ae6607a465e7b345cca5d6c55a86c3fac9f3e6  apps/singularity_storage/lib/singularity/storage/backup/logical_schema_v2.ex
  a10e3159ea9efe64fca51bc7f6a8e7a2446c33f0f41501bd2e42e8c93588ed3f  apps/singularity_storage/lib/singularity/storage/backup/manifest.ex
  a08d8ee09aef77969caf040429c07e4c8a817051c98acd10080e8dcdbdc377d7  apps/singularity_storage/priv/repo/migrations/20260718000100_create_schemas.exs
  fe71cd5ce35523de7af3f58f85967e95d8b4e13357906dcbcc803193386c1f32  apps/singularity_storage/priv/repo/migrations/20260718000200_create_identity_and_vault_tables.exs
  dde10879fbdf82636821f4b80aaa6750f501a00c1ec0b89e061c99ea5bf7c87c  apps/singularity_storage/priv/repo/migrations/20260718000300_create_content_asset_tables.exs
  04901d591e52a3a486b55c53676142fd9555337bd9fd25ab892771c1a61d858a  apps/singularity_storage/priv/repo/migrations/20260718000400_create_outbox_and_jobs.exs
  20d01c1e372a720f6864eff44a729496c3c00ad0bf06e60658ee04adf0fbceea  apps/singularity_storage/priv/repo/migrations/20260718000500_create_audit_and_backup_tables.exs
  95947d8aa9acd5ca1cbb73b25d34e6aa4f10b7c2b3b1078e62af680e5987abcc  apps/singularity_storage/priv/repo/migrations/20260718000600_create_security_functions_rls_and_grants.exs
  3862518b7c77b19c1fd8d38cd5e356cc2a9c42bec35c03dcd5696da1c1a70597  apps/singularity_storage/priv/repo/migrations/20260718000700_create_asset_search_projection.exs
  4cc1ff4fcebed58e7fa1e345e1fdd16e8a97fb9ecfe6cded3e2eef6dba491c10  apps/singularity_storage/priv/repo/migrations/20260718000800_add_task11_authorization_functions.exs
  5f2580665fe9c09b4d4e5ef6a153d086a00977beb12c4d785fa7c57580230d8a  apps/singularity_storage/priv/repo/migrations/20260718000900_complete_asset_lifecycle_evidence.exs
  28b350ff7f204faef6864d731213c5f472f7ea1793cff1ec52de4e919c58bccd  apps/singularity_storage/priv/repo/migrations/20260722000100_skip_vault_locked_outbox_claims.exs
  dbe6f19a8c496d29eb19f19f0c0f1a2e3caea78361c3494fa044bb28ed6d1331  apps/singularity_storage/priv/repo/migrations/20260722000200_export_current_vault_owner_for_backup.exs
  480f38ac6369f1d15588d5da6d77ab4948a3ceb15e86644aff21aac0e181cecc  apps/singularity_storage/priv/repo/migrations/20260722000300_enforce_backup_manifest_tag_length.exs
  a90586ded49fdd32600cb35571b220903a46eec8e69cf9c8eb641bb82d85bd8f  apps/singularity_storage/priv/repo/migrations/20260722000400_harden_backup_repository.exs
  8aee14f94f834ffa89899df0bcc6f0c7a961f3f0c5a556e9b161dc3d0dbecf41  apps/singularity_storage/priv/repo/migrations/20260722000500_allow_restore_outbox_retirement_reasons.exs
  25bc5bd3a753b38eb59c69e09d7d06ac2073a1958934ed3993c32d28afe7dbb6  apps/singularity_storage/priv/repo/migrations/20260722000600_create_restore_import_sagas.exs
  1cf64ea5bbd05251a13242539a8bf109dea4c9d6fc84fcc7508346984ebbc6b2  apps/singularity_storage/priv/repo/migrations/20260722000700_harden_audit_event_contract.exs
  f0a8c67141f043f409f1aef6d86d8ea23d9f0c59f39256efd07a2d38ced91ce2  apps/singularity_storage/priv/repo/migrations/20260722000800_bind_anonymous_audit_fingerprint.exs
  aba4f15d4d9937f69a9451bebc3e14980ac077d24b37e824858c8746d30d46ae  apps/singularity_storage/priv/repo/migrations/20260722000900_expose_upload_stage_age.exs
  43b49032cc475b6b35e1120fcb4c5da60fde47c72a04064a58aca207b09379e1  apps/singularity_storage/priv/repo/migrations/20260722001000_guard_active_domain_key_envelopes.exs
  dbd0096e555958dd0a5e57868c738908dec5a1b88c819549de8ece45efbc7b42  apps/singularity_storage/priv/repo/migrations/20260728000100_secure_upload_grant_csrf.exs
  ec09d4953047684ac7fe2d3257877c6a520ed518286ee1f0f851c1ea42a08a80  apps/singularity_storage/priv/repo/migrations/20260729000100_retire_superseded_upload_grants.exs
  89d6ce8f89ef0693d0be59ac5d495764c6a5981f518fccc93ef00fd565feb4e7  apps/singularity_storage/priv/repo/migrations/20260818000100_create_private_markdown_notes.exs
  f69a5337dc62a651378368c71cfe8086ec82d6f8ee628e918a70f83450fc2e55  apps/singularity_storage/priv/repo/migrations/20260901000100_defer_resource_version_classification_fkey.exs
  f6cb0c6b42a8a24181c7911ffc3d9849a91c4f76735f5a92392635bbd5f6553b  apps/singularity_storage/priv/repo/migrations/20260901000200_move_wake_generations_to_job_submissions.exs
  e38cd065ea6927337b091954ab031d533da87877dadedaeef8f0bf57715c3619  apps/singularity_storage/priv/repo/migrations/20260906000100_create_document_aggregate.exs
  368a2e261d407192dcd2238051aa80971f1a4c3403a21ad9ab8ae655f55f1b97  apps/singularity_storage/priv/repo/migrations/20260906000200_create_document_fragments_and_lifecycle.exs
  6d783afa4cfa06a0a00b3457e149f40007375e54df007a4b28f33ff2b32f5176  apps/singularity_storage/priv/repo/migrations/20260906000300_create_knowledge_links_and_organization.exs
  424c010993aeb3973c6b52158601b96c6c742b55b925f82f2de2c99e890ec869  apps/singularity_storage/priv/repo/migrations/20260922000000_backup_unsupported_guard.exs
  2d7643879404c7e7503f73de4da5a219a0e54255b1e38ded6b4652d391ac15ce  apps/singularity_storage/priv/repo/migrations/20260922000050_document_source_pin_count.exs
  3721cfdb4d40c9ca2022c505bbebedf3cc545b5a9670839dd54720bbe5873b57  apps/singularity_storage/priv/repo/migrations/20260922000100_document_extraction_attempts.exs
  1418913758a6e73b6cefa03491646919a83de764ee225d11ed6dc09e8e5cc9d5  apps/singularity_storage/priv/repo/migrations/20260922000110_document_terminal_tombstone.exs
  22093b4b52a2dcb7edafa0532e640d3d06ef47fac11d1d1bc729cfa0d683a248  apps/singularity_storage/priv/repo/migrations/20260922000200_document_extraction_recovery.exs
  c0f2ffb28dc6353d41f10090f8d979f298398364e7331c2f7f47c6a11572f324  apps/singularity_storage/priv/repo/migrations/20260922000250_document_custody_binding.exs
  3f64863ed9da5200959216b5744b4f3583cbbf05666ca817df11bd46d5885673  apps/singularity_storage/priv/repo/migrations/20260922000300_document_runtime_mutations.exs
  cfad64a7c19ae04d83ca2a993db2fa9512e6cf5589b2707f535aabee13a92724  apps/singularity_storage/priv/repo/migrations/20261008000000_document_worker_bridge.exs
  b07003c4b3c2150ba75f1f3bbf2298c6e54e0f346aee0019770cc6a1166b1aad  apps/singularity_storage/priv/repo/migrations/20261009000100_create_unified_search_projection.exs
  b162f30ed7762521f7443012a46e06ce9edc49c07693676ccfb6ff61bebcb2d8  apps/singularity_storage/priv/repo/migrations/20261009000200_unified_search_reconciliation.exs
  c9bb0dc60e7be1e622ee7134fbdc2d2aad318e5a88367d5eabb73ff2fc1b51ad  apps/singularity_storage/priv/repo/migrations/20261009000300_document_projection_events.exs
  4d27ebd036399bce0426935e18859b34d98e1da1a1d7cc538bcdc3168981c991  apps/singularity_storage/priv/repo/migrations/20261009000400_document_projection_worker.exs
  5254c58509393090dfdf67e9e3e1570c7eea8ba72fad0b4c63c70b60f615de26  apps/singularity_storage/priv/repo/migrations/20261010000000_create_guarded_search_candidates.exs
  af97a33001c9eb3986d98db483849e7cb354bd006ac286b8c4a089bebedb7d8c  apps/singularity_storage/priv/repo/migrations/20261011000000_seal_note_source_sets.exs
  9481823b2c5ca91f95e137c62d7e8eaa88a399abd8345f2d3c5a33b9098f5a3e  apps/singularity_storage/priv/repo/migrations/20261011000100_knowledge_runtime_grants.exs
  750487d30355c36d1834d3000a524f8a9c55a6ade1aaddaead99baf779e8fc59  apps/singularity_storage/priv/repo/migrations/20261011000200_knowledge_asset_lifecycle_guards.exs
  '''
  @original_manifest_sha "d0296d241c66e382baa09a0a092fe8add6df66364d5f2d5644f4f4ea1963a050"
  @unchanged_callers [
    {"apps/singularity_runtime/lib/singularity/runtime/assets/download.ex",
     "983813d9244620c030292fe47db20c234a75b3cc891807f799a6b4eedb58780e"},
    {"apps/singularity_runtime/lib/singularity/runtime/knowledge/export_read.ex",
     "9e7e20f235345627eee93a824b0b652a2b8cd582e657f9f92cc2a4716c00a091"}
  ]

  # BEGIN Task16 Read caller compatibility literals
  # Reviewed raw bytes, not expectations derived from the candidate at test time.
  @read_transition Jason.decode!(~S'''
                   {"path":"apps/singularity_runtime/lib/singularity/runtime/knowledge/export_read.ex","candidate_sha256":"5377afeb0858e1d3bcd40c939a263b517ecb4454e9a7ff2f09ed46b3ede59ebb","original_sha256":"9e7e20f235345627eee93a824b0b652a2b8cd582e657f9f92cc2a4716c00a091","block":"  # BEGIN Task16 committed transfer reads\n  # Only an Artifact owner may use these committed-transfer entrypoints. The\n  # companion owns acquisition even when the first COMMIT loses the local lease.\n  def asset_for_export(runtime, session, binding) do\n    safely(fn ->\n      validate_request!(runtime, session)\n      validate_asset!(binding)\n      context = transfer_context!(runtime)\n      owner = self()\n\n      pass = fn acc, consumer ->\n        transfer_asset_pass(runtime, session, binding, context, owner, acc, consumer)\n      end\n\n      descriptor(pass, binding[\"plaintext_byte_size\"], nil)\n    end)\n  end\n\n  def document_for_export(runtime, session, captured) do\n    safely(fn ->\n      validate_request!(runtime, session)\n      exact_keys!(captured, [:version, :source])\n      version = captured.version\n      map_keys!(version, @version_keys)\n      validate_asset!(captured.source)\n      ids!(version, ~w(resource_id version_id))\n      digest!(version[\"original_digest\"])\n\n      unless version[\"kind\"] == \"document\" and is_integer(version[\"original_byte_size\"]) and\n               version[\"original_byte_size\"] in 0..@document_bytes and\n               version[\"original_byte_size\"] == captured.source[\"plaintext_byte_size\"],\n             do: fail(:integrity_failure)\n\n      context = transfer_context!(runtime)\n      owner = self()\n\n      pass = fn acc, consumer ->\n        transfer_document_pass(runtime, session, captured, context, owner, acc, consumer)\n      end\n\n      descriptor(pass, version[\"original_byte_size\"], version[\"original_digest\"])\n    end)\n  end\n\n  defp transfer_context!(runtime) do\n    case {Map.get(runtime, :custodian), Map.get(runtime, :authenticated_reader)} do\n      {{Singularity.Runtime.Knowledge.ExportArtifact.Leases, context},\n       {Singularity.Runtime.Knowledge.ExportArtifact.Leases, context}}\n      when is_map(context) ->\n        exact_keys!(context, [:companion, :operation_ref, :reader])\n\n        unless is_pid(context.companion) and node(context.companion) == node() and\n                 context.companion != self() and Process.alive?(context.companion) and\n                 is_reference(context.operation_ref) and transfer_reader?(context.reader),\n               do: fail(:invalid)\n\n        context\n\n      _ ->\n        fail(:invalid)\n    end\n  end\n\n  defp transfer_reader?(module) when is_atom(module), do: module not in [nil, true, false]\n\n  defp transfer_reader?({module, _context}) when is_atom(module),\n    do: module not in [nil, true, false]\n\n  defp transfer_reader?(_reader), do: false\n\n  defp transfer_validate!(runtime, session, context, owner) do\n    unless self() == owner, do: fail(:invalid)\n    validate_request!(runtime, session)\n    unless transfer_context!(runtime) === context, do: fail(:invalid)\n  end\n\n  defp transfer_requirement(session) do\n    %{\n      vault_id: session.vault_id,\n      required_capability: \"asset.read\",\n      classification: :private,\n      requires_unlocked?: true,\n      principal_authorization_epoch: session.principal_authorization_epoch,\n      vault_authorization_epoch: session.vault_authorization_epoch\n    }\n  end\n\n  defp transfer_asset_pass(runtime, session, binding, context, owner, acc, consumer) do\n    transfer_validate!(runtime, session, context, owner)\n    size = binding[\"plaintext_byte_size\"]\n    initial = {acc, :crypto.hash_init(:sha256), 0}\n\n    result =\n      if size == 0 do\n        unless transfer_asset_read!(runtime, session, binding, :zero, context) == \"\",\n          do: fail(:integrity_failure)\n\n        initial\n      else\n        Enum.reduce(0..div(size - 1, @piece_bytes), initial, fn index, state ->\n          first = index * @piece_bytes\n          range = first..min(first + @piece_bytes - 1, size - 1)\n          bytes = transfer_asset_read!(runtime, session, binding, range, context)\n\n          unless is_binary(bytes) and byte_size(bytes) == range.last - range.first + 1,\n            do: fail(:integrity_failure)\n\n          validate_request!(runtime, session)\n          consume!(bytes, state, consumer)\n        end)\n      end\n\n    asset_guard!(runtime, session, binding, if(size == 0, do: :zero, else: 0..0))\n    result\n  end\n\n  defp transfer_asset_read!(runtime, session, binding, mode, context) do\n    requirement = transfer_requirement(session)\n\n    unwrap!(\n      OperationScope.with_read_request(runtime, session, requirement, fn repo ->\n        with :ok <- call(repository(runtime), :lock_asset_source, [repo, binding, mode]),\n             {:ok, lease} <-\n               Singularity.Runtime.Knowledge.ExportArtifact.Leases.lease(\n                 context,\n                 transfer_asset_request(session, binding)\n               ),\n             :ok <- call(repository(runtime), :lock_asset_source, [repo, binding, mode]) do\n          {:after_commit_scoped,\n           fn run_scoped ->\n             try do\n               validate_request!(runtime, session)\n\n               bytes =\n                 unwrap!(\n                   Singularity.Runtime.Knowledge.ExportArtifact.Leases.read(\n                     context,\n                     lease,\n                     if(mode == :zero, do: :all, else: mode)\n                   )\n                 )\n\n               transfer_asset_post!(run_scoped, runtime, session, binding, mode, requirement)\n               {:ok, bytes}\n             after\n               revoke({Singularity.Runtime.Knowledge.ExportArtifact.Leases, context}, lease)\n             end\n           end}\n        else\n          {:error, %Error{}} = error -> error\n          _ -> {:error, Error.new(:integrity_failure)}\n        end\n      end)\n    )\n  end\n\n  defp transfer_asset_post!(run_scoped, runtime, session, binding, mode, requirement) do\n    audit = Map.get(runtime, :audit, Singularity.Storage.Postgres.AuditSink)\n    correlation_id = Ecto.UUID.generate()\n\n    case run_scoped.(fn repo ->\n           with :ok <-\n                  Singularity.Runtime.Authorize.check(\n                    runtime.authorization,\n                    repo,\n                    session,\n                    requirement\n                  ),\n                :ok <- call(repository(runtime), :lock_asset_source, [repo, binding, mode]),\n                :ok <-\n                  Singularity.Runtime.Audit.append_principal(audit, repo, session, %{\n                    action: \"asset.downloaded\",\n                    result: :completed,\n                    classification: :private,\n                    correlation_id: correlation_id,\n                    target_type: \"asset\",\n                    target_id: binding[\"asset_id\"],\n                    metadata: %{}\n                  }) do\n             :ok\n           end\n         end) do\n      :ok -> validate_request!(runtime, session)\n      {:error, reason} -> raise_error!(reason)\n      _ -> fail(:integrity_failure)\n    end\n  end\n\n  defp transfer_asset_request(session, binding) do\n    %{\n      job_id: binding[\"asset_id\"],\n      purpose: :download,\n      session_id: session.session_id,\n      principal_id: session.principal_id,\n      vault_id: session.vault_id,\n      principal_authorization_epoch: session.principal_authorization_epoch,\n      vault_authorization_epoch: session.vault_authorization_epoch,\n      required_capability: \"asset.read\",\n      object_id: binding[\"object_id\"],\n      object_generation: binding[\"object_generation\"]\n    }\n  end\n\n  defp transfer_document_pass(runtime, session, captured, context, owner, acc, consumer) do\n    transfer_validate!(runtime, session, context, owner)\n    requirement = transfer_requirement(session)\n\n    unwrap!(\n      OperationScope.with_read_request(runtime, session, requirement, fn repo ->\n        with {:ok, binding} <- call(repository(runtime), :document_source, [repo, captured]),\n             :ok <- transfer_document_binding!(captured, binding),\n             {:ok, lease} <-\n               Singularity.Runtime.Knowledge.ExportArtifact.Leases.lease(\n                 context,\n                 transfer_document_request(session, binding)\n               ),\n             {:ok, ^binding} <- call(repository(runtime), :document_source, [repo, captured]) do\n          {:after_commit_scoped,\n           fn run_scoped ->\n             try do\n               validate_request!(runtime, session)\n\n               guard = fn ->\n                 transfer_document_guard!(\n                   run_scoped,\n                   runtime,\n                   session,\n                   captured,\n                   binding,\n                   requirement\n                 )\n               end\n\n               initial = {acc, :crypto.hash_init(:sha256), 0}\n               size = binding.source_byte_size\n\n               result =\n                 if size == 0 do\n                   case Singularity.Runtime.Knowledge.ExportArtifact.Leases.authenticate_empty_document_original(\n                          context,\n                          lease\n                        ) do\n                     :ok -> :ok\n                     {:error, reason} -> raise_error!(reason)\n                     _ -> fail(:integrity_failure)\n                   end\n\n                   guard.()\n                   initial\n                 else\n                   Enum.reduce(0..div(size - 1, @native_bytes), initial, fn ordinal, state ->\n                     if ordinal > 0, do: guard.()\n\n                     bytes =\n                       unwrap!(\n                         Singularity.Runtime.Knowledge.ExportArtifact.Leases.read_document_chunk(\n                           context,\n                           lease,\n                           ordinal\n                         )\n                       )\n\n                     guard.()\n                     expected_size = min(@native_bytes, size - ordinal * @native_bytes)\n\n                     unless is_binary(bytes) and byte_size(bytes) == expected_size,\n                       do: fail(:integrity_failure)\n\n                     split_document!(bytes, state, consumer, guard)\n                   end)\n                 end\n\n               guard.()\n               {:ok, result}\n             after\n               revoke({Singularity.Runtime.Knowledge.ExportArtifact.Leases, context}, lease)\n             end\n           end}\n        else\n          {:error, %Error{}} = error -> error\n          _ -> {:error, Error.new(:integrity_failure)}\n        end\n      end)\n    )\n  end\n\n  defp transfer_document_guard!(run_scoped, runtime, session, captured, binding, requirement) do\n    case run_scoped.(fn repo ->\n           with :ok <-\n                  Singularity.Runtime.Authorize.check(\n                    runtime.authorization,\n                    repo,\n                    session,\n                    requirement\n                  ),\n                {:ok, ^binding} <- call(repository(runtime), :document_source, [repo, captured]) do\n             :ok\n           else\n             {:error, %Error{}} = error -> error\n             _ -> {:error, Error.new(:integrity_failure)}\n           end\n         end) do\n      :ok -> validate_request!(runtime, session)\n      {:error, reason} -> raise_error!(reason)\n      _ -> fail(:integrity_failure)\n    end\n  end\n\n  defp transfer_document_binding!(captured, binding) do\n    unless binding.resource_id == captured.version[\"resource_id\"] and\n             binding.resource_version_id == captured.version[\"version_id\"] and\n             binding.object_id == captured.source[\"object_id\"] and\n             binding.object_generation == captured.source[\"object_generation\"] and\n             binding.source_byte_size == captured.version[\"original_byte_size\"] and\n             hex(binding.source_digest) == captured.version[\"original_digest\"],\n           do: fail(:integrity_failure)\n\n    :ok\n  end\n\n  defp transfer_document_request(session, binding) do\n    %{\n      purpose: :document_source,\n      access: :request,\n      session_id: session.session_id,\n      principal_id: session.principal_id,\n      vault_id: session.vault_id,\n      principal_authorization_epoch: session.principal_authorization_epoch,\n      vault_authorization_epoch: session.vault_authorization_epoch,\n      required_capability: \"asset.read\",\n      resource_version_id: binding.resource_version_id,\n      object_id: binding.object_id,\n      object_generation: binding.object_generation\n    }\n  end\n\n  # END Task16 committed transfer reads\n\n","left":"  def note(runtime, session, binding), do: text(runtime, session, binding, :note)\n  def fragment(runtime, session, binding), do: text(runtime, session, binding, :fragment)\n\n","right":"  defp text(runtime, session, binding, kind) do\n    safely(fn ->\n","begin":"  # BEGIN Task16 committed transfer reads\n","end":"  # END Task16 committed transfer reads\n\n","block_bytes":12264,"left_bytes":173,"right_bytes":65,"context_offset":3534,"block_sha256":"4d0da4e78d2dceef190f7fd8e55baec1a7f0a2fe739ec642cd913b6c938c5cdb","left_sha256":"5840c6cd9d15fcdd704a3e67786a277df54867e72d3ef9eae1357de8030b9435","right_sha256":"9e2c742b5c01f493b492a73a5ea095823444c853629ce26f2832d64594ff679a","old_context_sha256":"414b8cbb01f08e8ee033a7caae5e75db8035236c7940cd523c500ce0e5700463","new_context_sha256":"5ae7c43aee58778b52ea735528987a8b4a5d868deb32bccb5200ec3955490460"}
                   ''')
  # END Task16 Read caller compatibility literals

  # BEGIN Task16 Read caller compatibility tests
  test "Read transition literals retain the reviewed body and both raw context edges" do
    for field <- ["block", "left", "right"] do
      assert byte_size(@read_transition[field]) == @read_transition[field <> "_bytes"]
      assert sha(@read_transition[field]) == @read_transition[field <> "_sha256"]
    end

    assert sha(@read_transition["left"] <> @read_transition["right"]) ==
             @read_transition["old_context_sha256"]

    assert sha(@read_transition["left"] <> @read_transition["block"] <> @read_transition["right"]) ==
             @read_transition["new_context_sha256"]
  end

  test "raw Read candidate strictly reconstructs the old caller without normalizing other paths" do
    source = File.read!(Path.join(@repo_root, @read_transition["path"]))
    assert sha(source) == @read_transition["candidate_sha256"]
    assert {:ok, original} = read_transfer_inverse(source)
    assert sha(original) == @read_transition["original_sha256"]
    assert read_source(@read_transition["path"]) == original

    for path <-
          Enum.map(@transitions, & &1["path"]) ++
            ["apps/singularity_runtime/lib/singularity/runtime/assets/download.ex"] do
      assert read_source(path) == File.read!(Path.join(@repo_root, path))
    end
  end

  for {mutation, reason} <- [
        missing: :missing_read_block,
        changed: :changed_read_block,
        duplicate: :duplicate_read_block,
        duplicate_context: :duplicate_read_block,
        block_relocation: :read_block_location,
        context_relocation: :read_context_location,
        left: :read_left_context,
        right: :read_right_context,
        both: :read_both_contexts,
        coexistence: :read_old_new_coexistence,
        legacy_byte: :read_original_hash,
        new_outside_bytes: :read_original_hash,
        old_raw: :missing_read_block
      ] do
    @read_mutation mutation
    @read_reason reason
    test "raw Read transition rejects #{@read_mutation} at its exact inverse boundary" do
      source = File.read!(Path.join(@repo_root, @read_transition["path"]))
      assert {:ok, original} = read_transfer_inverse(source)
      assert sha(source) == @read_transition["candidate_sha256"]
      assert sha(original) == @read_transition["original_sha256"]
      block = @read_transition["block"]
      left = @read_transition["left"]
      right = @read_transition["right"]
      context = left <> block <> right

      mutated =
        case @read_mutation do
          :missing ->
            String.replace(source, block, "", global: false)

          :changed ->
            changed = String.replace(block, "Only an Artifact", "Only aN Artifact", global: false)
            String.replace(source, block, changed, global: false)

          :duplicate ->
            source <> block

          :duplicate_context ->
            source <> context

          :block_relocation ->
            String.replace(source, block, "", global: false) <> block

          :context_relocation ->
            String.replace(source, context, "", global: false) <> context

          :left ->
            String.replace(source, context, corrupt_edge(left) <> block <> right, global: false)

          :right ->
            String.replace(source, context, left <> block <> corrupt_edge(right), global: false)

          :both ->
            String.replace(source, context, corrupt_edge(left) <> block <> corrupt_edge(right),
              global: false
            )

          :coexistence ->
            source <> left <> right

          :legacy_byte ->
            String.replace(source, "@piece_bytes 65_536", "@piece_bytes 65_537", global: false)

          :new_outside_bytes ->
            source <> "# unreviewed outside addition\n"

          :old_raw ->
            original
        end

      assert mutated != source
      assert read_transfer_inverse(mutated) == {:error, @read_reason}
    end
  end

  # END Task16 Read caller compatibility tests

  test "the original 56-file manifest remains literal and only the two approved paths differ" do
    assert sha(@original_manifest) == @original_manifest_sha
    entries = manifest_entries()
    assert length(entries) == 56

    changed =
      for {path, hash} <- entries,
          sha(read_source(path)) != hash,
          do: path

    assert changed == Enum.map(@transitions, & &1["path"])
    assert length(entries) - length(changed) == 54

    for transition <- @transitions do
      assert {transition["path"], transition["original_sha256"]} in entries
    end
  end

  test "the exact transition table contains unique bounded hunks and both context edges" do
    assert Enum.map(@transitions, &length(&1["hunks"])) == [12, 4]

    for transition <- @transitions,
        hunk <- transition["hunks"] do
      assert hunk["old"] != hunk["new"]
      assert hunk["old"] == hunk["left"] <> hunk["old_body"] <> hunk["right"]
      assert hunk["new"] == hunk["left"] <> hunk["new_body"] <> hunk["right"]

      for field <- ["old", "new", "left", "right"] do
        assert sha(hunk[field]) == hunk[field <> "_sha256"]
      end

      assert hunk["left_boundary"] == if(hunk["left"] == "", do: "BOF", else: "CONTEXT")
      assert hunk["right_boundary"] == "CONTEXT"
      assert hunk["right"] != ""
      assert length(:binary.matches(read_source(transition["path"]), hunk["new"])) == 1
    end
  end

  test "ordinary download and export read callers remain byte-identical" do
    for {path, hash} <- @unchanged_callers, do: assert(sha(read_source(path)) == hash)
  end

  for {transition, file_index} <- Enum.with_index(@transitions) do
    @transition transition
    test "inverse file #{file_index} reconstructs its exact original raw frozen hash" do
      source = read_source(@transition["path"])
      assert accepted?(source, @transition)
      assert sha(source) == @transition["candidate_sha256"]
      assert {:ok, original} = inverse_source(source, @transition)
      assert sha(original) == @transition["original_sha256"]
    end

    test "file #{file_index} rejects an unrelated legacy mutation" do
      source = read_source(@transition["path"])
      assert accepted?(source, @transition)

      mutated =
        if String.ends_with?(@transition["path"], "/download_lease.ex"),
          do: String.replace(source, "@lease_seconds 60", "@lease_seconds 61", global: false),
          else:
            String.replace(
              source,
              "@default_pending_ttl_ms :timer.seconds(30)",
              "@default_pending_ttl_ms :timer.seconds(31)",
              global: false
            )

      assert mutated != source
      accepted = accepted?(mutated, @transition)
      refute accepted
    end

    for hunk <- transition["hunks"],
        mutation <- [
          :missing,
          :reverted,
          :altered,
          :duplicate,
          :relocated,
          :left,
          :right,
          :coexistence
        ] do
      @hunk hunk
      @mutation mutation
      test "file #{file_index} hunk #{hunk["id"]} rejects #{mutation}" do
        source = read_source(@transition["path"])
        assert accepted?(source, @transition)
        mutated = mutate(source, @hunk, @mutation)
        assert mutated != source
        accepted = accepted?(mutated, @transition)
        refute accepted
      end
    end
  end

  for mutation <- [:extra_clause, :extra_request_field, :changed_registration] do
    @mutation mutation
    test "custodian rejects #{@mutation} beyond the exact native seam" do
      transition = Enum.find(@transitions, &String.ends_with?(&1["path"], "/key_custodian.ex"))
      source = read_source(transition["path"])
      assert accepted?(source, transition)

      mutated =
        case @mutation do
          :extra_clause ->
            source <>
              "\ndef handle_call(:unexpected_export, _from, state), do: {:reply, :ok, state}\n"

          :extra_request_field ->
            String.replace(source, "@request_fields ~w[", "@request_fields ~w[ owner_pid",
              global: false
            )

          :changed_registration ->
            String.replace(
              source,
              "register_lease(state, binding, lease)",
              "register_lease(state, binding, nil)",
              global: false
            )
        end

      assert mutated != source
      accepted = accepted?(mutated, transition)
      refute accepted
    end
  end

  # BEGIN Task16 Read caller compatibility helpers
  defp read_transfer_inverse(source) do
    blocks = :binary.matches(source, @read_transition["block"])
    starts = :binary.matches(source, @read_transition["begin"])
    stops = :binary.matches(source, @read_transition["end"])

    cond do
      length(blocks) > 1 or length(starts) > 1 or length(stops) > 1 ->
        {:error, :duplicate_read_block}

      blocks == [] and starts == [] and stops == [] ->
        {:error, :missing_read_block}

      length(blocks) != 1 or length(starts) != 1 or length(stops) != 1 ->
        {:error, :changed_read_block}

      true ->
        [{offset, _length}] = blocks
        read_transfer_context_inverse(source, offset)
    end
  end

  defp read_transfer_context_inverse(source, offset) do
    left = @read_transition["left"]
    right = @read_transition["right"]
    block = @read_transition["block"]
    contexts = :binary.matches(source, left <> block <> right)
    old_contexts = :binary.matches(source, left <> right)
    after_block = offset + byte_size(block)

    left? =
      offset >= byte_size(left) and
        binary_part(source, offset - byte_size(left), byte_size(left)) == left

    right? =
      byte_size(source) >= after_block + byte_size(right) and
        binary_part(source, after_block, byte_size(right)) == right

    cond do
      contexts != [] and old_contexts != [] ->
        {:error, :read_old_new_coexistence}

      old_contexts != [] ->
        {:error, :read_block_location}

      not left? and not right? ->
        {:error, :read_both_contexts}

      not left? ->
        {:error, :read_left_context}

      not right? ->
        {:error, :read_right_context}

      contexts != [{@read_transition["context_offset"], byte_size(left <> block <> right)}] ->
        {:error, :read_context_location}

      true ->
        original = String.replace(source, block, "", global: false)

        cond do
          sha(original) != @read_transition["original_sha256"] ->
            {:error, :read_original_hash}

          sha(source) != @read_transition["candidate_sha256"] ->
            {:error, :read_candidate_hash}

          true ->
            {:ok, original}
        end
    end
  end

  defp read_source(
         "apps/singularity_runtime/lib/singularity/runtime/knowledge/export_read.ex" = path
       ) do
    assert {:ok, original} = read_transfer_inverse(File.read!(Path.join(@repo_root, path)))
    original
  end

  # END Task16 Read caller compatibility helpers

  defp read_source(path), do: File.read!(Path.join(@repo_root, path))
  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp manifest_entries do
    @original_manifest
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [hash, path] = String.split(line, "  ", parts: 2)
      {path, hash}
    end)
  end

  defp mutate(source, hunk, :missing),
    do: replace_hunk(source, hunk, hunk["left"] <> hunk["right"])

  defp mutate(source, hunk, :reverted), do: replace_hunk(source, hunk, hunk["old"])

  defp mutate(source, hunk, :altered),
    do:
      replace_hunk(
        source,
        hunk,
        hunk["left"] <> "# changed native hunk\n" <> hunk["new_body"] <> hunk["right"]
      )

  defp mutate(source, hunk, :duplicate),
    do: replace_hunk(source, hunk, hunk["new"] <> hunk["new"])

  defp mutate(source, hunk, :relocated),
    do: replace_hunk(source, hunk, "") <> hunk["new"]

  defp mutate(source, %{"left" => ""}, :left), do: "# outside BOF\n" <> source

  defp mutate(source, hunk, :left),
    do:
      replace_hunk(source, hunk, corrupt_edge(hunk["left"]) <> hunk["new_body"] <> hunk["right"])

  defp mutate(source, hunk, :right),
    do:
      replace_hunk(source, hunk, hunk["left"] <> hunk["new_body"] <> corrupt_edge(hunk["right"]))

  defp mutate(source, hunk, :coexistence),
    do: replace_hunk(source, hunk, hunk["new"] <> hunk["old"])

  defp replace_hunk(source, hunk, replacement),
    do: String.replace(source, hunk["new"], replacement, global: false)

  defp corrupt_edge(<<_first, rest::binary>>), do: "#" <> rest

  defp accepted?(source, transition),
    do: match?({:ok, _original}, inverse_source(source, transition))

  defp inverse_source(source, transition) do
    inverse =
      Enum.reduce_while(transition["hunks"], {:ok, source}, fn hunk, {:ok, current} ->
        case :binary.matches(current, hunk["new"]) do
          [{offset, _length}] ->
            if hunk["left_boundary"] == "BOF" and offset != 0 do
              {:halt, {:error, :outside_exact_transition}}
            else
              {:cont, {:ok, String.replace(current, hunk["new"], hunk["old"], global: false)}}
            end

          _missing_or_duplicate ->
            {:halt, {:error, :outside_exact_transition}}
        end
      end)

    case inverse do
      {:ok, original} ->
        if sha(original) == transition["original_sha256"],
          do: {:ok, original},
          else: {:error, :outside_exact_transition}

      {:error, _reason} = error ->
        error
    end
  end
end
