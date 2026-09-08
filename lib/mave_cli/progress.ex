defmodule MaveCli.Progress do
  @moduledoc false

  alias MaveCli.Client

  @bar_width 24
  @spinner ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  def wait_for_video(client, id, opts \\ []) do
    fetcher = fn -> Client.get_video(client, id) end
    wait(fetcher, opts)
  end

  def wait(fetcher, opts \\ []) when is_function(fetcher, 0) do
    timeout_seconds = Keyword.get(opts, :timeout, 600)

    if is_integer(timeout_seconds) and timeout_seconds > 0 do
      started_at = now_ms(opts)
      renderer = renderer(opts)
      initial = Keyword.get(opts, :initial)

      case initial do
        nil -> poll(fetcher, opts, renderer, started_at, 0)
        video -> handle_video(video, fetcher, opts, renderer, started_at, 0)
      end
    else
      {:error, "--timeout must be a positive integer"}
    end
  end

  def terminal? do
    System.get_env("_IS_TTY") == "1" or match?({:ok, _}, :io.columns())
  end

  def state(%{"renditions" => [_ | _]}), do: :ready
  def state(%{"last_upload" => uploaded}) when not is_nil(uploaded), do: :processing
  def state(_video), do: :uploading

  defp poll(fetcher, opts, renderer, started_at, tick) do
    if timed_out?(started_at, opts) do
      renderer.(:timeout, nil, tick)
      {:error, "video was not playable within #{Keyword.get(opts, :timeout, 600)} seconds"}
    else
      case fetcher.() do
        {:ok, video} ->
          handle_video(video, fetcher, opts, renderer, started_at, tick)

        {:error, reason} ->
          renderer.(:error, nil, tick)
          {:error, reason}
      end
    end
  end

  defp handle_video(video, fetcher, opts, renderer, started_at, tick) do
    current_state = state(video)
    renderer.(current_state, video, tick)

    if current_state == :ready do
      {:ok, video}
    else
      sleep(opts)
      poll(fetcher, opts, renderer, started_at, tick + 1)
    end
  end

  defp renderer(opts) do
    cond do
      Keyword.has_key?(opts, :renderer) -> Keyword.fetch!(opts, :renderer)
      Keyword.get(opts, :progress, true) -> &render/3
      true -> fn _, _, _ -> :ok end
    end
  end

  defp render(state, video, tick) do
    line = progress_line(state, video, tick)

    if terminal?() do
      suffix = if state in [:ready, :timeout, :error], do: "\n", else: ""
      IO.write(:stderr, "\r\e[2K#{line}#{suffix}")
    else
      IO.puts(:stderr, line)
    end
  end

  defp progress_line(:uploading, _video, tick),
    do: "#{spinner(tick)} #{bar(1)} 1/3  Mave is fetching the file…"

  defp progress_line(:processing, video, tick) do
    renditions = rendition_text(video)
    "#{spinner(tick)} #{bar(2)} 2/3  Processing video#{renditions}…"
  end

  defp progress_line(:ready, video, _tick) do
    renditions = rendition_text(video)
    "✓ #{bar(3)} 3/3  Video is playable#{renditions}"
  end

  defp progress_line(:timeout, _video, _tick), do: "! #{bar(2)} Processing timed out"
  defp progress_line(:error, _video, _tick), do: "✗ #{bar(1)} Could not retrieve progress"

  defp bar(stage) do
    filled = div(@bar_width * stage, 3)
    "[#{String.duplicate("█", filled)}#{String.duplicate("░", @bar_width - filled)}]"
  end

  defp spinner(tick), do: Enum.at(@spinner, rem(tick, length(@spinner)))

  defp rendition_text(%{"renditions" => renditions})
       when is_list(renditions) and renditions != [],
       do: " (#{Enum.join(renditions, ", ")})"

  defp rendition_text(_video), do: ""

  defp sleep(opts) do
    sleeper = Keyword.get(opts, :sleep, &Process.sleep/1)
    sleeper.(Keyword.get(opts, :poll_interval, 2_000))
  end

  defp timed_out?(started_at, opts) do
    now_ms(opts) - started_at >= Keyword.get(opts, :timeout, 600) * 1_000
  end

  defp now_ms(opts) do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    clock.()
  end
end
