defmodule SingularityRoleBootstrapConnection do
  @moduledoc false

  @service_name "singularity_role_provisioner"

  def write_service! do
    parameters =
      System.fetch_env!("SINGULARITY_ROLE_PROVISIONER_DATABASE_URL")
      |> connection_parameters!()

    IO.puts("[#{@service_name}]")

    parameters
    |> Enum.sort()
    |> Enum.each(fn {name, value} ->
      IO.puts("#{name}=#{service_value!(value)}")
    end)
  end

  defp connection_parameters!(url) do
    uri = URI.parse(url)

    unless uri.scheme in ["postgres", "postgresql"] and is_nil(uri.fragment) and
             not String.contains?(uri.authority || "", ",") do
      raise ArgumentError, "role provisioner URL must be a PostgreSQL connection URL"
    end

    %{}
    |> put_if_present("host", uri.host)
    |> put_if_present("port", uri.port)
    |> put_if_present("dbname", database_name(uri.path))
    |> put_userinfo(uri.userinfo)
    |> put_query(uri.query)
  end

  defp database_name(nil), do: nil
  defp database_name("/"), do: nil
  defp database_name("/" <> database), do: URI.decode(database)

  defp put_userinfo(parameters, nil), do: parameters

  defp put_userinfo(parameters, userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user] ->
        Map.put(parameters, "user", URI.decode(user))

      [user, password] ->
        parameters
        |> Map.put("user", URI.decode(user))
        |> Map.put("password", URI.decode(password))
    end
  end

  defp put_query(parameters, nil), do: parameters

  defp put_query(parameters, query) do
    Enum.reduce(URI.query_decoder(query), parameters, fn {name, value}, accumulator ->
      {name, value} =
        if name == "ssl" and value == "true", do: {"sslmode", "require"}, else: {name, value}

      unless name =~ ~r/\A[a-z_][a-z0-9_]*\z/ do
        raise ArgumentError, "invalid PostgreSQL connection parameter name"
      end

      Map.put(accumulator, name, value)
    end)
  end

  defp put_if_present(parameters, _name, nil), do: parameters
  defp put_if_present(parameters, _name, ""), do: parameters

  defp put_if_present(parameters, name, value) do
    Map.put(parameters, name, to_string(value))
  end

  defp service_value!(value) do
    if String.contains?(value, ["\0", "\r", "\n"]) or value != String.trim(value) do
      raise ArgumentError, "unsafe PostgreSQL connection parameter value"
    end

    value
  end
end

SingularityRoleBootstrapConnection.write_service!()
