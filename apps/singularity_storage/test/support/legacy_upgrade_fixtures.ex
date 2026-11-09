defmodule Singularity.Storage.LegacyUpgradeFixtures do
  @moduledoc false

  @root Path.expand("../fixtures/upgrade/v0.1.0", __DIR__)
  @commit "c49dc0aeda1d0115b20ff291f0da658f7e558b43"
  @tree "203135f6e35b72aaab269b75a30dcf2ef080bfe3"
  @fingerprint "5e3c5b3ad94f294379a00c80136617910c3537fc8a6288266ecc9a53e5f6eb62"
  @bytes 247_412
  @manifest_keys Enum.sort(~w(schema release commit tree fingerprint bytes files))
  @file_keys Enum.sort(~w(filename original fixture blob sha256 bytes))

  def identity! do
    require_directory!(@root)
    require_identity!(Enum.sort(entries!(@root)) == ["migrations", "source.json"])
    migrations = Path.join(@root, "migrations")
    require_directory!(migrations)

    manifest =
      case @root
           |> Path.join("source.json")
           |> read_regular!()
           |> Jason.decode(objects: :ordered_objects) do
        {:ok, manifest} -> manifest
        {:error, _reason} -> invalid_identity!()
      end

    inventory =
      Map.new(entries!(migrations), fn filename ->
        {"migrations/" <> filename, {:regular, read_regular!(Path.join(migrations, filename))}}
      end)

    validate_identity!(manifest, inventory)
  end

  def validate_identity!(manifest, inventory) do
    manifest = plain_json!(manifest)
    require_identity!(valid_manifest?(manifest))
    files = manifest["files"]
    require_identity!(Enum.all?(files, &valid_file?/1))
    filenames = Enum.map(files, & &1["filename"])
    require_identity!(filenames == Enum.sort(filenames))
    require_identity!(length(Enum.uniq(filenames)) == 22)
    require_identity!(Enum.sum(Enum.map(files, & &1["bytes"])) == @bytes)

    fingerprint =
      files
      |> Enum.map(fn file ->
        [file["filename"], "\t", file["blob"], "\t", file["sha256"], "\n"]
      end)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    require_identity!(fingerprint == @fingerprint)
    require_identity!(is_map(inventory))

    require_identity!(
      Enum.sort(Map.keys(inventory)) == Enum.sort(Enum.map(files, & &1["fixture"]))
    )

    for file <- files do
      case Map.fetch!(inventory, file["fixture"]) do
        {:regular, bytes} when is_binary(bytes) ->
          require_identity!(byte_size(bytes) == file["bytes"])

          require_identity!(
            Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == file["sha256"]
          )

          require_identity!(
            Base.encode16(
              :crypto.hash(:sha, ["blob ", Integer.to_string(byte_size(bytes)), <<0>>, bytes]),
              case: :lower
            ) == file["blob"]
          )

        _other ->
          invalid_identity!()
      end
    end

    %{
      commit: @commit,
      tree: @tree,
      fingerprint: @fingerprint,
      bytes: @bytes,
      files:
        Enum.map(files, fn file ->
          %{
            filename: file["filename"],
            original: file["original"],
            fixture: file["fixture"],
            blob: file["blob"],
            sha256: file["sha256"],
            bytes: file["bytes"]
          }
        end)
    }
  end

  defp valid_manifest?(manifest) do
    is_map(manifest) and Enum.sort(Map.keys(manifest)) == @manifest_keys and
      manifest["schema"] === 1 and manifest["release"] == "v0.1.0" and
      manifest["commit"] == @commit and manifest["tree"] == @tree and
      manifest["fingerprint"] == @fingerprint and manifest["bytes"] === @bytes and
      is_list(manifest["files"]) and length(manifest["files"]) == 22
  end

  defp valid_file?(file) when is_map(file) do
    Enum.sort(Map.keys(file)) == @file_keys and
      is_binary(file["filename"]) and
      String.match?(file["filename"], ~r/\A[0-9]{14}_[a-z0-9_]+\.exs\z/) and
      file["original"] ==
        "apps/singularity_storage/priv/repo/migrations/" <> file["filename"] and
      file["fixture"] == "migrations/" <> file["filename"] and
      is_binary(file["blob"]) and String.match?(file["blob"], ~r/\A[0-9a-f]{40}\z/) and
      is_binary(file["sha256"]) and String.match?(file["sha256"], ~r/\A[0-9a-f]{64}\z/) and
      is_integer(file["bytes"]) and file["bytes"] > 0
  end

  defp valid_file?(_other), do: false

  defp plain_json!(%Jason.OrderedObject{values: values}) do
    require_identity!(is_list(values))
    require_identity!(Enum.all?(values, &match?({key, _value} when is_binary(key), &1)))
    keys = Enum.map(values, &elem(&1, 0))
    require_identity!(length(Enum.uniq(keys)) == length(keys))
    Map.new(values, fn {key, value} -> {key, plain_json!(value)} end)
  end

  defp plain_json!(value) when is_map(value) do
    value |> :maps.to_list() |> Map.new(fn {key, item} -> {key, plain_json!(item)} end)
  end

  defp plain_json!(value) when is_list(value), do: Enum.map(value, &plain_json!/1)
  defp plain_json!(value), do: value

  defp require_directory!(path) do
    parent = Path.dirname(path)
    if parent != path, do: require_directory!(parent)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      _other -> invalid_identity!()
    end
  end

  defp entries!(path) do
    case File.ls(path) do
      {:ok, entries} -> entries
      {:error, _reason} -> invalid_identity!()
    end
  end

  defp read_regular!(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.read(path) do
          {:ok, bytes} -> bytes
          {:error, _reason} -> invalid_identity!()
        end

      _other ->
        invalid_identity!()
    end
  end

  defp require_identity!(true), do: :ok
  defp require_identity!(_other), do: invalid_identity!()
  defp invalid_identity!, do: raise(ArgumentError, "legacy_migration_identity")
end
