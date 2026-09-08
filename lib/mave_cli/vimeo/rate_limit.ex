defmodule MaveCli.Vimeo.RateLimit do
  @moduledoc false

  defexception [:seconds, :retry_at, :reset_known?]

  @fallback_seconds 60
  @max_wait_seconds 300

  def handle({request, %Req.Response{status: 429} = response}) do
    limit = from_response(response)
    retries = Req.Request.get_private(request, :req_retry_count, 0)
    max_retries = Req.Request.get_option(request, :max_retries, 3)

    if request.options[:retry] != false and retries < max_retries and
         limit.seconds <= @max_wait_seconds do
      IO.puts(:stderr, waiting_message(limit, retries + 1, max_retries))
      {request, Req.Response.put_header(response, "retry-after", to_string(limit.seconds))}
    else
      Req.Request.halt(request, response)
    end
  end

  def handle(request_response), do: request_response

  def from_response(response, now \\ DateTime.utc_now()) do
    server_now = datetime(header(response, "date")) || now

    seconds =
      [
        retry_after(header(response, "retry-after"), server_now),
        reset_after(header(response, "x-ratelimit-reset"), server_now)
      ]
      |> Enum.filter(&is_integer/1)
      |> Enum.max(fn -> nil end)

    wait = seconds || @fallback_seconds
    %__MODULE__{seconds: wait, retry_at: DateTime.add(now, wait), reset_known?: seconds != nil}
  end

  @impl true
  def message(%{reset_known?: true} = limit) do
    "Vimeo rate limit reached (HTTP 429); try again after #{timestamp(limit.retry_at)} " <>
      "(in about #{limit.seconds} seconds)"
  end

  def message(_limit) do
    "Vimeo rate limit reached (HTTP 429); no usable reset time was supplied. " <>
      "Wait at least #{@fallback_seconds} seconds before trying again"
  end

  defp waiting_message(limit, attempt, max_retries) do
    until = if limit.reset_known?, do: " until #{timestamp(limit.retry_at)}", else: ""

    "Vimeo rate limit reached; waiting #{limit.seconds}s#{until}, " <>
      "then retrying (#{attempt}/#{max_retries})."
  end

  defp timestamp(time), do: Calendar.strftime(time, "%Y-%m-%d %H:%M:%S UTC")

  defp header(response, name), do: List.first(Req.Response.get_header(response, name))

  defp retry_after(value, now) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds >= 0 -> max(seconds, 1)
      _ -> seconds_until(datetime(value), now)
    end
  end

  defp retry_after(_value, _now), do: nil

  defp reset_after(value, now) when is_binary(value) do
    time =
      case Integer.parse(String.trim(value)) do
        {seconds, ""} ->
          case DateTime.from_unix(seconds) do
            {:ok, time} -> time
            _ -> nil
          end

        _ ->
          datetime(value)
      end

    seconds_until(time, now)
  end

  defp reset_after(_value, _now), do: nil

  defp seconds_until(nil, _now), do: nil

  defp seconds_until(time, now) do
    case DateTime.diff(time, now, :millisecond) do
      milliseconds when milliseconds >= 0 -> div(milliseconds, 1000) + 1
      _ -> nil
    end
  end

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> time
      _ -> http_datetime(value)
    end
  end

  defp datetime(_value), do: nil

  defp http_datetime(value) do
    case Req.Utils.parse_http_date(value) do
      {:ok, time} -> time
      _ -> nil
    end
  end
end
