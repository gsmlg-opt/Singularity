defmodule Singularity.Core.NoteSourceSet do
  @moduledoc "An atomic version-pinned note source set validated against supplied evidence, not authenticated or looked up."
  alias Singularity.Core.{
    DocumentFragment,
    Error,
    KnowledgeValidation,
    NoteAttachment,
    NoteCitation,
    Types
  }

  @identity [:note_resource_id, :note_resource_version_id, :owner_scope_id, :classification]
  @enforce_keys @identity ++ [:attachments, :citations, :targets, :fragments]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          note_resource_id: Types.id(),
          note_resource_version_id: Types.id(),
          owner_scope_id: Types.id(),
          classification: :private,
          attachments: [NoteAttachment.t()],
          citations: [NoteCitation.t()],
          targets: [target()],
          fragments: [DocumentFragment.t()]
        }
  @type target ::
          %{
            resource_id: Types.id(),
            resource_version_id: Types.id(),
            owner_scope_id: Types.id(),
            classification: :private,
            kind: :document,
            state: :ready
          }
          | %{
              resource_id: Types.id(),
              resource_version_id: Types.id(),
              owner_scope_id: Types.id(),
              classification: :private,
              kind: :asset | :note
            }

  @spec new(term()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = input), do: new(Map.from_struct(input))

  def new(input) do
    with {:ok, attrs} <- KnowledgeValidation.attrs(input, @enforce_keys),
         {:ok, _} <- Types.canonical_uuid(attrs, :note_resource_id),
         {:ok, _} <- Types.canonical_uuid(attrs, :note_resource_version_id),
         {:ok, _} <- Types.canonical_uuid(attrs, :owner_scope_id),
         :private <- attrs[:classification],
         {:ok, attachments} <- values(attrs[:attachments], &NoteAttachment.new/1),
         {:ok, citations} <- values(attrs[:citations], &NoteCitation.new/1),
         {:ok, targets} <- values(attrs[:targets], &target/1),
         {:ok, fragments} <- values(attrs[:fragments], &DocumentFragment.new/1),
         true <- consistent_targets?(targets),
         true <- ordered?(attachments) and ordered?(citations),
         true <- unique?(attachments, & &1.attachment_id),
         true <- unique?(citations, & &1.citation_id),
         true <-
           unique?(attachments, &{&1.target_resource_id, &1.target_resource_version_id, &1.role}),
         true <-
           Enum.all?(
             attachments ++ citations,
             &(Map.take(&1, @identity) == Map.take(attrs, @identity))
           ),
         true <- Enum.all?(targets ++ fragments, &(&1.owner_scope_id == attrs.owner_scope_id)),
         true <- Enum.all?(attachments, &attachment_target?(&1, targets)),
         true <- Enum.all?(citations, &citation_source?(&1, targets, fragments)) do
      {:ok,
       struct(
         __MODULE__,
         Map.merge(attrs, %{
           attachments: attachments,
           citations: citations,
           targets: targets,
           fragments: fragments
         })
       )}
    else
      _ -> Types.invalid()
    end
  end

  defp values(input, constructor), do: values(input, constructor, [])
  defp values([], _constructor, acc), do: {:ok, Enum.reverse(acc)}

  defp values([input | rest], constructor, acc) do
    with {:ok, value} <- constructor.(input), do: values(rest, constructor, [value | acc])
  end

  defp values(_, _, _), do: Types.invalid()

  defp consistent_targets?(targets) do
    versions = Enum.group_by(targets, & &1.resource_version_id)
    resources = Enum.group_by(targets, & &1.resource_id)

    Enum.all?(versions, fn {_version, summaries} -> length(Enum.uniq(summaries)) == 1 end) and
      Enum.all?(resources, fn {_resource, summaries} ->
        length(Enum.uniq_by(summaries, & &1.kind)) == 1
      end)
  end

  defp target(input) do
    keys = [:resource_id, :resource_version_id, :owner_scope_id, :classification, :kind, :state]

    with {:ok, attrs} <- KnowledgeValidation.attrs(input, keys),
         {:ok, _} <- Types.canonical_uuid(attrs, :resource_id),
         {:ok, _} <- Types.canonical_uuid(attrs, :resource_version_id),
         {:ok, _} <- Types.canonical_uuid(attrs, :owner_scope_id),
         :private <- attrs[:classification],
         true <- valid_target_state?(attrs) do
      {:ok, attrs}
    else
      _ -> Types.invalid()
    end
  end

  defp valid_target_state?(%{kind: :document, state: :ready}), do: true

  defp valid_target_state?(%{kind: kind} = attrs) when kind in [:asset, :note],
    do: not Map.has_key?(attrs, :state)

  defp valid_target_state?(_), do: false

  defp ordered?(values),
    do: values |> Enum.with_index() |> Enum.all?(fn {value, index} -> value.ordinal == index end)

  defp unique?(values, key), do: length(Enum.uniq_by(values, key)) == length(values)

  defp attachment_target?(attachment, targets) do
    Enum.any?(
      targets,
      &(&1.resource_id == attachment.target_resource_id and
          &1.resource_version_id == attachment.target_resource_version_id and
          &1.kind == attachment.target_kind and &1.owner_scope_id == attachment.owner_scope_id)
    )
  end

  defp citation_source?(citation, targets, fragments) do
    Enum.any?(
      targets,
      &(&1.kind == :document and &1.resource_id == citation.source_resource_id and
          &1.resource_version_id == citation.source_resource_version_id and
          &1.owner_scope_id == citation.owner_scope_id)
    ) and
      Enum.any?(
        fragments,
        &(&1.resource_id == citation.source_resource_id and
            &1.resource_version_id == citation.source_resource_version_id and
            &1.owner_scope_id == citation.owner_scope_id and
            &1.fragment_id == citation.fragment_id and &1.locator == citation.locator)
      )
  end
end
