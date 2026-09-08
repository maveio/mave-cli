defmodule MaveCli.TransferProgress do
  @moduledoc false

  alias MaveCli.Progress

  @bar_width 24

  def status(message) do
    clear_terminal_line()
    IO.puts(:stderr, message)
  end

  def transfer(stage, current, total, opts \\ []) do
    if Keyword.get(opts, :progress, true) do
      percent = percentage(current, total)

      if Progress.terminal?() or report_non_terminal?(stage, percent) do
        line =
          "#{label(stage)} #{bar(percent)} #{percent_text(percent)}  #{sizes(current, total)}"

        write_line(line, finished?(current, total))
      end
    end
  end

  def processing(message, opts \\ []) do
    if Keyword.get(opts, :progress, true), do: status("⠹ Processing: #{message}")
  end

  def ready(message \\ "video is playable", opts \\ []) do
    if Keyword.get(opts, :progress, true), do: status("✓ #{message}")
  end

  defp percentage(_current, total) when not is_integer(total) or total <= 0, do: nil
  defp percentage(current, total), do: min(100, round(current / total * 100))

  defp finished?(current, total) when is_integer(current) and is_integer(total),
    do: total > 0 and current >= total

  defp finished?(_current, _total), do: false

  defp report_non_terminal?(stage, percent) do
    key = {__MODULE__, stage}
    previous = Process.get(key)
    report? = is_nil(previous) or is_nil(percent) or percent >= 100 or percent - previous >= 5
    if report?, do: Process.put(key, percent)
    report?
  end

  defp label(:download), do: "↓ Download"
  defp label(:upload), do: "↑ Upload  "

  defp bar(nil), do: "[#{String.duplicate("░", @bar_width)}]"

  defp bar(percent) do
    filled = div(@bar_width * percent, 100)
    "[#{String.duplicate("█", filled)}#{String.duplicate("░", @bar_width - filled)}]"
  end

  defp percent_text(nil), do: "  ?%"

  defp percent_text(percent),
    do: percent |> Integer.to_string() |> String.pad_leading(3) |> Kernel.<>("%")

  defp sizes(current, nil), do: human_bytes(current)
  defp sizes(current, total), do: "#{human_bytes(current)} / #{human_bytes(total)}"

  defp human_bytes(bytes) when bytes >= 1_073_741_824,
    do: :erlang.float_to_binary(bytes / 1_073_741_824, decimals: 1) <> " GiB"

  defp human_bytes(bytes) when bytes >= 1_048_576,
    do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1) <> " MiB"

  defp human_bytes(bytes) when bytes >= 1_024,
    do: :erlang.float_to_binary(bytes / 1_024, decimals: 1) <> " KiB"

  defp human_bytes(bytes), do: "#{bytes} B"

  defp write_line(line, finished?) do
    if Progress.terminal?() do
      IO.write(:stderr, "\r\e[2K#{line}#{if(finished?, do: "\n", else: "")}")
    else
      IO.puts(:stderr, line)
    end
  end

  defp clear_terminal_line do
    if Progress.terminal?(), do: IO.write(:stderr, "\r\e[2K")
  end
end
