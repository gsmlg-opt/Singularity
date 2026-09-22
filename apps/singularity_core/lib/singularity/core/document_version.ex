defmodule Singularity.Core.DocumentVersion do
  @moduledoc "A private Document version with a pinned source and validated lifecycle shape."
  alias Singularity.Core.{
    DocumentCompletion,
    DocumentFragment,
    DocumentSource,
    Error,
    KnowledgeValidation,
    Types
  }

  @enforce_keys [
    :resource_id,
    :resource_version_id,
    :owner_scope_id,
    :classification,
    :revision,
    :source,
    :title,
    :created_by_principal_id,
    :inserted_at,
    :state,
    :generation
  ]
  @optional [
    :attempt_job_id,
    :attempt_started_at,
    :attempt_deadline_at,
    :adapter_name,
    :format_version,
    :extracted_text_digest,
    :detected_language,
    :failure_code,
    :finished_at,
    :fragments
  ]
  defstruct @enforce_keys ++ @optional

  @type t :: %__MODULE__{
          resource_id: Types.id(),
          resource_version_id: Types.id(),
          owner_scope_id: Types.id(),
          classification: :private,
          revision: non_neg_integer(),
          source: DocumentSource.t(),
          title: String.t(),
          created_by_principal_id: Types.id(),
          inserted_at: DateTime.t(),
          state: :pending | :extracting | :ready | :failed | :unsupported,
          generation: non_neg_integer(),
          attempt_job_id: Types.id() | nil,
          attempt_started_at: DateTime.t() | nil,
          attempt_deadline_at: DateTime.t() | nil,
          adapter_name: String.t() | nil,
          format_version: pos_integer() | nil,
          extracted_text_digest: binary() | nil,
          detected_language: String.t() | nil,
          failure_code: String.t() | nil,
          finished_at: DateTime.t() | nil,
          fragments: [DocumentFragment.t()] | nil
        }

  @spec new(term()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = input), do: new(Map.from_struct(input))

  def new(input) do
    with {:ok, attrs} <- KnowledgeValidation.attrs(input, @enforce_keys ++ @optional),
         true <-
           Enum.all?(
             [:resource_id, :resource_version_id, :owner_scope_id, :created_by_principal_id],
             &match?({:ok, _}, Types.canonical_uuid(attrs, &1))
           ),
         :private <- attrs[:classification],
         {:ok, _} <- KnowledgeValidation.integer(attrs[:revision]),
         {:ok, _} <- KnowledgeValidation.integer(attrs[:generation]),
         {:ok, source} <- DocumentSource.new(attrs[:source]),
         true <-
           source.owner_scope_id == attrs.owner_scope_id and
             source.classification == attrs.classification,
         true <-
           source.resource_id != attrs.resource_id and
             source.resource_version_id != attrs.resource_version_id,
         {:ok, title} <- KnowledgeValidation.bounded_name(attrs[:title]),
         {:ok, _} <- KnowledgeValidation.utc_datetime(attrs, :inserted_at),
         {:ok, attrs} <- lifecycle(Map.put(attrs, :source, source)) do
      {:ok, struct!(__MODULE__, Map.put(attrs, :title, title))}
    else
      _ -> Types.invalid()
    end
  end

  defp lifecycle(%{state: :pending} = attrs) do
    if Enum.all?(@optional, &is_nil(attrs[&1])), do: {:ok, attrs}, else: Types.invalid()
  end

  defp lifecycle(%{state: :extracting} = attrs) do
    with {:ok, _} <- KnowledgeValidation.integer(attrs[:generation], 1),
         {:ok, _} <- Types.canonical_uuid(attrs, :attempt_job_id),
         {:ok, _} <- KnowledgeValidation.utc_datetime(attrs, :attempt_started_at),
         {:ok, _} <- KnowledgeValidation.utc_datetime(attrs, :attempt_deadline_at),
         true <- DateTime.compare(attrs.attempt_deadline_at, attrs.attempt_started_at) == :gt,
         {:ok, adapter} <- KnowledgeValidation.bounded_name(attrs[:adapter_name]),
         {:ok, _} <- KnowledgeValidation.integer(attrs[:format_version], 1),
         true <- attrs.format_version <= 2_147_483_647,
         true <-
           Enum.all?(
             @optional --
               [
                 :adapter_name,
                 :format_version,
                 :attempt_job_id,
                 :attempt_started_at,
                 :attempt_deadline_at
               ],
             &is_nil(attrs[&1])
           ) do
      {:ok, Map.put(attrs, :adapter_name, adapter)}
    else
      _ -> Types.invalid()
    end
  end

  defp lifecycle(%{state: state} = attrs) when state in [:ready, :failed, :unsupported] do
    with {:ok, _} <- Types.canonical_uuid(attrs, :attempt_job_id),
         {:ok, _} <- KnowledgeValidation.utc_datetime(attrs, :attempt_started_at),
         {:ok, _} <- KnowledgeValidation.utc_datetime(attrs, :attempt_deadline_at),
         true <- DateTime.compare(attrs.attempt_deadline_at, attrs.attempt_started_at) == :gt do
      input =
        attrs
        |> Map.take(
          [:resource_id, :resource_version_id, :owner_scope_id, :classification, :generation] ++
            [
              :adapter_name,
              :format_version,
              :extracted_text_digest,
              :detected_language,
              :failure_code,
              :finished_at,
              :fragments
            ]
        )
        |> Map.merge(%{outcome: state, media_type: attrs.source.media_type})

      with {:ok, completion} <- DocumentCompletion.new(input) do
        {:ok, Map.merge(attrs, Map.take(Map.from_struct(completion), @optional))}
      end
    else
      _ -> Types.invalid()
    end
  end

  defp lifecycle(_), do: Types.invalid()
end
