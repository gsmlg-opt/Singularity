defmodule Singularity.Runtime.Notes.SourceCollections do
  @moduledoc false

  alias Singularity.Core.Error
  alias Singularity.Runtime.DTO.NoteValidation
  alias Singularity.Runtime.SessionContext

  @spec compose(term(), term(), SessionContext.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def compose(adapter, repo, %SessionContext{} = session, row) when is_map(row) do
    with :ok <- row_identity(row, session),
         {:ok, membership} <-
           call_adapter(adapter, :read_membership, [
             %{
               repo: repo,
               principal_id: session.principal_id,
               owner_scope_id: session.vault_id
             },
             row.resource_id,
             row.resource_version_id
           ])
           |> membership_result(),
         true <- is_map(membership) and not is_struct(membership),
         {:ok, membership} <-
           NoteValidation.exact_attrs(membership, [:revision, :attachments, :citations]),
         true <- membership.revision === row.revision,
         {:ok, sources} <- NoteValidation.source_collections(membership),
         true <- canonical_references?(membership.attachments, sources.attachments),
         true <- canonical_references?(membership.citations, sources.citations) do
      {:ok, Map.merge(row, sources)}
    else
      {:error, %Error{}} = failure -> failure
      _invalid -> NoteValidation.integrity_failure()
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def compose(_adapter, _repo, _session, _row), do: NoteValidation.integrity_failure()

  defp row_identity(row, session) do
    with {:ok, _principal} <- NoteValidation.uuid(%{principal: session.principal_id}, :principal),
         {:ok, _owner} <- NoteValidation.uuid(%{owner: session.vault_id}, :owner),
         {:ok, _resource} <- NoteValidation.uuid(row, :resource_id),
         {:ok, _version} <- NoteValidation.uuid(row, :resource_version_id),
         true <- row[:vault_id] == session.vault_id and row[:classification] == :private,
         true <- is_integer(row[:revision]) and row.revision >= 0,
         false <- Map.has_key?(row, :attachments) or Map.has_key?(row, :citations) do
      :ok
    else
      _invalid -> NoteValidation.integrity_failure()
    end
  end

  defp membership_result({:ok, _membership} = result), do: result

  defp membership_result({:error, %Error{code: code, retryable?: retryable?}})
       when is_boolean(retryable?) do
    if code in Error.codes(),
      do: {:error, Error.new(code, retryable?: retryable?)},
      else: NoteValidation.integrity_failure()
  end

  defp membership_result(_invalid), do: NoteValidation.integrity_failure()

  # Constructor inputs may normalize; canonical server output must never gain
  # defaults or silently change an identity, label, role or locator.
  defp canonical_references?(original, reconstructed) do
    original
    |> Enum.zip(reconstructed)
    |> Enum.all?(fn {input, dto} ->
      attrs = if is_struct(input), do: Map.from_struct(input), else: input
      attrs === Map.from_struct(dto)
    end)
  end

  defp call_adapter(module, function, arguments) when is_atom(module) and not is_nil(module),
    do: apply(module, function, arguments)

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [context | arguments])

  defp storage_unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
