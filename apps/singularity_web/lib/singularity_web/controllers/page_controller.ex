defmodule SingularityWeb.PageController do
  use SingularityWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
