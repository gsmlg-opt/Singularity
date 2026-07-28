defmodule Singularity.Web.ErrorJSON do
  @moduledoc false

  def render(template, _assigns) do
    status = Phoenix.Controller.status_message_from_template(template)
    %{error: %{code: status |> String.downcase() |> String.replace(" ", "_")}}
  end
end
