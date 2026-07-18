defmodule Singularity.Runtime.DeferredPlaintextAdapter do
  @moduledoc """
  Fails plaintext lease work closed until the Task 12 reader is composed.

  Task 11 still starts the custody process in development and production so
  unlock, lock, and revocation have one supervised owner. No object key or
  plaintext reader is fabricated at this boundary.
  """

  alias Singularity.Core.Error

  @spec utc_now(term()) :: DateTime.t()
  def utc_now(_context), do: DateTime.utc_now()

  @spec revalidate(term(), map()) :: {:error, Error.t()}
  def revalidate(_context, _binding), do: unavailable()

  @spec load_object_key(term(), map(), map()) :: {:error, :waiting_for_unlock}
  def load_object_key(_context, _binding, _hierarchy),
    do: {:error, :waiting_for_unlock}

  @spec load_checkpoint(term(), map()) :: {:error, Error.t()}
  def load_checkpoint(_context, _binding), do: unavailable()

  @spec read_chunk(term(), map(), non_neg_integer()) :: {:error, Error.t()}
  def read_chunk(_context, _binding, _index), do: unavailable()

  @spec persist_checkpoint(term(), map(), map(), map()) :: {:error, Error.t()}
  def persist_checkpoint(_context, _binding, _expected, _next), do: unavailable()

  defp unavailable, do: {:error, Error.new(:job_failed)}
end
