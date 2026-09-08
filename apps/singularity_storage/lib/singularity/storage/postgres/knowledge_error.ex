defmodule Singularity.Storage.Postgres.KnowledgeError do
  @moduledoc false
  alias Singularity.Core.Error

  def from(%Error{code: code, retryable?: retryable?}),
    do: Error.new(code, retryable?: retryable?)

  def from(%Postgrex.Error{postgres: %{constraint: "document_extraction_conflict_check"}}),
    do: Error.new(:conflict)

  def from(%Postgrex.Error{postgres: %{constraint: "document_extraction_authority_check"}}),
    do: Error.new(:forbidden)

  def from(%Postgrex.Error{postgres: %{code: :insufficient_privilege}}), do: Error.new(:forbidden)
  def from(%Postgrex.Error{postgres: %{code: :unique_violation}}), do: Error.new(:conflict)

  def from(%Postgrex.Error{postgres: %{code: code}})
      when code in [
             :check_violation,
             :foreign_key_violation,
             :not_null_violation,
             :invalid_text_representation,
             :numeric_value_out_of_range
           ],
      do: Error.new(:invalid)

  def from(%Ecto.Changeset{}), do: Error.new(:invalid)
  def from(%Ecto.ConstraintError{type: :unique}), do: Error.new(:conflict)
  def from(%Ecto.ConstraintError{}), do: Error.new(:invalid)
  def from(%Ecto.Query.CastError{}), do: Error.new(:invalid)
  def from(%Ecto.CastError{}), do: Error.new(:invalid)
  def from(_), do: Error.new(:storage_unavailable, retryable?: true)
end
