defmodule Singularity.Runtime.Knowledge.ExportArtifact.Handle do
  @moduledoc false

  @enforce_keys [:owner, :operation_ref, :binding, :deadline]
  defstruct [:owner, :operation_ref, :binding, :deadline]
end

defimpl Inspect, for: Singularity.Runtime.Knowledge.ExportArtifact.Handle do
  def inspect(_handle, _options), do: "#KnowledgeExport<opaque>"
end
