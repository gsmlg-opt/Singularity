defmodule SingularityWeb.RunComponents do
  @moduledoc "Fetch run status rendering shared by the Overview and Source pages."
  use SingularityWeb, :html

  attr :run, :map, required: true

  def run_status(assigns) do
    ~H"""
    <.dm_badge size="sm" variant={variant(@run.status)}>{status_label(@run.status)}</.dm_badge>
    """
  end

  def status_label("ok"), do: dgettext("source", "OK")
  def status_label("failed"), do: dgettext("source", "Failed")
  def status_label(_running), do: dgettext("source", "Running")

  defp variant("ok"), do: "success"
  defp variant("failed"), do: "error"
  defp variant(_running), do: "info"
end
