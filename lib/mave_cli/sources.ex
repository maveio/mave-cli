defmodule MaveCli.Sources do
  @moduledoc false

  alias MaveCli.Downloader

  @cdn_domain "video-dns.com"

  def manifest(embed, opts \\ []) do
    with {:ok, url} <- url(embed, "manifest.json", opts) do
      request = Keyword.get(opts, :request, &Req.request/1)

      case request.(
             method: :get,
             url: url,
             headers: [{"accept", "application/json"}, {"user-agent", user_agent()}],
             retry: :transient,
             max_retries: 2,
             receive_timeout: 30_000
           ) do
        {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
        {:ok, %{status: status, body: body}} -> {:error, {:api, status, error_message(body)}}
        {:error, exception} -> {:error, {:transport, Exception.message(exception)}}
      end
    end
  end

  def url(embed, path, opts \\ []) when is_binary(embed) and is_binary(path) do
    with {:ok, space_hash, embed_id} <- split_embed(embed),
         {:ok, encoded_path} <- encode_path(path) do
      domain = Keyword.get(opts, :cdn_domain, @cdn_domain)
      base_url = opts[:cdn_base_url] || "https://space-#{space_hash}.#{domain}"
      base_url = base_url |> String.replace("{space}", space_hash) |> String.trim_trailing("/")
      {:ok, "#{base_url}/#{embed_id}/#{encoded_path}"}
    end
  end

  # Output directory is chosen by the local operator; downloaded metadata cannot choose it.
  # sobelow_skip ["Traversal.FileModule"]
  def download(embed, path, destination, opts \\ []) do
    destination = Path.expand(destination)

    if File.exists?(destination) and not Keyword.get(opts, :overwrite, false) do
      {:error, "destination file already exists; use --yes to overwrite: #{destination}"}
    else
      with {:ok, source_url} <- url(embed, path, opts),
           {:ok, acquired} <-
             Downloader.acquire(source_url, Keyword.take(opts, [:progress, :request])) do
        try do
          with :ok <- File.mkdir_p(Path.dirname(destination)),
               :ok <- save_download(acquired.path, destination, opts) do
            {:ok, %{"downloaded" => true, "path" => destination, "url" => source_url}}
          else
            {:error, reason} ->
              {:error, "could not save file: #{:file.format_error(reason)}"}
          end
        after
          Downloader.cleanup(acquired)
        end
      end
    end
  end

  # Source is our private staging file; destination is operator-selected.
  # No-overwrite uses exclusive creation; replacement requires --yes.
  # sobelow_skip ["Traversal.FileModule"]
  defp save_download(source, destination, opts) do
    if Keyword.get(opts, :overwrite, false) do
      File.cp(source, destination)
    else
      copy_exclusive(source, destination)
    end
  end

  # The operator selects the destination. Exclusive creation rejects existing files and symlinks atomically.
  # sobelow_skip ["Traversal.FileModule"]
  defp copy_exclusive(source, destination) do
    case File.open(destination, [:write, :binary, :exclusive], &copy_to_file(source, &1)) do
      {:ok, result} -> result
      {:error, _reason} = error -> error
    end
  end

  defp copy_to_file(source, file) do
    case :file.copy(String.to_charlist(source), file) do
      {:ok, _bytes} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp split_embed(embed) do
    embed = String.trim(embed)

    if byte_size(embed) == 15 do
      {space_hash, embed_id} = String.split_at(embed, 5)
      {:ok, space_hash, embed_id}
    else
      {:error, "invalid combined embed ID (expected 15 characters): #{embed}"}
    end
  end

  defp encode_path(path) do
    path = path |> String.trim() |> String.trim_leading("/")

    cond do
      path == "" ->
        {:error, "source path must not be empty"}

      URI.parse(path).scheme != nil ->
        {:error, "source path must be relative"}

      Enum.any?(Path.split(path), &(&1 == "..")) ->
        {:error, "source path must not contain .."}

      true ->
        {:ok,
         path
         |> String.split("/")
         |> Enum.map_join("/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))}
    end
  end

  defp user_agent, do: "mave-cli/#{MaveCli.version()}"
  defp error_message(body) when is_binary(body), do: body |> String.slice(0, 240) |> String.trim()
  defp error_message(body), do: Jason.encode!(body)
end
