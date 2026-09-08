defmodule MaveCli.ProgressTest do
  use ExUnit.Case, async: true

  alias MaveCli.Progress

  test "reports upload phases and returns the ready video" do
    Process.put(:responses, [
      %{"id" => "video-1", "last_upload" => nil, "renditions" => []},
      %{"id" => "video-1", "last_upload" => 123, "renditions" => []},
      %{"id" => "video-1", "last_upload" => 123, "renditions" => ["sd"]}
    ])

    fetcher = fn ->
      [next | rest] = Process.get(:responses)
      Process.put(:responses, rest)
      {:ok, next}
    end

    renderer = fn state, _video, _tick -> send(self(), {:state, state}) end

    assert {:ok, %{"renditions" => ["sd"]}} =
             Progress.wait(fetcher,
               renderer: renderer,
               sleep: fn _ -> :ok end,
               clock: fn -> 0 end
             )

    assert_received {:state, :uploading}
    assert_received {:state, :processing}
    assert_received {:state, :ready}
  end

  test "recognizes the three API states" do
    assert Progress.state(%{"last_upload" => nil, "renditions" => []}) == :uploading
    assert Progress.state(%{"last_upload" => 123, "renditions" => []}) == :processing
    assert Progress.state(%{"last_upload" => 123, "renditions" => ["hd"]}) == :ready
  end

  test "rejects invalid timeouts" do
    assert {:error, message} = Progress.wait(fn -> flunk("should not fetch") end, timeout: 0)
    assert message =~ "positive integer"
  end
end
