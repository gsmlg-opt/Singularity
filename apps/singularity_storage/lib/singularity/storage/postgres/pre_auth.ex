defmodule Singularity.Storage.Postgres.PreAuth do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias Singularity.Core.Error

  def authentication_candidate(repo, login) when is_binary(login) do
    case SQL.query(
           repo,
           "SELECT * FROM identity.authentication_candidate($1)",
           [login],
           log: false
         ) do
      {:ok, %{rows: [[credential_id, account_id, verifier, verifier_version]]}} ->
        {:ok,
         %{
           credential_id: load_uuid(credential_id),
           account_id: load_uuid(account_id),
           verifier: verifier,
           verifier_version: verifier_version
         }}

      {:error, _reason} ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  def authentication_candidate(_repo, _login), do: {:error, Error.new(:invalid)}

  def resolve_session(repo, token_digest)
      when is_binary(token_digest) and byte_size(token_digest) == 32 do
    case SQL.query(
           repo,
           "SELECT * FROM identity.resolve_session($1)",
           [token_digest],
           log: false
         ) do
      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:ok, %{rows: [[session_id, principal_id, vault_id, expires_at]]}} ->
        {:ok,
         %{
           session_id: load_uuid(session_id),
           principal_id: load_uuid(principal_id),
           vault_id: load_uuid(vault_id),
           expires_at: expires_at
         }}

      {:error, _reason} ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  def resolve_session(_repo, _token_digest), do: {:error, Error.new(:invalid)}

  def record_auth_attempt(
        repo,
        %{
          login_fingerprint: login_fingerprint,
          source_fingerprint: source_fingerprint,
          result: result
        }
      )
      when is_binary(login_fingerprint) and byte_size(login_fingerprint) == 32 and
             is_binary(source_fingerprint) and byte_size(source_fingerprint) == 32 and
             result in [:started, :failed, :succeeded] do
    case SQL.query(
           repo,
           "SELECT * FROM identity.record_auth_attempt($1, $2, $3)",
           [login_fingerprint, source_fingerprint, Atom.to_string(result)],
           log: false
         ) do
      {:ok, %{rows: [[attempt_id, accepted?]]}} ->
        {:ok, %{attempt_id: load_uuid(attempt_id), accepted?: accepted?}}

      {:error, _reason} ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  def record_auth_attempt(_repo, _command), do: {:error, Error.new(:invalid)}

  defp load_uuid(nil), do: nil
  defp load_uuid(uuid), do: Ecto.UUID.load!(uuid)
end
