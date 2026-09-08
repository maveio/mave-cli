defmodule MaveCli.Downloader do
  @moduledoc false

  alias MaveCli.{PrivateFile, TransferProgress}

  @user_agent "mave-cli/#{MaveCli.version()} (URL-to-TUS uploader; https://www.mave.io)"

  def acquire(source, opts \\ []) do
    uri = URI.parse(source)

    cond do
      uri.scheme in ["http", "https"] and is_binary(uri.host) -> download(source, opts)
      File.regular?(source) -> {:ok, %{path: Path.expand(source), temporary?: false}}
      true -> {:error, "source is not an existing file or a valid http(s) URL: #{source}"}
    end
  end

  # Temporary paths come from our random private directory and sanitized basename; local inputs are not cleaned.
  # sobelow_skip ["Traversal.FileModule"]
  def cleanup(%{temporary?: true, path: path}) do
    result = File.rm(path)
    File.rmdir(Path.dirname(path))
    result
  end

  def cleanup(_source), do: :ok

  defp download(url, opts) do
    case PrivateFile.create_directory(System.tmp_dir!()) do
      {:ok, directory} ->
        download_to(url, Path.join(directory, temporary_basename(url)), opts)

      {:error, reason} ->
        {:error, "could not create temporary file: #{:file.format_error(reason)}"}
    end
  end

  defp download_to(url, path, opts) do
    case PrivateFile.open(path, &stream(url, &1, path, opts)) do
      {:ok, {:ok, source}} ->
        {:ok, source}

      {:ok, {:error, _reason} = error} ->
        cleanup(%{temporary?: true, path: path})
        error

      {:error, reason} ->
        cleanup(%{temporary?: true, path: path})
        {:error, "could not open temporary file: #{:file.format_error(reason)}"}
    end
  catch
    kind, reason ->
      cleanup(%{temporary?: true, path: path})
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp stream(url, file, path, opts) do
    progress? = Keyword.get(opts, :progress, true)
    counter = :counters.new(1, [])

    into = fn {:data, data}, {request, response} ->
      :ok = IO.binwrite(file, data)
      :counters.add(counter, 1, byte_size(data))
      total = content_length(response)
      TransferProgress.transfer(:download, :counters.get(counter, 1), total, progress: progress?)
      {:cont, {request, response}}
    end

    request = Keyword.get(opts, :request, &Req.request/1)

    request_opts = [
      method: :get,
      url: url,
      headers: [
        {"user-agent", @user_agent},
        {"accept", "*/*"}
      ],
      into: into,
      raw: true,
      retry: false,
      receive_timeout: 60_000
    ]

    case request.(request_opts) do
      {:ok, %{status: status, headers: headers}} when status in 200..299 ->
        {:ok,
         %{
           path: path,
           temporary?: true,
           content_type: first_header(headers, "content-type")
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, "download returned HTTP #{status}: #{short_body(body)}"}

      {:error, error} ->
        {:error, "download failed: #{Exception.message(error)}"}
    end
  end

  defp content_length(%{headers: headers}) do
    case first_header(headers, "content-length") do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {number, ""} -> number
          _ -> nil
        end
    end
  end

  defp first_header(headers, name) when is_map(headers),
    do: headers |> Map.get(name, []) |> List.first()

  defp first_header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: value
    end)
  end

  defp temporary_basename(url) do
    (URI.parse(url).path || "upload.bin") |> Path.basename() |> safe_basename()
  end

  defp safe_basename(value) do
    cleaned = String.replace(value || "upload.bin", ~r/[^a-zA-Z0-9._-]/u, "_")
    if cleaned in ["", ".", ".."], do: "upload.bin", else: cleaned
  end

  defp short_body(body) when is_binary(body), do: body |> String.slice(0, 240) |> String.trim()
  defp short_body(body), do: inspect(body, limit: 10)
end
