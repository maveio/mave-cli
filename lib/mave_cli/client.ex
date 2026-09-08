defmodule MaveCli.Client do
  @moduledoc false

  defstruct [:request, :upload_key]

  def new(token, opts \\ []) do
    base_url = Keyword.get(opts, :base_url) || Application.fetch_env!(:mave_cli, :api_base_url)
    auth_scheme = if Keyword.get(opts, :auth, :bearer) == :basic, do: "Basic", else: "Bearer"

    req_options =
      [
        base_url: ensure_trailing_slash(base_url),
        headers: [
          {"authorization", "#{auth_scheme} #{token}"},
          {"accept", "application/json"},
          {"user-agent", "mave-cli/#{MaveCli.version()}"}
        ],
        receive_timeout: 30_000,
        retry: :transient,
        max_retries: 2
      ]
      |> maybe_put_plug(Keyword.get(opts, :plug))

    req = Req.new(req_options)

    %__MODULE__{request: req, upload_key: token}
  end

  def upload_key(%__MODULE__{upload_key: token}), do: token

  def base_url(client), do: Req.Request.get_option(client.request, :base_url)

  def without_retries(client),
    do: %{client | request: Req.merge(client.request, retry: false)}

  def list_videos(client, query), do: request(client, :get, "videos", query: query)
  def get_video(client, id), do: request(client, :get, "videos/#{segment(id)}")
  def create_video(client, body), do: request(client, :post, "videos", body: body)

  def update_video(client, id, body),
    do: request(client, :put, "videos/#{segment(id)}", body: body)

  def delete_video(client, id), do: request(client, :delete, "videos/#{segment(id)}")

  def list_collections(client, query), do: request(client, :get, "collections", query: query)
  def create_collection(client, body), do: request(client, :post, "collections", body: body)

  def update_collection(client, id, body),
    do: request(client, :put, "collections/#{segment(id)}", body: body)

  def delete_collection(client, id), do: request(client, :delete, "collections/#{segment(id)}")

  def create_space(client, body), do: request(client, :post, "spaces", body: body)

  defp request(client, method, path, opts \\ []) do
    request_opts =
      [method: method, url: path, params: Keyword.get(opts, :query, [])]
      |> maybe_put_json(Keyword.get(opts, :body))

    case Req.request(client.request, request_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, normalize_body(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api, status, error_message(body)}}

      {:error, exception} ->
        {:error, {:transport, Exception.message(exception)}}
    end
  end

  defp maybe_put_json(opts, nil), do: opts
  defp maybe_put_json(opts, body), do: Keyword.put(opts, :json, body)
  defp maybe_put_plug(opts, nil), do: opts
  defp maybe_put_plug(opts, plug), do: Keyword.put(opts, :plug, plug)

  defp normalize_body(""), do: %{}
  defp normalize_body(nil), do: %{}
  defp normalize_body(body), do: body

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(body) when is_binary(body), do: body
  defp error_message(body), do: Jason.encode!(body)

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp ensure_trailing_slash(url), do: String.trim_trailing(url, "/") <> "/"
end
