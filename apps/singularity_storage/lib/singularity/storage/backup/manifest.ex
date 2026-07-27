defmodule Singularity.Storage.Backup.Manifest do
  @moduledoc "Validates and encodes the authenticated backup inventory."

  alias Singularity.Core.Error

  @wire_tag "singularity.backup.manifest"
  @version 1
  @recovery_label "backup_recovery"
  @max_record_type 0xFFFE
  @max_payload_length 0xFFFFFFFFFFFFFFFF
  @max_encoded_bytes 67_108_864
  @max_inventory_entries 1_000_000

  @manifest_keys [
    :version,
    :manifest_id,
    :vault_ids,
    :snapshot_id,
    :outbox_high_water_mark,
    :recovery,
    :inventory
  ]
  @recovery_keys ["binding", "label", "wrapper"]
  @binding_keys ["manifest_id", "vault_id"]
  @inventory_keys [:position, :record_type, :payload_length, :sha256]

  @type inventory_entry :: %{
          position: non_neg_integer(),
          record_type: non_neg_integer(),
          payload_length: non_neg_integer(),
          sha256: <<_::256>>
        }

  @type t :: %{
          version: 1,
          manifest_id: Ecto.UUID.t(),
          vault_ids: [Ecto.UUID.t(), ...],
          snapshot_id: Ecto.UUID.t(),
          outbox_high_water_mark: non_neg_integer(),
          recovery: map(),
          inventory: [inventory_entry()]
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    if valid_manifest?(attrs) do
      {:ok, Map.take(attrs, @manifest_keys)}
    else
      invalid()
    end
  end

  def new(_attrs), do: invalid()

  @spec encode(map()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(manifest) do
    with {:ok, manifest} <- new(manifest) do
      encoded = manifest |> to_wire() |> :erlang.term_to_binary([:deterministic])

      if byte_size(encoded) <= @max_encoded_bytes, do: {:ok, encoded}, else: invalid()
    end
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, Error.t()}
  def decode(<<131, tag, _rest::binary>> = encoded)
      when tag != 80 and byte_size(encoded) <= @max_encoded_bytes do
    case :erlang.binary_to_term(encoded, [:safe, :used]) do
      {wire, consumed} when consumed == byte_size(encoded) -> from_wire(wire)
      _trailing_bytes -> invalid()
    end
  rescue
    ArgumentError -> invalid()
  end

  def decode(_encoded), do: invalid()

  @spec verify(map(), [map()]) :: :ok | {:error, Error.t()}
  def verify(manifest, records) do
    with {:ok, %{inventory: inventory}} <- new(manifest),
         true <- verified_inventory?(inventory, records) do
      :ok
    else
      _invalid -> invalid()
    end
  end

  defp valid_manifest?(attrs) do
    exact_keys?(attrs, @manifest_keys) and
      Map.fetch!(attrs, :version) == @version and
      canonical_uuid?(Map.fetch!(attrs, :manifest_id)) and
      valid_vault_ids?(Map.fetch!(attrs, :vault_ids)) and
      canonical_uuid?(Map.fetch!(attrs, :snapshot_id)) and
      valid_outbox_mark?(Map.fetch!(attrs, :outbox_high_water_mark)) and
      valid_recovery?(
        Map.fetch!(attrs, :recovery),
        Map.fetch!(attrs, :manifest_id),
        Map.fetch!(attrs, :vault_ids)
      ) and
      valid_inventory?(Map.fetch!(attrs, :inventory), 0)
  end

  defp valid_vault_ids?([_first | _rest] = vault_ids) do
    valid_uuid_list?(vault_ids) and
      MapSet.size(MapSet.new(vault_ids)) == length(vault_ids)
  end

  defp valid_vault_ids?(_vault_ids), do: false

  defp valid_uuid_list?([]), do: true

  defp valid_uuid_list?([uuid | rest]) do
    canonical_uuid?(uuid) and valid_uuid_list?(rest)
  end

  defp valid_uuid_list?(_improper), do: false

  defp valid_recovery?(recovery, manifest_id, vault_ids) when is_map(recovery) do
    if exact_keys?(recovery, @recovery_keys) do
      binding = Map.fetch!(recovery, "binding")
      wrapper = Map.fetch!(recovery, "wrapper")

      valid_binding?(binding, manifest_id, vault_ids) and
        Map.fetch!(recovery, "label") == @recovery_label and
        is_binary(wrapper) and wrapper != ""
    else
      false
    end
  end

  defp valid_recovery?(_recovery, _manifest_id, _vault_ids), do: false

  defp valid_binding?(binding, manifest_id, vault_ids) when is_map(binding) do
    if exact_keys?(binding, @binding_keys) do
      binding_manifest_id = Map.fetch!(binding, "manifest_id")
      binding_vault_id = Map.fetch!(binding, "vault_id")

      binding_manifest_id == manifest_id and
        canonical_uuid?(binding_manifest_id) and
        binding_vault_id in vault_ids
    else
      false
    end
  end

  defp valid_binding?(_binding, _manifest_id, _vault_ids), do: false

  defp valid_inventory?([], expected_position)
       when expected_position <= @max_inventory_entries,
       do: true

  defp valid_inventory?([entry | rest], expected_position)
       when is_map(entry) and expected_position < @max_inventory_entries do
    exact_keys?(entry, @inventory_keys) and
      Map.fetch!(entry, :position) == expected_position and
      valid_record_type?(Map.fetch!(entry, :record_type)) and
      valid_payload_length?(Map.fetch!(entry, :payload_length)) and
      valid_sha256?(Map.fetch!(entry, :sha256)) and
      valid_inventory?(rest, expected_position + 1)
  end

  defp valid_inventory?(_inventory, _expected_position), do: false

  defp exact_keys?(map, keys) do
    map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1))
  end

  defp canonical_uuid?(uuid) when is_binary(uuid) and byte_size(uuid) == 36 do
    Ecto.UUID.cast(uuid) == {:ok, uuid}
  end

  defp canonical_uuid?(_uuid), do: false

  defp valid_outbox_mark?(mark), do: is_integer(mark) and mark >= 0

  defp valid_record_type?(type) do
    is_integer(type) and type >= 0 and type <= @max_record_type
  end

  defp valid_payload_length?(length) do
    is_integer(length) and length >= 0 and length <= @max_payload_length
  end

  defp valid_sha256?(hash), do: is_binary(hash) and byte_size(hash) == 32

  defp verified_inventory?([], []), do: true

  defp verified_inventory?(
         [
           %{
             record_type: expected_type,
             payload_length: expected_length,
             sha256: expected_hash
           }
           | inventory
         ],
         [%{type: actual_type, payload: payload} | records]
       )
       when is_binary(payload) do
    actual_type == expected_type and
      byte_size(payload) == expected_length and
      :crypto.hash(:sha256, payload) == expected_hash and
      verified_inventory?(inventory, records)
  end

  defp verified_inventory?(_inventory, _records), do: false

  defp to_wire(manifest) do
    recovery = manifest.recovery
    binding = recovery["binding"]

    {
      @wire_tag,
      manifest.version,
      manifest.manifest_id,
      manifest.vault_ids,
      manifest.snapshot_id,
      manifest.outbox_high_water_mark,
      {recovery["label"], binding["manifest_id"], binding["vault_id"], recovery["wrapper"]},
      Enum.map(manifest.inventory, fn entry ->
        {entry.position, entry.record_type, entry.payload_length, entry.sha256}
      end)
    }
  end

  defp from_wire({
         @wire_tag,
         version,
         manifest_id,
         vault_ids,
         snapshot_id,
         outbox_high_water_mark,
         {recovery_label, recovery_manifest_id, recovery_vault_id, recovery_wrapper},
         inventory
       }) do
    with {:ok, inventory} <- inventory_from_wire(inventory, [], 0) do
      new(%{
        version: version,
        manifest_id: manifest_id,
        vault_ids: vault_ids,
        snapshot_id: snapshot_id,
        outbox_high_water_mark: outbox_high_water_mark,
        recovery: %{
          "binding" => %{
            "manifest_id" => recovery_manifest_id,
            "vault_id" => recovery_vault_id
          },
          "label" => recovery_label,
          "wrapper" => recovery_wrapper
        },
        inventory: inventory
      })
    end
  end

  defp from_wire(_wire), do: invalid()

  defp inventory_from_wire([], entries, count)
       when count <= @max_inventory_entries,
       do: {:ok, Enum.reverse(entries)}

  defp inventory_from_wire(
         [{position, record_type, payload_length, sha256} | rest],
         entries,
         count
       )
       when count < @max_inventory_entries do
    inventory_from_wire(
      rest,
      [
        %{
          position: position,
          record_type: record_type,
          payload_length: payload_length,
          sha256: sha256
        }
        | entries
      ],
      count + 1
    )
  end

  defp inventory_from_wire(_inventory, _entries, _count), do: invalid()

  defp invalid, do: {:error, Error.new(:backup_invalid)}
end
