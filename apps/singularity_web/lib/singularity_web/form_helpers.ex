defmodule SingularityWeb.FormHelpers do
  @moduledoc "Form error rendering shared by all pages; messages go through the errors domain."
  use Phoenix.Component

  @doc "Translates one changeset error through the `errors` gettext domain."
  def translate_error({message, opts}) do
    case opts[:count] do
      nil -> Gettext.dgettext(SingularityWeb.Gettext, "errors", message, opts)
      count -> Gettext.dngettext(SingularityWeb.Gettext, "errors", message, message, count, opts)
    end
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :field, :atom, required: true

  @doc "Renders a field's errors once its changeset has been validated or submitted."
  def field_errors(assigns) do
    assigns = assign(assigns, :messages, messages(assigns.form.source, assigns.field))

    ~H"""
    <p :for={message <- @messages} class="text-sm text-error" data-role="error">{message}</p>
    """
  end

  defp messages(%Ecto.Changeset{action: action, errors: errors}, field) when not is_nil(action),
    do: for({^field, error} <- errors, do: translate_error(error))

  defp messages(_source, _field), do: []
end
