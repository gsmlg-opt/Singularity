defmodule Singularity.Sources.Source do
  use Ecto.Schema

  import Ecto.Changeset

  alias Singularity.Collector

  @type t :: %__MODULE__{}

  schema "sources" do
    field :kind, :string
    field :name, :string
    field :config, :map, default: %{}
    field :enabled, :boolean, default: true
    field :interval_minutes, :integer
    field :next_run_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [:kind, :name, :config, :enabled, :interval_minutes])
    |> validate_required([:kind, :name])
    |> validate_collector()
  end

  defp validate_collector(changeset) do
    case Collector.fetch_module(get_field(changeset, :kind) || "") do
      :error ->
        add_error(changeset, :kind, "is not a registered source type")

      {:ok, collector} ->
        changeset
        |> put_default_interval(collector)
        |> validate_number(:interval_minutes, greater_than_or_equal_to: 5)
        |> validate_config(collector)
    end
  end

  defp put_default_interval(changeset, collector) do
    if get_field(changeset, :interval_minutes),
      do: changeset,
      else: put_change(changeset, :interval_minutes, collector.default_interval_minutes())
  end

  defp validate_config(changeset, collector) do
    case collector.validate_config(get_field(changeset, :config) || %{}) do
      {:ok, config} ->
        put_change(changeset, :config, config)

      {:error, errors} ->
        Enum.reduce(errors, changeset, fn {field, message}, acc ->
          add_error(acc, :config, "#{field} #{message}", field: field)
        end)
    end
  end
end
