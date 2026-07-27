defmodule Mix.Tasks.Singularity.Restore do
  use Mix.Task

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.LocalDestination

  @shortdoc "Restores an encrypted Singularity backup"
  @forbidden_message "password or passphrase arguments are forbidden; use no-echo prompts or inherited descriptors"

  @impl Mix.Task
  def run(arguments) do
    with {:ok, options} <- parse_options(arguments),
         {:ok, config} <- task_config(),
         {:ok, source} <- normalize_reference(config.destination, options.source),
         {:ok, secrets} <- read_secrets(options, default_readers()),
         {:ok, result} <-
           call_adapter(config.operation, :run, [
             config.context,
             %{
               source: source,
               passphrase: secrets.passphrase,
               new_password: secrets.new_password
             }
           ]) do
      Mix.shell().info("restore complete manifest=#{manifest_id(result)}")
      result
    else
      {:error, %Error{code: :invalid}} -> Mix.raise(@forbidden_message)
      {:error, %Error{code: code}} -> Mix.raise("restore failed: #{code}")
      _invalid -> Mix.raise("restore failed: invalid runtime configuration")
    end
  end

  @spec parse_options([binary()]) :: {:ok, map()} | {:error, Error.t()}
  def parse_options(arguments) when is_list(arguments) do
    if forbidden_named_secret?(arguments) or not source_option_at_most_once?(arguments) or
         not restore_oracle_allowed?(arguments) do
      invalid()
    else
      {options, positional, invalid_options} =
        OptionParser.parse(arguments,
          strict: [
            passphrase_fd: :integer,
            password_fd: :integer,
            restore_oracle: :boolean,
            source: :string
          ]
        )

      with [] <- invalid_options,
           {:ok, source} <- source(options, positional),
           true <- valid_ref?(source),
           {:ok, passphrase_descriptor} <- optional_descriptor(options, :passphrase_fd),
           {:ok, password_descriptor} <- optional_descriptor(options, :password_fd),
           true <- Keyword.keys(options) == Enum.uniq(Keyword.keys(options)) do
        {:ok,
         %{
           source: source,
           passphrase_fd: passphrase_descriptor,
           password_fd: password_descriptor,
           restore_oracle: Keyword.get(options, :restore_oracle, false)
         }}
      else
        _invalid -> invalid()
      end
    end
  end

  def parse_options(_arguments), do: invalid()

  @spec read_secrets(map(), map()) ::
          {:ok, %{passphrase: binary(), new_password: binary()}} | {:error, Error.t()}
  def read_secrets(
        %{passphrase_fd: passphrase_descriptor, password_fd: password_descriptor},
        readers
      )
      when is_map(readers) do
    with {:ok, passphrase} <- read_secret(readers, passphrase_descriptor, :restore_passphrase),
         {:ok, new_password} <-
           read_secret(readers, password_descriptor, :new_owner_password),
         {:ok, passphrase} <- require_secret(passphrase),
         {:ok, new_password} <- require_secret(new_password) do
      {:ok, %{passphrase: passphrase, new_password: new_password}}
    else
      _invalid -> invalid()
    end
  rescue
    _exception -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  def read_secrets(_options, _readers), do: invalid()

  defp read_secret(readers, nil, purpose) do
    case Map.get(readers, :prompt_no_echo) do
      prompt when is_function(prompt, 1) -> prompt.(purpose)
      _invalid -> invalid()
    end
  end

  defp read_secret(readers, descriptor, purpose) when is_integer(descriptor) do
    case Map.get(readers, :read_descriptor_once) do
      read when is_function(read, 2) -> read.(descriptor, purpose)
      _invalid -> invalid()
    end
  end

  defp require_secret(secret) when is_list(secret),
    do: secret |> List.to_string() |> require_secret()

  defp require_secret(secret) when is_binary(secret) do
    case strip_transport_terminator(secret) do
      "" -> invalid()
      normalized -> {:ok, normalized}
    end
  end

  defp require_secret(_secret), do: invalid()

  defp default_readers do
    %{
      prompt_no_echo: &prompt_no_echo/1,
      read_descriptor_once: &read_descriptor_once/2
    }
  end

  defp prompt_no_echo(:restore_passphrase), do: prompt("Restore passphrase: ")
  defp prompt_no_echo(:new_owner_password), do: prompt("New owner password: ")

  defp prompt(prompt) do
    IO.write(prompt)

    case :io.get_password(Process.group_leader()) do
      secret when is_binary(secret) or is_list(secret) -> {:ok, secret}
      _invalid -> {:error, :unavailable}
    end
  end

  defp read_descriptor_once(descriptor, purpose)
       when is_integer(descriptor) and descriptor >= 0 and
              purpose in [:restore_passphrase, :new_owner_password] do
    case File.read("/proc/self/fd/#{descriptor}") do
      {:ok, secret} -> {:ok, strip_transport_terminator(secret)}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp strip_transport_terminator(secret) do
    size = byte_size(secret)

    cond do
      size >= 2 and binary_part(secret, size - 2, 2) == "\r\n" ->
        binary_part(secret, 0, size - 2)

      size >= 1 and binary_part(secret, size - 1, 1) == "\n" ->
        binary_part(secret, 0, size - 1)

      true ->
        secret
    end
  end

  defp task_config do
    case Application.fetch_env(:singularity_runtime, :restore_task) do
      {:ok, %{operation: operation, context: context}}
      when operation not in [nil, false] and is_map(context) ->
        with {:ok, destination} <- destination_adapter(context) do
          {:ok, %{operation: operation, context: context, destination: destination}}
        end

      _invalid ->
        invalid()
    end
  end

  defp destination_adapter(%{destination: destination})
       when destination not in [nil, false],
       do: {:ok, destination}

  defp destination_adapter(_context) do
    case Application.fetch_env(:singularity_storage, :backup_root) do
      {:ok, backup_root} when is_binary(backup_root) and backup_root != "" ->
        {:ok, {LocalDestination, %{backup_root: backup_root}}}

      _invalid ->
        invalid()
    end
  end

  defp optional_descriptor(options, key) do
    case Keyword.get_values(options, key) do
      [] -> {:ok, nil}
      [descriptor] when is_integer(descriptor) and descriptor >= 0 -> {:ok, descriptor}
      _invalid -> invalid()
    end
  end

  defp source(options, []) do
    case Keyword.get_values(options, :source) do
      [source] -> {:ok, source}
      _invalid -> invalid()
    end
  end

  defp source(options, [source]) do
    case Keyword.get_values(options, :source) do
      [] -> {:ok, source}
      _invalid -> invalid()
    end
  end

  defp source(_options, _positional), do: invalid()

  defp source_option_at_most_once?(arguments) do
    Enum.count(arguments, fn
      "--source" -> true
      "--source=" <> _reference -> true
      _argument -> false
    end) <= 1
  end

  defp restore_oracle_allowed?(arguments) do
    case Enum.filter(arguments, &restore_oracle_argument?/1) do
      [] -> true
      ["--restore-oracle"] -> Mix.env() == :test
      _invalid -> false
    end
  end

  defp restore_oracle_argument?("--restore-oracle"), do: true
  defp restore_oracle_argument?("--no-restore-oracle"), do: true
  defp restore_oracle_argument?("--restore-oracle=" <> _value), do: true
  defp restore_oracle_argument?(_argument), do: false

  defp forbidden_named_secret?(arguments) do
    Enum.any?(arguments, fn
      "--password" -> true
      "--passphrase" -> true
      "--password=" <> _secret -> true
      "--passphrase=" <> _secret -> true
      _argument -> false
    end)
  end

  defp valid_ref?(reference), do: LocalDestination.valid_ref?(reference)

  defp normalize_reference(module, reference)
       when is_atom(module) and not is_nil(module),
       do: invoke_adapter(module, :normalize, [reference])

  defp normalize_reference({module, context}, reference)
       when is_atom(module) and not is_nil(module),
       do: invoke_adapter(module, :normalize, [context, reference])

  defp normalize_reference(_adapter, _reference), do: adapter_unavailable()

  defp manifest_id(%{manifest_id: manifest_id}), do: manifest_id
  defp manifest_id(%{id: manifest_id}), do: manifest_id
  defp manifest_id(_manifest), do: "unknown"

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: invoke_adapter(module, function, arguments)

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: invoke_adapter(module, function, [context | arguments])

  defp call_adapter(_adapter, _function, _arguments), do: adapter_unavailable()

  defp invoke_adapter(module, function, arguments) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(arguments)) do
      case apply(module, function, arguments) do
        {:ok, value} when is_map(value) and map_size(value) > 0 -> {:ok, value}
        {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
        {:error, %Error{} = error} -> {:error, error}
        _malformed -> adapter_unavailable()
      end
    else
      adapter_unavailable()
    end
  rescue
    _exception -> adapter_unavailable()
  catch
    _kind, _reason -> adapter_unavailable()
  end

  defp adapter_unavailable,
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}

  defp invalid, do: {:error, Error.new(:invalid)}
end
