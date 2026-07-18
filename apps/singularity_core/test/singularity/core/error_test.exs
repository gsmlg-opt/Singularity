defmodule Singularity.Core.ErrorTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error

  @codes ~w[
    unauthenticated vault_locked forbidden not_found conflict invalid
    upload_expired upload_too_large unsupported_media_type integrity_failure
    storage_unavailable job_failed backup_invalid
  ]a
  @misuse_message "invalid error construction"

  test "exposes exactly the stable foundation error codes" do
    assert Error.codes() == @codes
  end

  test "constructs stable errors with safe defaults" do
    assert %Error{
             code: :invalid,
             message: nil,
             details: %{},
             retryable?: false
           } = Error.new(:invalid)

    assert %Error{
             code: :storage_unavailable,
             message: "temporarily unavailable",
             details: %{operation: "stat"},
             retryable?: true
           } =
             Error.new(:storage_unavailable,
               message: "temporarily unavailable",
               details: %{operation: "stat"},
               retryable?: true
             )
  end

  test "rejects unsupported codes with one deliberate generic exception" do
    for code <- [:timeout, :unsupported, "secret-error-code"] do
      assert_raise ArgumentError, @misuse_message, fn ->
        Error.new(code)
      end
    end
  end

  test "rejects malformed or unsupported options without echoing their values" do
    misuse = [
      %{message: "secret-message"},
      [:not_a_keyword_pair],
      [unknown: "secret-option"],
      [message: 123],
      [message: "valid", message: 123],
      [details: :secret_details],
      [retryable?: :yes]
    ]

    for opts <- misuse do
      assert_raise ArgumentError, @misuse_message, fn ->
        Error.new(:invalid, opts)
      end
    end
  end
end
