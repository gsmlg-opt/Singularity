defmodule Singularity.Web.LiveCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      use Singularity.Web.ConnCase

      import Phoenix.LiveViewTest
    end
  end
end
