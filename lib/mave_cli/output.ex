defmodule MaveCli.Output do
  @moduledoc false

  @video_columns ["id", "name", "duration", "size", "renditions"]
  @collection_columns ["id", "name", "video_count", "created"]
  @space_columns ["id", "domain", "created", "key"]

  def print(data, "json") do
    IO.puts(Jason.encode!(data, pretty: true))
    :ok
  end

  def print(%{"data" => rows}, "table") when is_list(rows) do
    columns = columns_for(rows)
    IO.puts(table(rows, columns))
    :ok
  end

  def print(row, "table") when is_map(row) do
    columns = columns_for([row])
    IO.puts(table([row], columns))
    :ok
  end

  def print(_data, format),
    do: {:error, "unknown output format: #{format} (use json or table)"}

  defp columns_for([%{"object" => "collection"} | _]), do: @collection_columns
  defp columns_for([%{"object" => "space"} | _]), do: @space_columns
  defp columns_for([row]) when is_map(row), do: row |> Map.keys() |> Enum.sort()
  defp columns_for(_), do: @video_columns

  defp table([], _columns), do: "No results."

  defp table(rows, columns) do
    values = Enum.map(rows, fn row -> Enum.map(columns, &format_value(Map.get(row, &1))) end)

    widths =
      columns
      |> Enum.with_index()
      |> Enum.map(fn {heading, index} ->
        Enum.reduce(values, String.length(heading), fn row, width ->
          max(width, row |> Enum.at(index) |> String.length())
        end)
      end)

    separator = Enum.map_join(widths, "-+-", &String.duplicate("-", &1))
    header = render_row(Enum.map(columns, &String.upcase/1), widths)
    body = Enum.map_join(values, "\n", &render_row(&1, widths))
    Enum.join([header, separator, body], "\n")
  end

  defp render_row(values, widths) do
    values
    |> Enum.zip(widths)
    |> Enum.map_join(" | ", fn {value, width} -> String.pad_trailing(value, width) end)
  end

  defp format_value(nil), do: "-"
  defp format_value(value) when is_list(value), do: Enum.join(value, ",")
  defp format_value(value) when is_map(value), do: Jason.encode!(value)
  defp format_value(value), do: to_string(value)
end
