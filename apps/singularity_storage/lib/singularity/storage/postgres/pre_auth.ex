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
        account_id = load_uuid(account_id)

        {:ok,
         %{
           credential_id: load_uuid(credential_id),
           account_id: account_id,
           verifier: verifier,
           verifier_version: verifier_version,
           scoped_context: owner_scope(account_id)
         }}

      {:error, _reason} ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  def authentication_candidate(_repo, _login), do: {:error, Error.new(:invalid)}

  def reserve_attempt(repo, %{
        login_fingerprint: login_fingerprint,
        source_fingerprint: source_fingerprint,
        correlation_id: correlation_id
      })
      when is_binary(correlation_id) do
    case record_auth_attempt(repo, %{
           login_fingerprint: login_fingerprint,
           source_fingerprint: source_fingerprint,
           result: :started
         }) do
      {:ok, %{attempt_id: id, accepted?: accepted?}} ->
        {:ok, %{id: id, accepted?: accepted?}}

      {:error, %Error{}} = error ->
        error
    end
  end

  def reserve_attempt(_repo, _command), do: {:error, Error.new(:invalid)}

  def record_attempt(repo, %{
        login_fingerprint: login_fingerprint,
        source_fingerprint: source_fingerprint,
        correlation_id: correlation_id,
        result: "failed"
      })
      when is_binary(correlation_id) do
    case record_auth_attempt(repo, %{
           login_fingerprint: login_fingerprint,
           source_fingerprint: source_fingerprint,
           result: :failed
         }) do
      {:ok, _attempt} -> :ok
      {:error, %Error{}} = error -> error
    end
  end

  def record_attempt(_repo, _command), do: {:error, Error.new(:invalid)}

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

      {:ok,
       %{
         rows: [
           [
             session_id,
             principal_id,
             vault_id,
             expires_at,
             principal_authorization_epoch,
             vault_authorization_epoch
           ]
         ]
       }} ->
        {:ok,
         %{
           session_id: load_uuid(session_id),
           principal_id: load_uuid(principal_id),
           vault_id: load_uuid(vault_id),
           expires_at: expires_at,
           principal_authorization_epoch: principal_authorization_epoch,
           vault_authorization_epoch: vault_authorization_epoch
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

  defp owner_scope(nil), do: nil

  defp owner_scope(account_id) do
    %{
      account_id: account_id,
      principal_id: account_id,
      vault_id: account_id
    }
  end
end
