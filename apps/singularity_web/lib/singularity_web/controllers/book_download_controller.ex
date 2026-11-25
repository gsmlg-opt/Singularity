defmodule SingularityWeb.BookDownloadController do
  use SingularityWeb, :controller

  alias Singularity.Knowledge

  def show(conn, %{"id" => id}) do
    case Knowledge.book_file(Knowledge.get_book(id)) do
      {:ok, path, filename} ->
        send_download(conn, {:file, path},
          filename: filename,
          content_type: "application/epub+zip"
        )

      {:error, :enoent} ->
        conn |> put_status(:not_found) |> put_view(SingularityWeb.ErrorHTML) |> render(:"404")
    end
  end
end
