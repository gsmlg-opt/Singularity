defmodule Singularity.Runtime.Test.SecretInput do
  @moduledoc false

  @spec capture_prompt(binary(), (-> term())) :: binary()
  def capture_prompt(secret, callback)
      when is_binary(secret) and is_function(callback, 0) do
    ExUnit.CaptureIO.capture_io(
      [input: secret <> "\n", capture_prompt: false],
      callback
    )
  end
end
