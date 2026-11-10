defmodule Singularity.HttpClient do
  @moduledoc """
  The one place that talks to http_fetch: a GET with a 15 second deadline whose
  body is read completely. Never raises; every failure becomes
  `{:error, {:transport, message}}`. Callers pass the adapter from their
  application config (`nil` in production, `{HTTP.Test, name}` in tests).
  """

  @timeout 15_000

  @type response :: %{status: pos_integer(), headers: HTTP.Headers.t(), body: binary()}

  @spec get(String.t(), [{String.t(), String.t()}], module() | {module(), term()} | nil) ::
          {:ok, response()} | {:error, {:transport, String.t()}}
  def get(url, headers, adapter) do
    url
    |> HTTP.fetch(headers: headers, adapter: adapter, timeout: @timeout)
    # The fetch gives its worker up to one more second to report its own timeout.
    |> HTTP.Promise.await(@timeout + 2_000)
    |> read()
  catch
    # HTTP.Promise.await/2 exits the caller when the request process crashes.
    :exit, reason -> {:error, {:transport, "request exited: " <> inspect(reason)}}
  end

  # HTTP.Response.text/1 raises when a streamed body fails part way.
  defp read(%HTTP.Response{} = response) do
    {:ok,
     %{status: response.status, headers: response.headers, body: HTTP.Response.text(response)}}
  rescue
    exception -> {:error, {:transport, Exception.message(exception)}}
  end

  defp read({:error, reason}), do: {:error, {:transport, describe(reason)}}

  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason), do: inspect(reason)
end
