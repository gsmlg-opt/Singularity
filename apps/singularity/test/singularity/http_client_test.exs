defmodule Singularity.HttpClientTest do
  use ExUnit.Case, async: true

  alias Singularity.HttpClient

  @adapter {HTTP.Test, :http_client}

  setup do
    HTTP.Test.verify_on_exit!()
  end

  test "returns status, headers and the whole body" do
    HTTP.Test.expect(:http_client, fn request ->
      assert request.url.path == "/hello"
      assert HTTP.Headers.get(request.headers, "user-agent") == "Singularity"
      HTTP.Test.response(201, "hi", [{"x-test", "yes"}])
    end)

    assert {:ok, %{status: 201, body: "hi", headers: headers}} =
             HttpClient.get(
               "https://example.test/hello",
               [{"User-Agent", "Singularity"}],
               @adapter
             )

    assert HTTP.Headers.get(headers, "x-test") == "yes"
  end

  test "maps transport failures to {:transport, message}" do
    HTTP.Test.expect(:http_client, fn _request -> HTTP.Test.transport_error(:econnrefused) end)

    assert {:error, {:transport, "econnrefused"}} =
             HttpClient.get("https://example.test/", [], @adapter)
  end

  test "maps a body that fails mid-stream to a transport error instead of raising" do
    HTTP.Test.expect(:http_client, fn _request ->
      HTTP.Test.stream(["partial", {:error, :closed}])
    end)

    assert {:error, {:transport, message}} = HttpClient.get("https://example.test/", [], @adapter)
    assert message =~ "closed"
  end
end
