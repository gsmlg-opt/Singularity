defmodule Singularity.Core.Error do
  @moduledoc "Stable errors returned across adapter boundaries."

  @codes ~w[
    unauthenticated vault_locked forbidden not_found conflict invalid
    upload_expired upload_too_large unsupported_media_type integrity_failure
    storage_unavailable job_failed backup_invalid
  ]a
  @misuse_message "invalid error construction"

  @enforce_keys [:code]
  defstruct [:code, :message, details: %{}, retryable?: false]

  @type code ::
          :unauthenticated
          | :vault_locked
          | :forbidden
          | :not_found
          | :conflict
          | :invalid
          | :upload_expired
          | :upload_too_large
          | :unsupported_media_type
          | :integrity_failure
          | :storage_unavailable
          | :job_failed
          | :backup_invalid

  @type t :: %__MODULE__{
          code: code(),
          message: String.t() | nil,
          details: map(),
          retryable?: boolean()
        }

  @spec codes() :: [code()]
  def codes, do: @codes

  @spec new(term(), term()) :: t()
  def new(code, opts \\ []) do
    if code in @codes and valid_options?(opts) do
      %__MODULE__{
        code: code,
        message: Keyword.get(opts, :message),
        details: Keyword.get(opts, :details, %{}),
        retryable?: Keyword.get(opts, :retryable?, false)
      }
    else
      raise ArgumentError, @misuse_message
    end
  end

  defp valid_options?(opts) when is_list(opts) do
    Keyword.keyword?(opts) and Enum.all?(opts, &valid_option?/1)
  end

  defp valid_options?(_opts), do: false

  defp valid_option?({:message, message}), do: valid_message?(message)
  defp valid_option?({:details, details}), do: is_map(details)
  defp valid_option?({:retryable?, retryable?}), do: is_boolean(retryable?)
  defp valid_option?(_option), do: false

  defp valid_message?(message), do: is_binary(message) or is_nil(message)
end
