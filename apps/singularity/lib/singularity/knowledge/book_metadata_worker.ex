defmodule Singularity.Knowledge.BookMetadataWorker do
  @moduledoc "Extracts the bibliographic metadata of an uploaded EPUB."

  use Styx.Worker, queue: :default, max_attempts: 1

  alias Singularity.Knowledge
  alias Singularity.Knowledge.Epub

  @impl Styx.Worker
  def perform(%Styx.Job{args: %{"item_id" => item_id}}) do
    case Knowledge.get_book(item_id) do
      nil -> {:cancel, :book_not_found}
      book -> extract(book)
    end
  end

  defp extract(book) do
    with {:ok, path, _filename} <- Knowledge.book_file(book),
         {:ok, fields} <- Epub.metadata(path) do
      {:ok, _book} = Knowledge.update_book_metadata(book, "ready", fields)
      :ok
    else
      {:error, reason} ->
        {:ok, _book} = Knowledge.update_book_metadata(book, "failed")
        {:error, reason}
    end
  end
end
