defmodule SingularityWeb.Outbound do
  @moduledoc """
  Links that leave the site go through the `/out` confirmation page first.
  `external_link/1` renders such a link; Markdown rendering rewrites its links
  with `path/1`.
  """
  use Phoenix.Component

  @doc "Whether the address is an http(s) URL with a host."
  @spec web?(term()) :: boolean()
  def web?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        host != ""

      _other ->
        false
    end
  end

  def web?(_url), do: false

  @doc "The confirmation page path for an outbound address."
  @spec path(String.t()) :: String.t()
  def path(url) when is_binary(url), do: "/out?" <> URI.encode_query(%{"to" => url})

  attr :href, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  @doc "A link to another site, through the confirmation page."
  def external_link(assigns) do
    ~H"""
    <a href={path(@href)} class={@class} rel="noopener noreferrer" {@rest}>
      {render_slot(@inner_block)}
    </a>
    """
  end
end
