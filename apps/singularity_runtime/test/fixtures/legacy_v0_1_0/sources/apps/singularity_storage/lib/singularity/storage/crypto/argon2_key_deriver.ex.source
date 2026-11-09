defmodule Singularity.Storage.Crypto.Argon2KeyDeriver do
  @moduledoc """
  Versioned, domain-separated Argon2id derivation of the vault wrapping KEK.

  This raw derivation is deliberately separate from credential verification.
  """

  @behaviour Singularity.Core.KeyDeriver

  alias Singularity.Core.Error

  @version 1
  @domain "singularity:v1:vault-kek:"

  @impl true
  def derive(password, salt, params)
      when is_binary(password) and byte_size(password) > 0 and is_binary(salt) and
             byte_size(salt) >= 8 do
    with {:ok, options} <- options(params) do
      key =
        (@domain <> password)
        |> Argon2.Base.hash_password(salt, options)
        |> Base.decode16!(case: :mixed)

      {:ok, key}
    end
  rescue
    ArgumentError -> {:error, Error.new(:invalid)}
  end

  def derive(_password, _salt, _params), do: {:error, Error.new(:invalid)}

  defp options(%{
         version: @version,
         t_cost: t_cost,
         m_cost: m_cost,
         parallelism: parallelism
       })
       when is_integer(t_cost) and t_cost > 0 and is_integer(m_cost) and
              m_cost >= 8 and is_integer(parallelism) and parallelism > 0 do
    {:ok,
     [
       t_cost: t_cost,
       m_cost: m_cost,
       parallelism: parallelism,
       hashlen: 32,
       argon2_type: 2,
       format: :raw_hash
     ]}
  end

  defp options(_params), do: {:error, Error.new(:invalid)}
end
