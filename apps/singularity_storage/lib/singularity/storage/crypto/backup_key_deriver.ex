defmodule Singularity.Storage.Crypto.BackupKeyDeriver do
  @moduledoc """
  Derives the backup bundle key from the single supported public KDF profile.

  The persisted memory cost is expressed in KiB. It is translated to the
  logarithmic value expected by `argon2_elixir` only after the complete public
  profile has matched the allowlist.
  """

  alias Singularity.Core.Error

  @domain "singularity.backup.bundle.v1"
  @input_domain "singularity:v1:backup-bundle:"
  @parameters %{
    "m_cost" => 65_536,
    "parallelism" => 2,
    "t_cost" => 5,
    "version" => 4
  }
  @argon2_memory_cost 16

  @spec profile() :: %{domain: String.t(), parameters: map()}
  def profile, do: %{domain: @domain, parameters: @parameters}

  @spec derive(binary(), map()) :: {:ok, <<_::256>>} | {:error, Error.t()}
  def derive(
        passphrase,
        %{
          domain: @domain,
          parameters: parameters,
          salt: <<_::binary-size(16)>> = salt
        } = kdf
      )
      when is_binary(passphrase) and passphrase != "" and map_size(kdf) == 3 and
             parameters == @parameters do
    key =
      (@input_domain <> passphrase)
      |> Argon2.Base.hash_password(
        salt,
        t_cost: 5,
        m_cost: @argon2_memory_cost,
        parallelism: 2,
        hashlen: 32,
        argon2_type: 2,
        format: :raw_hash
      )
      |> Base.decode16!(case: :mixed)

    case key do
      <<_::binary-size(32)>> -> {:ok, key}
      _invalid -> backup_invalid()
    end
  rescue
    _exception -> backup_invalid()
  catch
    _kind, _reason -> backup_invalid()
  end

  def derive(_passphrase, _kdf), do: backup_invalid()

  defp backup_invalid, do: {:error, Error.new(:backup_invalid)}
end
