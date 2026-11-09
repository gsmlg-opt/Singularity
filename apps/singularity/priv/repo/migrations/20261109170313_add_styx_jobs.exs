defmodule Singularity.Repo.Migrations.AddStyxJobs do
  use Ecto.Migration

  def up, do: Styx.Migrations.up()
  def down, do: Styx.Migrations.down(version: 1)
end
