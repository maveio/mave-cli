defmodule MaveCli.Tus do
  @moduledoc false

  alias MaveCli.TransferProgress

  @version "1.0.0"
  @default_endpoint "https://upload.mave.io/files"
  @default_chunk_size 5 * 1_024 * 1_024

  # send_file is our local TUS upload helper, not Phoenix send_file; only the selected input is read.
  # sobelow_skip ["Traversal.SendFile"]
  def upload(path, token, upload_id, opts \\ []) do
    with {:ok, stat} <- File.stat(path),
         {:ok, upload_url} <- create(path, stat.size, token, upload_id, opts),
         :ok <- send_file(path, stat.size, upload_url, opts) do
      {:ok, %{url: upload_url, bytes: stat.size}}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "could not read file: #{:file.format_error(reason)}"}

      {:error, _reason} = error ->
        error
    end
  end

  def metadata(values) do
    Enum.map_join(values, ",", fn {key, value} ->
      "#{key} #{Base.encode64(to_string(value))}"
    end)
  end

  defp create(path, size, token, upload_id, opts) do
    endpoint = Keyword.get(opts, :endpoint, @default_endpoint)
    content_type = Keyword.get(opts, :content_type) || MIME.from_path(path)

    headers = [
      {"tus-resumable", @version},
      {"upload-length", Integer.to_string(size)},
      {"upload-metadata",
       metadata(
         title: Path.basename(path),
         filetype: content_type,
         token: token,
         upload_id: upload_id
       )}
    ]

    case request(opts, method: :post, url: endpoint, headers: headers, body: "") do
      {:ok, %{status: 201, headers: response_headers}} ->
        case first_header(response_headers, "location") do
          nil -> {:error, "TUS server did not return a Location header"}
          location -> {:ok, resolve_location(endpoint, location)}
        end

      response ->
        tus_error("upload creation", response)
    end
  end

  # Reads the operator-selected media file or our private downloaded copy, not a server-supplied path.
  # sobelow_skip ["Traversal.FileModule"]
  defp send_file(path, size, upload_url, opts) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      result = upload_chunks(file, upload_url, 0, size, opts, 0)
      File.close(file)
      result
    end
  end

  defp upload_chunks(_file, _url, offset, size, _opts, _retries) when offset >= size, do: :ok

  defp upload_chunks(file, url, offset, size, opts, retries) do
    chunk_size = min(Keyword.get(opts, :chunk_size, @default_chunk_size), size - offset)
    :file.position(file, offset)

    case IO.binread(file, chunk_size) do
      data when is_binary(data) ->
        patch_chunk(file, data, url, offset, size, opts, retries)

      :eof ->
        {:error, "file ended unexpectedly at byte #{offset} of #{size}"}

      {:error, reason} ->
        {:error, "could not read file: #{:file.format_error(reason)}"}
    end
  end

  defp patch_chunk(file, data, url, offset, size, opts, retries) do
    headers = [
      {"tus-resumable", @version},
      {"upload-offset", Integer.to_string(offset)},
      {"content-type", "application/offset+octet-stream"}
    ]

    case request(opts, method: :patch, url: url, headers: headers, body: data) do
      {:ok, %{status: status, headers: response_headers}} when status in [200, 204] ->
        next_offset = parse_offset(response_headers) || offset + byte_size(data)
        TransferProgress.transfer(:upload, next_offset, size, progress: progress?(opts))
        upload_chunks(file, url, next_offset, size, opts, 0)

      response when retries < 5 ->
        resume_after_error(file, url, size, opts, retries, response)

      response ->
        tus_error("upload", response)
    end
  end

  defp resume_after_error(file, url, size, opts, retries, original_response) do
    Process.sleep(min(1_000 * round(:math.pow(2, retries)), 8_000))

    case current_offset(url, opts) do
      {:ok, offset} ->
        TransferProgress.transfer(:upload, offset, size, progress: progress?(opts))
        upload_chunks(file, url, offset, size, opts, retries + 1)

      {:error, _reason} when retries < 4 ->
        resume_after_error(file, url, size, opts, retries + 1, original_response)

      {:error, _reason} ->
        tus_error("upload resume", original_response)
    end
  end

  defp current_offset(url, opts) do
    headers = [{"tus-resumable", @version}]

    case request(opts, method: :head, url: url, headers: headers) do
      {:ok, %{status: status, headers: response_headers}} when status in [200, 204] ->
        case parse_offset(response_headers) do
          nil -> {:error, "TUS server did not return an Upload-Offset header"}
          offset -> {:ok, offset}
        end

      response ->
        tus_error("offset retrieval", response)
    end
  end

  defp request(opts, request_opts) do
    request = Keyword.get(opts, :request, &Req.request/1)

    defaults = [
      raw: true,
      retry: false,
      receive_timeout: 120_000,
      headers: [{"user-agent", "mave-cli/#{MaveCli.version()}"}]
    ]

    request.(
      Keyword.merge(defaults, request_opts, fn
        :headers, left, right -> left ++ right
        _key, _left, right -> right
      end)
    )
  end

  defp tus_error(action, {:ok, %{status: status, body: body}}),
    do: {:error, "TUS #{action} returned HTTP #{status}: #{short_body(body)}"}

  defp tus_error(action, {:error, exception}),
    do: {:error, "TUS #{action} failed: #{Exception.message(exception)}"}

  defp tus_error(action, other), do: {:error, "TUS #{action} failed: #{inspect(other)}"}

  defp parse_offset(headers) do
    case first_header(headers, "upload-offset") do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {offset, ""} -> offset
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

  defp resolve_location(endpoint, location) do
    case URI.parse(location) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> location
      _ -> endpoint |> ensure_directory_url() |> URI.merge(location) |> to_string()
    end
  end

  defp ensure_directory_url(url), do: String.trim_trailing(url, "/") <> "/"
  defp progress?(opts), do: Keyword.get(opts, :progress, true)
  defp short_body(body) when is_binary(body), do: body |> String.slice(0, 240) |> String.trim()
  defp short_body(body), do: inspect(body, limit: 10)
end
