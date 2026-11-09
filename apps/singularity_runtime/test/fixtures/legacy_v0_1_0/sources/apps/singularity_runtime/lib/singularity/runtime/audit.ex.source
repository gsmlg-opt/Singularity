defmodule Singularity.Runtime.Audit do
  @moduledoc """
  Builds strict audit values and redacts metadata before the persistence port.
  """

  alias Singularity.Core.AuditEvent
  alias Singularity.Core.Error
  alias Singularity.Runtime.Observability.Redactor

  @spec append_principal(term(), term(), map(), map()) ::
          :ok | {:error, Error.t()}
  def append_principal(
        sink,
        repo,
        %{principal_id: principal_id, vault_id: vault_id},
        attrs
      )
      when is_map(attrs) do
    attrs
    |> Map.merge(%{
      actor_kind: :principal,
      principal_id: principal_id,
      vault_id: vault_id,
      anonymous_fingerprint: nil,
      system_principal_name: nil
    })
    |> append(sink, repo)
  end

  def append_principal(_sink, _repo, _session, _attrs),
    do: {:error, Error.new(:invalid)}

  @spec append_system(term(), term(), String.t(), String.t(), map()) ::
          :ok | {:error, Error.t()}
  def append_system(sink, repo, system_principal_name, vault_id, attrs)
      when is_binary(system_principal_name) and is_binary(vault_id) and is_map(attrs) do
    attrs
    |> Map.merge(%{
      actor_kind: :system,
      principal_id: nil,
      vault_id: vault_id,
      anonymous_fingerprint: nil,
      system_principal_name: system_principal_name
    })
    |> append(sink, repo)
  end

  def append_system(_sink, _repo, _name, _vault_id, _attrs),
    do: {:error, Error.new(:invalid)}

  @spec append_anonymous(term(), term(), binary(), map()) ::
          :ok | {:error, Error.t()}
  def append_anonymous(sink, repo, anonymous_fingerprint, attrs)
      when is_binary(anonymous_fingerprint) and is_map(attrs) do
    attrs
    |> Map.merge(%{
      actor_kind: :anonymous,
      principal_id: nil,
      vault_id: nil,
      anonymous_fingerprint: anonymous_fingerprint,
      system_principal_name: nil
    })
    |> append(sink, repo)
  end

  def append_anonymous(_sink, _repo, _fingerprint, _attrs),
    do: {:error, Error.new(:invalid)}

  defp append(attrs, sink, repo) do
    attrs =
      attrs
      |> Map.put_new(:audit_event_id, Ecto.UUID.generate())
      |> Map.put_new(:occurred_at, DateTime.utc_now())
      |> Map.update(:metadata, %{}, &Redactor.redact/1)

    with {:ok, event} <- AuditEvent.new(attrs) do
      persist(sink, repo, event)
    end
  rescue
    _error -> {:error, Error.new(:invalid)}
  catch
    _kind, _reason -> {:error, Error.new(:invalid)}
  end

  defp persist(sink, repo, event) do
    case call_adapter(sink, :append, [repo, event]) do
      :ok -> :ok
      {:error, %Error{}} = error -> error
      _invalid -> storage_error()
    end
  rescue
    _error -> storage_error()
  catch
    _kind, _reason -> storage_error()
  end

  defp storage_error,
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, arguments)
  end

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, [context | arguments])
  end
end
