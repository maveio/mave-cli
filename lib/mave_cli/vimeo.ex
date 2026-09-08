defmodule MaveCli.Vimeo do
  @moduledoc false

  alias MaveCli.Vimeo.RateLimit

  @base_url "https://api.vimeo.com"

  def new(token) do
    Req.new(
      base_url: @base_url,
      headers: [
        {"authorization", "Bearer #{token}"},
        {"accept", "application/vnd.vimeo.*+json;version=3.4"},
        {"user-agent", "mave-cli/#{MaveCli.version()}"}
      ],
      redirect: false,
      compressed: true,
      decode_body: false,
      retry: :safe_transient,
      retry_log_level: false,
      max_retries: 3,
      receive_timeout: 30_000
    )
    |> Req.Request.prepend_response_steps(vimeo_rate_limit: &RateLimit.handle/1)
  end

  defdelegate token(), to: MaveCli.Vimeo.Auth

  def get(client, path, query \\ []) do
    with {:ok, url} <- api_url(path) do
      case Req.get(client, url: url, params: query) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          decode_response(body, status)

        {:ok, %Req.Response{status: 429} = response} ->
          {:error, RateLimit.from_response(response)}

        {:ok, %{status: status}} ->
          {:error, api_error(status)}

        {:error, _reason} ->
          {:error, "could not reach the Vimeo API"}
      end
    end
  end

  # Vimeo endpoints return different media types; decode their JSON explicitly.
  defp decode_response(body, status) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> invalid_response(status)
    end
  end

  defp decode_response(body, _status) when is_map(body), do: {:ok, body}
  defp decode_response(_body, status), do: invalid_response(status)

  defp invalid_response(status),
    do: {:error, "Vimeo returned an invalid JSON object (HTTP #{status})"}

  def all(client, path, query \\ []) do
    list_pages(client, path, Keyword.put(query, :per_page, 100), MapSet.new(), [])
  end

  def id(uri) when is_binary(uri) do
    case Regex.run(~r{^/(?:videos|(?:users/\d+|me)/projects)/(\d+)(?:/[^/]+)?$}, uri) do
      [_, id] -> {:ok, id}
      _ -> {:error, "Vimeo returned an invalid video or folder identifier"}
    end
  end

  def id(_), do: {:error, "Vimeo returned a missing video or folder identifier"}

  def source(client, video_id) do
    # Keep a required field in the response even when file access is unavailable.
    with {:ok, video} <- get(client, "/videos/#{video_id}", fields: "uri,files,download") do
      files = List.wrap(video["download"]) ++ List.wrap(video["files"])

      select_file(files)
    end
  end

  defp select_file(files) do
    case files |> Enum.filter(&video_file?/1) |> Enum.max_by(&quality/1, fn -> nil end) do
      nil -> {:error, "no accessible video file; check Vimeo's video_files scope and plan"}
      file -> {:ok, file["link"]}
    end
  end

  defp list_pages(client, path, query, visited, pages) do
    with {:ok, url} <- api_url(path),
         false <- MapSet.member?(visited, url),
         {:ok, %{"data" => data, "paging" => paging}} when is_list(data) and is_map(paging) <-
           get(client, url, query) do
      pages = [data | pages]

      case paging["next"] do
        nil -> {:ok, pages |> Enum.reverse() |> List.flatten()}
        next -> list_pages(client, next, [], MapSet.put(visited, url), pages)
      end
    else
      {:error, _} = error -> error
      _ -> {:error, "Vimeo returned invalid or repeating pagination"}
    end
  end

  # Never send the Vimeo bearer token to a pagination/connection URL on another origin.
  defp api_url(path) when is_binary(path) do
    url = URI.merge(@base_url, path)

    if url.scheme == "https" and url.host == "api.vimeo.com" and url.port == 443 and
         is_nil(url.userinfo) and is_nil(url.fragment) do
      {:ok, URI.to_string(url)}
    else
      {:error, "Vimeo returned a URL outside its API"}
    end
  end

  defp api_url(_), do: {:error, "Vimeo returned an invalid API URL"}

  defp video_file?(%{"link" => link} = file) when is_binary(link) do
    uri = URI.parse(link)
    type = file["type"] || ""

    uri.scheme in ["http", "https"] and is_binary(uri.host) and is_nil(uri.userinfo) and
      (String.starts_with?(type, "video/") or file["quality"] == "source") and
      file["quality"] != "hls" and not expired?(file["expires"])
  end

  defp video_file?(_), do: false

  defp quality(file) do
    {file["quality"] == "source", number(file["width"]) * number(file["height"]),
     number(file["size"])}
  end

  defp number(value) when is_number(value), do: value
  defp number(_), do: 0

  defp expired?(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, expires, _} -> DateTime.compare(expires, DateTime.utc_now()) != :gt
      _ -> false
    end
  end

  defp expired?(_), do: false

  defp api_error(401), do: "Vimeo rejected the access token"

  defp api_error(403),
    do: "Vimeo denied access; check the public, private and video_files token scopes"

  defp api_error(status), do: "Vimeo API returned HTTP #{status}"
end
