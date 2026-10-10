defmodule Singularity.Runtime.Organization.Authorizer do
  @moduledoc "Invocation-local composition of existing organization capability alternatives."

  alias Singularity.Core.{Error, KnowledgeValidation, Types}
  alias Singularity.Runtime.SessionContext

  @entry_keys ~w(organization_access vault_id classification requires_unlocked? principal_authorization_epoch vault_authorization_epoch)a
  @error_keys ~w(__struct__ code message details retryable?)a

  @spec check(term(), term(), term(), term(), term()) :: :ok | {:error, Error.t()}
  def check(original, dependencies, repo, %SessionContext{} = session, requirement) do
    with true <- valid_entry?(requirement, session),
         {:ok, delegate} <- delegate(original) do
      note = delegated_requirement(requirement, "note", true)

      case invoke(delegate, dependencies, repo, session, note) do
        {:error, %Error{code: code, retryable?: false}}
        when code in [:forbidden, :vault_locked] ->
          invoke(
            delegate,
            dependencies,
            repo,
            session,
            delegated_requirement(requirement, "asset", false)
          )

        result ->
          result
      end
    else
      _invalid -> {:error, Error.new(:invalid)}
    end
  end

  def check(_original, _dependencies, _repo, _session, _requirement),
    do: {:error, Error.new(:invalid)}

  defp valid_entry?(requirement, session) do
    with true <- exact_map?(requirement, @entry_keys),
         true <- exact_struct?(session, SessionContext),
         true <- requirement.organization_access in [:read, :write],
         :private <- requirement.classification,
         true <- requirement.requires_unlocked?,
         {:ok, _} <- Types.canonical_uuid(Map.from_struct(session), :principal_id),
         {:ok, owner} <- Types.canonical_uuid(Map.from_struct(session), :vault_id),
         true <- requirement.vault_id === owner,
         {:ok, principal_epoch} <- KnowledgeValidation.integer(principal_epoch(session)),
         {:ok, vault_epoch} <- KnowledgeValidation.integer(session.vault_authorization_epoch),
         true <- requirement.principal_authorization_epoch === principal_epoch,
         true <- requirement.vault_authorization_epoch === vault_epoch do
      true
    else
      _invalid -> false
    end
  end

  defp principal_epoch(%SessionContext{principal_authorization_epoch: nil} = session),
    do: session.authorization_epoch

  defp principal_epoch(session), do: session.principal_authorization_epoch

  defp delegated_requirement(requirement, kind, unlocked?) do
    requirement
    |> Map.delete(:organization_access)
    |> Map.put(:requires_unlocked?, unlocked?)
    |> Map.put(
      :required_capability,
      kind <> "." <> Atom.to_string(requirement.organization_access)
    )
  end

  defp delegate({module, context}) when is_atom(module) and module not in [nil, __MODULE__] do
    with {:module, _} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :check, 5) do
      {:ok, {module, context}}
    else
      _invalid -> :invalid
    end
  end

  defp delegate(module) when is_atom(module) and module not in [nil, __MODULE__] do
    with {:module, _} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :check, 4) do
      {:ok, module}
    else
      _invalid -> :invalid
    end
  end

  defp delegate(_original), do: :invalid

  defp invoke({module, context}, dependencies, repo, session, requirement) do
    module.check(context, dependencies, repo, session, requirement) |> result()
  rescue
    _exception -> unavailable()
  catch
    _, _ -> unavailable()
  end

  defp invoke(module, dependencies, repo, session, requirement) do
    module.check(dependencies, repo, session, requirement) |> result()
  rescue
    _exception -> unavailable()
  catch
    _, _ -> unavailable()
  end

  defp result(:ok), do: :ok

  defp result({:error, %Error{} = error}) do
    if Enum.sort(Map.keys(error)) == Enum.sort(@error_keys) and
         error.code in Error.codes() and is_boolean(error.retryable?) do
      {:error, Error.new(error.code, retryable?: error.retryable?)}
    else
      unavailable()
    end
  end

  defp result(_result), do: unavailable()

  defp exact_map?(value, keys) when is_map(value) and not is_struct(value),
    do: Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp exact_map?(_value, _keys), do: false

  defp exact_struct?(value, module),
    do: Enum.sort(Map.keys(value)) == Enum.sort(Map.keys(module.__struct__()))

  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
