defmodule MaveCli.Config do
  @moduledoc false

  alias MaveCli.PrivateFile

  @filename "config.json"

  def token(explicit \\ nil, opts \\ []) do
    case resolve_token(explicit, System.get_env("MAVE_TOKEN"), nil) do
      nil -> stored_token(load(), api_base_url(opts))
      token -> {:ok, token}
    end
  end

  def resolve_token(explicit, environment, stored) do
    Enum.find([explicit, environment, stored], &(is_binary(&1) and String.trim(&1) != ""))
  end

  def save_token(token, opts \\ []) when is_binary(token) do
    data = %{"token" => String.trim(token), "api_base_url" => api_base_url(opts)}
    PrivateFile.write_atomic(path(), Jason.encode!(data, pretty: true))
  end

  # Path comes from the operator-selected configuration root, not from a server response.
  # sobelow_skip ["Traversal.FileModule"]
  def delete_token do
    case File.rm(path()) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  def source(explicit \\ nil, opts \\ []) do
    cond do
      present?(explicit) -> :flag
      present?(System.get_env("MAVE_TOKEN")) -> :environment
      present?(load()["token"]) -> stored_source(load(), api_base_url(opts))
      true -> :missing
    end
  end

  def path do
    Path.join(config_home(), Path.join("mave", @filename))
  end

  # Read only the operator-selected configuration file; remote payloads cannot select this path.
  # sobelow_skip ["Traversal.FileModule"]
  defp load do
    with {:ok, content} <- File.read(path()),
         {:ok, data} when is_map(data) <- Jason.decode(content) do
      data
    else
      _ -> %{}
    end
  end

  defp config_home do
    cond do
      present?(System.get_env("MAVE_CONFIG_HOME")) ->
        System.fetch_env!("MAVE_CONFIG_HOME")

      present?(System.get_env("XDG_CONFIG_HOME")) ->
        System.fetch_env!("XDG_CONFIG_HOME")

      match?({:win32, _}, :os.type()) and present?(System.get_env("APPDATA")) ->
        System.fetch_env!("APPDATA")

      true ->
        Path.join(System.user_home!(), ".config")
    end
  end

  defp stored_token(data, base_url) do
    case stored_source(data, base_url) do
      :config ->
        {:ok, data["token"]}

      :missing ->
        {:error, "no token found; use `mave auth login` or MAVE_TOKEN"}

      :unbound ->
        {:error,
         "stored token is not bound to a server; run `mave auth login` again for this server"}

      :different_server ->
        {:error,
         "stored token belongs to a different server; use a separate MAVE_CONFIG_HOME and log in to this server"}
    end
  end

  defp stored_source(data, base_url) do
    cond do
      not present?(data["token"]) -> :missing
      not present?(data["api_base_url"]) -> :unbound
      data["api_base_url"] == base_url -> :config
      true -> :different_server
    end
  end

  defp api_base_url(opts) do
    base = opts[:base_url] || Application.fetch_env!(:mave_cli, :api_base_url)
    String.trim_trailing(base, "/")
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
