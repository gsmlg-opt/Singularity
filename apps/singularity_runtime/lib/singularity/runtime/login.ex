defmodule Singularity.Runtime.Login do
  @moduledoc "Constant-shape pre-authentication and opaque session issuance."

  alias Singularity.Core.Error

  @login_label "singularity/auth-login/v1"
  @source_label "singularity/auth-source/v1"
  @opaque_token_bytes 32

  @spec run(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def run(
        adapters,
        %{
          login: login,
          password: password,
          source: source,
          correlation_id: correlation_id
        }
      )
      when is_map(adapters) and is_binary(login) and is_binary(password) and
             is_binary(source) and is_binary(correlation_id) do
    with {:ok, normalized_login} <- normalize(login),
         {:ok, normalized_source} <- normalize(source),
         :ok <- validate_secret(adapters.audit_fingerprint_secret),
         fingerprints <-
           fingerprints(
             adapters.audit_fingerprint_secret,
             normalized_login,
             normalized_source
           ),
         {:ok, %{id: attempt_id, accepted?: true}} <-
           adapters.pre_auth.reserve_attempt(adapters.pre_auth_context, %{
             login_fingerprint: fingerprints.login,
             source_fingerprint: fingerprints.source,
             correlation_id: correlation_id
           }) do
      authenticate_reserved(
        adapters,
        normalized_login,
        password,
        %{
          attempt_id: attempt_id,
          login_fingerprint: fingerprints.login,
          source_fingerprint: fingerprints.source,
          correlation_id: correlation_id
        }
      )
    else
      _failure -> unauthenticated()
    end
  rescue
    _error -> unauthenticated()
  end

  def run(_adapters, _request), do: unauthenticated()

  defp authenticate_reserved(adapters, normalized_login, password, command) do
    with {:ok, candidate} <-
           adapters.pre_auth.authentication_candidate(
             adapters.pre_auth_context,
             normalized_login
           ),
         {:ok, verified?} <-
           adapters.password_hasher.verify(
             adapters.password_hasher_context,
             password,
             candidate.verifier
           ) do
      finish(
        adapters,
        verified? and not is_nil(candidate.scoped_context),
        candidate,
        command
      )
    else
      _failure -> finish(adapters, false, nil, command)
    end
  rescue
    _error -> finish(adapters, false, nil, command)
  catch
    _kind, _reason -> finish(adapters, false, nil, command)
  end

  @spec fingerprints(binary(), binary(), binary()) :: %{
          login: binary(),
          source: binary()
        }
  def fingerprints(secret, normalized_login, normalized_source) do
    %{
      login: mac(secret, @login_label, normalized_login),
      source: mac(secret, @source_label, normalized_source)
    }
  end

  @spec cookie_payload(map()) :: %{required(String.t()) => String.t()}
  def cookie_payload(%{opaque_token: <<_::binary-size(@opaque_token_bytes)>> = token}) do
    %{"session" => Base.url_encode64(token, padding: false)}
  end

  defp finish(adapters, true, candidate, command) do
    token = adapters.random_bytes.(@opaque_token_bytes)

    if is_binary(token) and byte_size(token) == @opaque_token_bytes do
      session_command = %{
        attempt_id: command.attempt_id,
        token_digest: :crypto.hash(:sha256, token),
        source_fingerprint: command.source_fingerprint,
        correlation_id: command.correlation_id
      }

      case adapters.identity.create_session_and_audit(
             adapters.identity_context,
             candidate.scoped_context,
             session_command,
             audit_result: "allowed"
           ) do
        {:ok, session} -> {:ok, %{session: session, opaque_token: token}}
        _failure -> unauthenticated()
      end
    else
      unauthenticated()
    end
  end

  defp finish(adapters, false, _candidate, command) do
    failure_command = %{
      attempt_id: command.attempt_id,
      login_fingerprint: command.login_fingerprint,
      source_fingerprint: command.source_fingerprint,
      correlation_id: command.correlation_id,
      result: "failed"
    }

    record_anonymous_failure(adapters, failure_command)

    unauthenticated()
  end

  defp record_anonymous_failure(adapters, failure_command) do
    case adapters.pre_auth.record_attempt(
           adapters.pre_auth_context,
           failure_command
         ) do
      :ok -> :ok
      _failure -> emit_audit_health(failure_command.correlation_id)
    end
  rescue
    _error -> emit_audit_health(failure_command.correlation_id)
  catch
    _kind, _reason -> emit_audit_health(failure_command.correlation_id)
  end

  defp emit_audit_health(correlation_id) do
    :telemetry.execute(
      [:singularity, :authentication, :audit_write_failure],
      %{count: 1},
      %{
        category: :anonymous_audit_write,
        correlation_id: correlation_id
      }
    )
  end

  defp normalize(value) do
    case value |> String.normalize(:nfc) |> String.trim() |> String.downcase() do
      "" -> {:error, Error.new(:invalid)}
      normalized -> {:ok, normalized}
    end
  end

  defp validate_secret(secret) when is_binary(secret) and byte_size(secret) >= 32,
    do: :ok

  defp validate_secret(_secret), do: {:error, Error.new(:invalid)}

  defp mac(secret, label, value) do
    :crypto.mac(:hmac, :sha256, secret, [label, <<0>>, value])
  end

  defp unauthenticated, do: {:error, Error.new(:unauthenticated)}
end
