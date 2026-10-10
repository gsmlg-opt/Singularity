defmodule Singularity.Core.NoteSnapshot do
  @moduledoc "An immutable private note source snapshot."

  alias Singularity.Core.Classification
  alias Singularity.Core.Error
  alias Singularity.Core.NoteAttachmentReference
  alias Singularity.Core.NoteCitationReference
  alias Singularity.Core.Types

  @max_title_bytes 255
  @max_markdown_bytes 1_048_576

  @enforce_keys [:classification, :title, :markdown]
  defstruct @enforce_keys ++
              [
                :parent_version_id,
                :merge_parent_version_id,
                attachments: :inherit,
                citations: :inherit
              ]

  @type t :: %__MODULE__{
          classification: :private,
          title: String.t(),
          markdown: String.t(),
          parent_version_id: Types.id() | nil,
          merge_parent_version_id: Types.id() | nil,
          attachments: [NoteAttachmentReference.t()] | :inherit,
          citations: [NoteCitationReference.t()] | :inherit
        }

  @spec initial(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def initial(attrs), do: build(attrs, :initial)

  @spec normal(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def normal(attrs), do: build(attrs, :normal)

  @spec merge(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def merge(attrs), do: build(attrs, :merge)

  defp build(attrs, shape) do
    with {:ok, attrs} <- Types.attrs(attrs),
         {:ok, classification} <- Classification.new(Map.get(attrs, :classification)),
         :ok <- require_private(classification),
         {:ok, title} <- title(attrs),
         {:ok, markdown} <- markdown(attrs),
         {:ok, parent_version_id, merge_parent_version_id} <- parents(attrs, shape),
         {:ok, attachments} <- source_set(attrs, :attachments, shape, NoteAttachmentReference),
         {:ok, citations} <- source_set(attrs, :citations, shape, NoteCitationReference),
         :ok <- source_bounds(attachments, citations) do
      {:ok,
       %__MODULE__{
         classification: classification,
         title: title,
         markdown: markdown,
         parent_version_id: parent_version_id,
         merge_parent_version_id: merge_parent_version_id,
         attachments: attachments,
         citations: citations
       }}
    end
  end

  defp source_set(attrs, field, shape, module) do
    case Map.fetch(attrs, field) do
      :error -> {:ok, if(shape == :initial, do: [], else: :inherit)}
      {:ok, values} when is_list(values) and length(values) <= 100 -> references(values, module)
      _invalid -> invalid()
    end
  end

  defp references(values, module) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case module.new(value) do
        {:ok, reference} -> {:cont, {:ok, [reference | acc]}}
        _invalid -> {:halt, invalid()}
      end
    end)
    |> case do
      {:ok, references} -> {:ok, Enum.reverse(references)}
      error -> error
    end
  end

  defp source_bounds(attachments, citations) do
    attachments = if attachments == :inherit, do: [], else: attachments
    citations = if citations == :inherit, do: [], else: citations

    attachment_targets =
      Enum.map(attachments, &{&1.target_resource_id, &1.target_resource_version_id})

    citation_targets =
      Enum.map(citations, &{&1.source_resource_id, &1.source_resource_version_id})

    if unique?(attachments, & &1.attachment_id) and
         unique?(attachments, &{&1.target_resource_id, &1.target_resource_version_id, &1.role}) and
         unique?(citations, & &1.citation_id) and
         MapSet.size(MapSet.new(attachment_targets ++ citation_targets)) <= 100 and
         MapSet.size(MapSet.new(Enum.map(citations, & &1.fragment_id))) <= 100,
       do: :ok,
       else: invalid()
  end

  defp unique?(references, key) do
    MapSet.size(MapSet.new(Enum.map(references, key))) == length(references)
  end

  defp title(attrs) do
    case Map.fetch(attrs, :title) do
      {:ok, value} when is_binary(value) ->
        if String.valid?(value) do
          case String.trim(value) do
            "" -> invalid()
            title when byte_size(title) <= @max_title_bytes -> {:ok, title}
            _title -> invalid()
          end
        else
          invalid()
        end

      _other ->
        invalid()
    end
  end

  defp markdown(attrs) do
    case Map.fetch(attrs, :markdown) do
      {:ok, value}
      when is_binary(value) and byte_size(value) <= @max_markdown_bytes ->
        if String.valid?(value) and not String.contains?(value, <<0>>),
          do: {:ok, value},
          else: invalid()

      _other ->
        invalid()
    end
  end

  defp parents(attrs, :initial) do
    if is_nil(Map.get(attrs, :parent_version_id)) and
         is_nil(Map.get(attrs, :merge_parent_version_id)),
       do: {:ok, nil, nil},
       else: invalid()
  end

  defp parents(attrs, :normal) do
    with {:ok, parent_version_id} <- Types.canonical_uuid(attrs, :parent_version_id),
         true <- is_nil(Map.get(attrs, :merge_parent_version_id)) do
      {:ok, parent_version_id, nil}
    else
      _invalid -> invalid()
    end
  end

  defp parents(attrs, :merge) do
    with {:ok, parent_version_id} <- Types.canonical_uuid(attrs, :parent_version_id),
         {:ok, merge_parent_version_id} <- Types.canonical_uuid(attrs, :merge_parent_version_id),
         true <- parent_version_id != merge_parent_version_id do
      {:ok, parent_version_id, merge_parent_version_id}
    else
      _invalid -> invalid()
    end
  end

  defp require_private(:private), do: :ok
  defp require_private(_classification), do: invalid()

  defp invalid, do: {:error, Error.new(:invalid)}
end
