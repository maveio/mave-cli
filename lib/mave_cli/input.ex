defmodule MaveCli.Input do
  @moduledoc false

  def resolve_url(positional, option, opts \\ []) do
    required? = Keyword.get(opts, :required, false)

    case {present(positional), present(option)} do
      {nil, nil} when required? ->
        {:error, "provide a URL, for example `mave videos upload https://example.com/video.mp4`"}

      {nil, nil} ->
        {:ok, nil}

      {url, nil} ->
        validate_url(url)

      {nil, url} ->
        validate_url(url)

      {url, url} ->
        validate_url(url)

      {_positional, _option} ->
        {:error, "provide the URL as a positional argument or via --input-url, not both"}
    end
  end

  def validate_url(value) when is_binary(value) do
    value = String.trim(value)

    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, value}

      _ ->
        {:error, "invalid video URL; use a complete http:// or https:// URL"}
    end
  end

  def validate_url(_value),
    do: {:error, "invalid video URL; use a complete http:// or https:// URL"}

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
