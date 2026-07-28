defmodule Singularity.Web.CoreComponents do
  @moduledoc false

  use Phoenix.Component

  attr :title, :string, required: true
  slot :inner_block, required: true

  def page(assigns) do
    ~H"""
    <section>
      <header>
        <h1>{@title}</h1>
      </header>
      {render_slot(@inner_block)}
    </section>
    """
  end
end
