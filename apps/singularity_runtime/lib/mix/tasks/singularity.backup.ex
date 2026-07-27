defmodule Mix.Tasks.Singularity.Backup do
  use Mix.Task

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.LocalDestination

  @shortdoc "Creates an encrypted vault backup"
  @forbidden_message "passphrase arguments are forbidden; use the no-echo prompt or --passphrase-fd"

  @impl Mix.Task
  def run(arguments) do
    with {:ok, options} <- parse_options(arguments),
         {:ok, config} <- task_config(),
         {:ok, destination_ref} <-
           normalize_reference(config.destination, options.destination_ref),
         {:ok, %{passphrase: passphrase}} <- read_secrets(options, default_readers()),
         {:ok, manifest} <-
           call_adapter(config.operation, :request, [
             config.runtime,
             config.session,
             passphrase,
             destination_ref
           ]) do
      Mix.shell().info("backup queued manifest=#{manifest.id}")
      manifest
    else
      {:error, %Error{code: :invalid}} -> Mix.raise(@forbidden_message)
      {:error, %Error{code: code}} -> Mix.raise("backup failed: #{code}")
      _invalid -> Mix.raise("backup failed: invalid runtime configuration")
    end
  end

  @spec parse_options([binary()]) :: {:ok, map()} | {:error, Error.t()}
  def parse_options(arguments) when is_list(arguments) do
    if forbidden_named_secret?(arguments) or not destination_once?(arguments) or
         not restore_oracle_allowed?(arguments) do
      invalid()
    else
      {options, positional, invalid_options} =
        OptionParser.parse(arguments,
          strict: [
            destination: :string,
            passphrase_fd: :integer,
            restore_oracle: :boolean
          ]
        )

      with [] <- invalid_options,
           [] <- positional,
           [destination_ref] <- Keyword.get_values(options, :destination),
           true <- valid_ref?(destination_ref),
           {:ok, descriptor} <- optional_descriptor(options, :passphrase_fd),
           true <- Keyword.keys(options) == Enum.uniq(Keyword.keys(options)) do
        {:ok,
         %{
           destination_ref: destination_ref,
           passphrase_fd: descriptor,
           restore_oracle: Keyword.get(options, :restore_oracle, false)
         }}
      else
        _invalid -> invalid()
      end
    end
  end

  def parse_options(_arguments), do: invalid()

  @spec read_secrets(map(), map()) :: {:ok, %{passphrase: binary()}} | {:error, Error.t()}
  def read_secrets(%{passphrase_fd: descriptor}, readers) when is_map(readers) do
    with {:ok, reader} <- secret_reader(readers, descriptor),
         {:ok, passphrase} <- reader.() do
      require_secret(passphrase)
    else
      _invalid -> invalid()
    end
  rescue
    _exception -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  def read_secrets(_options, _readers), do: invalid()

  defp secret_reader(readers, nil) do
    case Map.get(readers, :prompt_no_echo) do
      prompt when is_function(prompt, 1) ->
        {:ok, fn -> prompt.(:backup_passphrase) end}

      _invalid ->
        invalid()
    end
  end

  defp secret_reader(readers, descriptor) when is_integer(descriptor) do
    case Map.get(readers, :read_descriptor_once) do
      read when is_function(read, 2) ->
        {:ok, fn -> read.(descriptor, :backup_passphrase) end}

      _invalid ->
        invalid()
    end
  end

  defp require_secret(passphrase) when is_binary(passphrase) do
    case strip_transport_terminator(passphrase) do
      "" -> invalid()
      normalized -> {:ok, %{passphrase: normalized}}
    end
  end

  defp require_secret(passphrase) when is_list(passphrase) do
    passphrase
    |> List.to_string()
    |> require_secret()
  end

  defp require_secret(_passphrase), do: invalid()

  defp default_readers do
    %{
      prompt_no_echo: &prompt_no_echo/1,
      read_descriptor_once: &read_descriptor_once/2
    }
  end

  defp prompt_no_echo(:backup_passphrase) do
    IO.write("Backup passphrase: ")

    case :io.get_password(Process.group_leader()) do
      secret when is_binary(secret) or is_list(secret) -> {:ok, secret}
      _invalid -> {:error, :unavailable}
    end
  end

  defp read_descriptor_once(descriptor, :backup_passphrase)
       when is_integer(descriptor) and descriptor >= 0 do
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
    case Application.fetch_env(:singularity_runtime, :backup_task) do
      {:ok, %{operation: operation, runtime: runtime, session: session}}
      when operation not in [nil, false] and is_map(runtime) and is_map(session) ->
        with {:ok, destination} <- destination_adapter(runtime) do
          {:ok,
           %{
             destination: destination,
             operation: operation,
             runtime: runtime,
             session: session
           }}
        end

      _invalid ->
        invalid()
    end
  end

  defp destination_adapter(%{destination: destination})
       when destination not in [nil, false],
       do: {:ok, destination}

  defp destination_adapter(_runtime) do
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

  defp forbidden_named_secret?(arguments) do
    Enum.any?(arguments, fn
      "--password" -> true
      "--passphrase" -> true
      "--password=" <> _secret -> true
      "--passphrase=" <> _secret -> true
      _argument -> false
    end)
  end

  defp destination_once?(arguments) do
    Enum.count(arguments, fn
      "--destination" -> true
      "--destination=" <> _reference -> true
      _argument -> false
    end) == 1
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

  defp valid_ref?(reference), do: LocalDestination.valid_ref?(reference)

  defp normalize_reference(module, reference)
       when is_atom(module) and not is_nil(module),
       do: invoke_normalizer(module, [reference])

  defp normalize_reference({module, context}, reference)
       when is_atom(module) and not is_nil(module),
       do: invoke_normalizer(module, [context, reference])

  defp normalize_reference(_adapter, _reference), do: adapter_unavailable()

  defp invoke_normalizer(module, arguments) do
    if Code.ensure_loaded?(module) and function_exported?(module, :normalize, length(arguments)) do
      case apply(module, :normalize, arguments) do
        {:ok, reference} when is_binary(reference) and reference != "" -> {:ok, reference}
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

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module) do
    invoke_adapter(module, function, arguments)
  end

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module) do
    invoke_adapter(module, function, [context | arguments])
  end

  defp call_adapter(_adapter, _function, _arguments), do: adapter_unavailable()

  defp invoke_adapter(module, function, arguments) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(arguments)) do
      case apply(module, function, arguments) do
        {:ok, %{id: id} = result} when is_binary(id) and id != "" -> {:ok, result}
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

  defp adapter_unavailable do
    {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  defp invalid, do: {:error, Error.new(:invalid)}
end
