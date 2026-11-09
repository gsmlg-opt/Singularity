defmodule Singularity.Runtime.Notes.Mutation do
  @moduledoc false

  alias Singularity.Core.Error
  alias Singularity.Core.NoteSaveResult, as: ReferenceResult
  alias Singularity.Core.Types
  alias Singularity.Domains.Notes
  alias Singularity.Domains.Notes.Command
  alias Singularity.Runtime.Notes.DTO, as: NotesDTO
  alias Singularity.Runtime.Notes.MutationFingerprint
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.Postgres.NoteRepository

  @client_fields %{
    create: [:mutation_id, :title, :markdown],
    save: [:mutation_id, :resource_id, :base_version_id, :title, :markdown],
    merge: [
      :mutation_id,
      :resource_id,
      :conflict_id,
      :expected_current_version_id,
      :competing_version_id,
      :title,
      :markdown
    ],
    tombstone: [:mutation_id, :resource_id, :expected_current_version_id],
    restore: [:mutation_id, :resource_id]
  }

  @spec run(atom(), map(), SessionContext.t(), String.t() | nil, map() | keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def run(operation, runtime, %SessionContext{} = session, resource_id, attrs)
      when operation in [:create, :save, :merge, :tombstone, :restore] and is_map(runtime) do
    with {:ok, adapters} <- adapters(runtime),
         {:ok, attrs} <- client_attrs(operation, attrs, resource_id) do
      call_adapter(adapters.operation_scope, :with_shared_request, [
        runtime,
        session,
        requirement(session),
        fn repo -> execute(adapters, operation, repo, session, attrs) end
      ])
    end
  rescue
    _error -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def run(_operation, _runtime, _session, _resource_id, _attrs), do: invalid()

  defp execute(adapters, operation, repo, session, attrs) do
    raw =
      Map.merge(attrs, %{
        principal_id: session.principal_id,
        vault_id: session.vault_id,
        classification: :private,
        correlation_id: Ecto.UUID.generate()
      })

    with {:ok, command} <- Command.new(operation, raw),
         {:ok, fingerprint} <-
           call_adapter(adapters.mutation_fingerprint, :compute, [
             adapters.fingerprint_secret,
             command
           ]),
         {:ok, references} <-
           call_adapter(adapters.notes, :execute, [
             %{repository: adapters.note_repository, repository_context: repo},
             command,
             fingerprint
           ]) do
      hydrate(adapters, repo, session, command, references)
    end
  end

  defp hydrate(adapters, repo, session, %Command{operation: :create}, %ReferenceResult{
         outcome: :saved,
         resource_id: resource_id
       }) do
    reload_note(adapters, repo, session, resource_id)
  end

  defp hydrate(
         adapters,
         repo,
         session,
         %Command{operation: operation, resource_id: resource_id},
         %ReferenceResult{
           outcome: outcome,
           resource_id: resource_id
         } = references
       )
       when operation in [:save, :merge] and outcome in [:saved, :conflict] do
    with {:ok, canonical} <- reload_note(adapters, repo, session, resource_id) do
      attrs = %{
        outcome: outcome,
        canonical: canonical,
        submitted_version_id:
          if(outcome == :saved,
            do: canonical.resource_version_id,
            else: references.submitted_version_id
          ),
        conflict_id: references.conflict_id
      }

      NotesDTO.save_result(attrs)
    end
  end

  defp hydrate(
         _adapters,
         _repo,
         _session,
         %Command{
           operation: :tombstone,
           resource_id: resource_id,
           expected_current_version_id: version_id
         },
         %{resource_id: resource_id, canonical_version_id: version_id, state: :tombstoned}
       ) do
    if canonical_uuid?(version_id), do: {:ok, true}, else: invalid()
  end

  defp hydrate(
         adapters,
         repo,
         session,
         %Command{operation: :restore, resource_id: resource_id},
         %{resource_id: resource_id, canonical_version_id: version_id, state: :restored}
       ) do
    with true <- canonical_uuid?(version_id),
         {:ok, canonical} <- reload_note(adapters, repo, session, resource_id) do
      {:ok, canonical}
    else
      false -> invalid()
      {:error, %Error{}} = error -> error
    end
  end

  defp hydrate(_adapters, _repo, _session, _command, _references), do: integrity_failure()

  defp reload_note(adapters, repo, session, resource_id) do
    case call_adapter(adapters.note_repository, :get, [repo, session.vault_id, resource_id]) do
      {:ok,
       %{
         resource_id: ^resource_id,
         vault_id: vault_id,
         classification: :private
       } = note}
      when vault_id == session.vault_id ->
        NotesDTO.note(note)

      {:ok, %{__struct__: Singularity.Runtime.DTO.Note, resource_id: ^resource_id} = note} ->
        NotesDTO.note(note)

      {:ok, _malformed} ->
        integrity_failure()

      {:error, %Error{}} = error ->
        error

      _malformed ->
        integrity_failure()
    end
  end

  defp client_attrs(operation, attrs, resource_id) do
    fields = Map.fetch!(@client_fields, operation)
    string_fields = Enum.map(fields, &Atom.to_string/1)

    with {:ok, attrs} <- Types.attrs(attrs),
         true <- Enum.all?(Map.keys(attrs), &(&1 in fields or &1 in string_fields)),
         {:ok, attrs} <- bind_resource(attrs, operation, resource_id) do
      {:ok, attrs}
    else
      _invalid -> invalid()
    end
  end

  defp bind_resource(attrs, :create, nil), do: {:ok, attrs}

  defp bind_resource(attrs, operation, resource_id)
       when operation in [:save, :merge, :tombstone, :restore] do
    with true <- canonical_uuid?(resource_id),
         :ok <- supplied_resource_matches(attrs, resource_id) do
      {:ok,
       attrs
       |> Map.delete("resource_id")
       |> Map.put(:resource_id, resource_id)}
    else
      _invalid -> invalid()
    end
  end

  defp bind_resource(_attrs, _operation, _resource_id), do: invalid()

  defp supplied_resource_matches(attrs, resource_id) do
    supplied =
      [:resource_id, "resource_id"]
      |> Enum.flat_map(fn key ->
        case Map.fetch(attrs, key) do
          {:ok, value} -> [value]
          :error -> []
        end
      end)

    if Enum.all?(supplied, &(&1 == resource_id)), do: :ok, else: invalid()
  end

  defp requirement(session) do
    %{
      vault_id: session.vault_id,
      required_capability: "note.write",
      classification: :private,
      requires_unlocked?: true
    }
  end

  defp adapters(runtime) do
    values = %{
      fingerprint_secret:
        Map.get(runtime, :fingerprint_secret) ||
          Application.get_env(:singularity_runtime, :mutation_fingerprint_secret),
      mutation_fingerprint: Map.get(runtime, :mutation_fingerprint, MutationFingerprint),
      note_repository: Map.get(runtime, :note_repository, NoteRepository),
      notes: Map.get(runtime, :notes, Notes),
      operation_scope: Map.get(runtime, :operation_scope, OperationScope)
    }

    if valid_adapters?(values), do: {:ok, values}, else: invalid()
  end

  defp valid_adapters?(values) do
    match?(<<_::binary-size(32)>>, values.fingerprint_secret) and
      Enum.all?(
        Map.take(values, [:mutation_fingerprint, :note_repository, :notes, :operation_scope])
        |> Map.values(),
        &(&1 not in [nil, false])
      ) and is_atom(values.note_repository)
  end

  defp canonical_uuid?(value), do: Ecto.UUID.cast(value) == {:ok, value}

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, arguments)

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [context | arguments])

  defp invalid, do: {:error, Error.new(:invalid)}
  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
  defp storage_unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end

defmodule Singularity.Runtime.Notes.Create do
  @moduledoc "Creates a private note inside one authorized shared request."

  alias Singularity.Core.Error
  alias Singularity.Runtime.Notes.Mutation
  alias Singularity.Runtime.SessionContext

  @spec run(map(), SessionContext.t(), map() | keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(runtime, %SessionContext{} = session, attrs),
    do: Mutation.run(:create, runtime, session, nil, attrs)

  def run(_runtime, _session, _attrs), do: {:error, Error.new(:invalid)}
end
