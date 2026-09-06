defmodule Singularity.Core.SourceLocator do
  @moduledoc "A validated v1 location within an immutable source version."
  alias Singularity.Core.{Error, KnowledgeEncoding, KnowledgeValidation, Types}

  @enforce_keys [:version, :kind, :fields]
  defstruct @enforce_keys
  @type t :: %__MODULE__{version: 1, kind: String.t(), fields: map()}
  @keys [
    :version,
    :kind,
    :page,
    :start_char,
    :end_char,
    :heading_path,
    :start_line,
    :end_line,
    :ordinal
  ]

  @spec new(term()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{version: version, kind: kind, fields: fields} = locator) do
    with true <- Map.keys(locator) |> Enum.sort() == [:__struct__, :fields, :kind, :version],
         true <- is_map(fields) and not is_struct(fields),
         {:ok, fields} <- KnowledgeValidation.attrs(fields, @keys -- [:version, :kind]) do
      new(Map.merge(fields, %{version: version, kind: kind}))
    else
      _ -> Types.invalid()
    end
  end

  def new(input) do
    with {:ok, attrs} <- KnowledgeValidation.attrs(input, @keys),
         1 <- Map.get(attrs, :version),
         {:ok, fields} <- fields(Map.get(attrs, :kind), Map.drop(attrs, [:version, :kind])) do
      {:ok, %__MODULE__{version: 1, kind: attrs.kind, fields: fields}}
    else
      _ -> Types.invalid()
    end
  end

  @spec to_map(term()) :: map() | {:error, Error.t()}
  def to_map(input) do
    with {:ok, locator} <- new(input) do
      locator.fields
      |> Map.merge(%{version: 1, kind: locator.kind})
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    end
  end

  @spec encode(term()) :: binary() | {:error, Error.t()}
  def encode(input) do
    with {:ok, locator} <- new(input) do
      ["1", locator.kind | encoded_fields(locator.kind, locator.fields)]
      |> Enum.map(&KnowledgeEncoding.frame/1)
      |> IO.iodata_to_binary()
    end
  end

  defp fields("pdf", attrs) do
    with true <- only?(attrs, [:page, :start_char, :end_char]),
         {:ok, _} <- KnowledgeValidation.integer(attrs[:page], 1),
         :ok <- range(attrs, :start_char, :end_char, 0, false, true),
         do: {:ok, attrs}
  end

  defp fields("markdown", attrs) do
    with true <- only?(attrs, [:heading_path, :start_line, :end_line]),
         {:ok, headings} <- headings(attrs[:heading_path]),
         :ok <- range(attrs, :start_line, :end_line, 1, true, true),
         do: {:ok, Map.put(attrs, :heading_path, headings)}
  end

  defp fields("text", attrs) do
    with true <- only?(attrs, [:start_line, :end_line]),
         :ok <- range(attrs, :start_line, :end_line, 1, true, false),
         do: {:ok, attrs}
  end

  defp fields("fragment", attrs) do
    with true <- only?(attrs, [:ordinal]),
         {:ok, _} <- KnowledgeValidation.integer(attrs[:ordinal]),
         do: {:ok, attrs}
  end

  defp fields(_, _), do: Types.invalid()

  defp only?(attrs, keys), do: Enum.all?(Map.keys(attrs), &(&1 in keys))

  defp range(attrs, first, last, minimum, equal?, optional?) do
    if optional? and not Map.has_key?(attrs, first) and not Map.has_key?(attrs, last) do
      :ok
    else
      with {:ok, start} <- KnowledgeValidation.integer(attrs[first], minimum),
           {:ok, finish} <- KnowledgeValidation.integer(attrs[last], minimum),
           true <- finish > start or (equal? and finish == start),
           do: :ok
    end
  end

  defp headings(values) when is_list(values) and length(values) <= 64 do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      with {:ok, value} <- KnowledgeValidation.string(value, 255),
           {:ok, normalized} <- KnowledgeValidation.string(String.normalize(value, :nfc), 255) do
        {:cont, {:ok, [normalized | acc]}}
      else
        _ -> {:halt, Types.invalid()}
      end
    end)
    |> case do
      {:ok, headings} -> {:ok, Enum.reverse(headings)}
      error -> error
    end
  end

  defp headings(_), do: Types.invalid()

  defp encoded_fields("pdf", fields),
    do: Enum.map([:page, :start_char, :end_char], &decimal(fields[&1]))

  defp encoded_fields("markdown", fields) do
    heading =
      [Integer.to_string(length(fields.heading_path)) | fields.heading_path]
      |> Enum.map(&KnowledgeEncoding.frame/1)
      |> IO.iodata_to_binary()

    [heading, decimal(fields[:start_line]), decimal(fields[:end_line])]
  end

  defp encoded_fields("text", fields), do: [decimal(fields.start_line), decimal(fields.end_line)]
  defp encoded_fields("fragment", fields), do: [decimal(fields.ordinal)]
  defp decimal(nil), do: ""
  defp decimal(value), do: Integer.to_string(value)
end
