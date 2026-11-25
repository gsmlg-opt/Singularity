defmodule Singularity.Knowledge.BookFiles do
  @moduledoc false

  alias Singularity.DataDir
  alias Singularity.Knowledge.Epub

  @directory "published-books"
  @max_bytes 1000 * 1024 * 1024

  def max_bytes, do: @max_bytes

  def prepare(path, filename, mode) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(path),
         :ok <- check_size(size, mode),
         :ok <- Epub.validate(path) do
      digest =
        path
        |> File.stream!(65_536)
        |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, hash ->
          :crypto.hash_update(hash, chunk)
        end)
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      title =
        filename
        |> String.replace("\\", "/")
        |> Path.basename()
        |> Path.rootname()
        |> clean_text(200)

      title = if title == "", do: "EPUB #{String.slice(digest, 0, 12)}", else: title
      {:ok, %{digest: digest, title: title, filename: title <> ".epub"}}
    else
      {:ok, %File.Stat{}} -> {:error, :invalid_epub}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in File.Error -> {:error, error.reason}
  end

  defp check_size(size, :upload) when size > @max_bytes, do: {:error, :too_large}
  defp check_size(_size, _mode), do: :ok

  def store(source, digest, mode) do
    destination = path(DataDir.path!(@directory), digest)

    cond do
      File.regular?(destination) -> :ok
      mode == :staged -> move_staged(source, destination)
      true -> copy_atomically(source, destination)
    end
  rescue
    error in File.Error -> {:error, error.reason}
  end

  defp move_staged(source, destination) do
    case File.rename(source, destination) do
      {:error, :exdev} -> copy_atomically(source, destination)
      result -> result
    end
  end

  defp copy_atomically(source, destination) do
    temporary =
      destination <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    try do
      with :ok <- File.cp(source, temporary), do: File.rename(temporary, destination)
    after
      File.rm(temporary)
    end
  end

  def locate(digest) do
    path = path(Path.join(DataDir.root(), @directory), digest)
    if File.regular?(path), do: {:ok, path}, else: {:error, :enoent}
  end

  defp path(directory, digest), do: Path.join(directory, digest <> ".epub")

  def clean_text(text, length) do
    text |> String.replace(~r/\p{Cc}/u, " ") |> String.trim() |> String.slice(0, length)
  end
end
