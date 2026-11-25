defmodule Singularity.Knowledge.Epub do
  @moduledoc "Reads EPUB package metadata without extracting or loading the book into memory."

  @mimetype "application/epub+zip"
  @container ~c"META-INF/container.xml"
  @metadata_limit 1024 * 1024

  def validate(path) do
    with {:ok, files} <- :zip.list_dir(String.to_charlist(path)),
         true <- has_entry?(files, @container),
         {:ok, {:ok, @mimetype}} <-
           File.open(path, [:read, :binary], &read_entry(&1, files, ~c"mimetype")) do
      :ok
    else
      _invalid -> {:error, :invalid_epub}
    end
  end

  def metadata(path) do
    with {:ok, files} <- :zip.list_dir(String.to_charlist(path)),
         {:ok, {:ok, fields}} <- File.open(path, [:read, :binary], &read_metadata(&1, files)) do
      {:ok, fields}
    else
      _invalid -> {:error, :invalid_epub_metadata}
    end
  end

  defp read_metadata(file, files) do
    with {:ok, container} <- read_entry(file, files, @container),
         {:ok, document} <- Floki.parse_document(container),
         [package_path | _] <- Floki.attribute(document, "rootfile", "full-path"),
         {:ok, package} <- read_entry(file, files, String.to_charlist(package_path)),
         {:ok, document} <- Floki.parse_document(package),
         [{"metadata", _, nodes} | _] <- Floki.find(document, "metadata") do
      title = nodes |> values("title") |> List.first()
      author = nodes |> values("creator") |> Enum.join(", ")

      {:ok,
       Map.filter(%{"title" => title, "author" => author}, fn {_key, value} ->
         value not in [nil, ""]
       end)}
    end
  end

  defp values(nodes, field) do
    for {tag, _, _} = node <- nodes, List.last(String.split(tag, ":")) == field do
      node |> Floki.text() |> Singularity.Knowledge.BookFiles.clean_text(512)
    end
    |> Enum.reject(&(&1 == ""))
  end

  defp has_entry?(files, name),
    do: Enum.any?(files, &match?({:zip_file, ^name, _, _, _, _}, &1))

  defp read_entry(file, files, name) do
    with {:zip_file, ^name, info, _, offset, packed} <-
           Enum.find(files, &match?({:zip_file, ^name, _, _, _, _}, &1)),
         size = elem(info, 1),
         true <- size in 1..@metadata_limit and packed in 1..@metadata_limit,
         {:ok,
          <<"PK", 3, 4, _version::16, flags::little-16, method::little-16, _fields::128,
            name_size::little-16, extra_size::little-16>>} <- :file.pread(file, offset, 30),
         true <- rem(flags, 2) == 0,
         encoded_name = :unicode.characters_to_binary(name),
         {:ok, ^encoded_name} <- :file.pread(file, offset + 30, name_size),
         {:ok, bytes} when byte_size(bytes) == packed <-
           :file.pread(file, offset + 30 + name_size + extra_size, packed),
         {:ok, expanded} when byte_size(expanded) == size <- expand(method, bytes, size) do
      {:ok, expanded}
    else
      _invalid -> {:error, :invalid_entry}
    end
  end

  defp expand(0, bytes, _size), do: {:ok, bytes}

  defp expand(8, bytes, size) do
    zlib = :zlib.open()

    try do
      :ok = :zlib.inflateInit(zlib, -15)

      with {:ok, data} <- inflate(zlib, bytes, size, []),
           :ok <- :zlib.inflateEnd(zlib) do
        {:ok, data}
      end
    rescue
      ErlangError -> {:error, :invalid_deflate}
    after
      :zlib.close(zlib)
    end
  end

  defp expand(_method, _bytes, _size), do: {:error, :unsupported_compression}

  defp inflate(zlib, bytes, remaining, acc) do
    {status, output} = :zlib.safeInflate(zlib, bytes)
    size = IO.iodata_length(output)

    cond do
      size > remaining -> {:error, :invalid_entry_size}
      status == :finished -> {:ok, IO.iodata_to_binary(Enum.reverse([output | acc]))}
      true -> inflate(zlib, <<>>, remaining - size, [output | acc])
    end
  end
end
