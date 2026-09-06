defmodule Singularity.Core.KnowledgeEncoding do
  @moduledoc false

  @spec frame(binary()) :: binary()
  def frame(field) when is_binary(field), do: <<byte_size(field)::unsigned-big-64, field::binary>>
end
