defmodule Singularity.Test.FakeRsync do
  @moduledoc """
  Test rsync runner. Sends `{:rsync, args}` to the calling process, then runs
  `Process.get(:fake_rsync)` (a `fn args -> :ok | {:error, reason} end`), or
  returns `:ok`.
  """

  @behaviour Singularity.Collectors.IetfRfc.Rsync

  @impl true
  def sync(args) do
    send(self(), {:rsync, args})

    case Process.get(:fake_rsync) do
      nil -> :ok
      fun -> fun.(args)
    end
  end
end
