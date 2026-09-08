defmodule MaveCli.UploadChannelTest do
  use ExUnit.Case, async: true

  alias MaveCli.UploadChannel

  test "joins from handle_info after WebSockex has accepted handle_connect" do
    state = state()

    assert {:ok, ^state} = UploadChannel.handle_connect(nil, state)
    assert_receive :join

    assert {:reply, {:text, frame}, %{ref: 2}} = UploadChannel.handle_info(:join, state)

    assert ["1", "1", "embed:jwt", "phx_join", %{}] = Jason.decode!(frame)
  end

  test "forwards Mave upload and rendition events" do
    state = %{state() | ref: 2}

    initiate = Jason.encode!(["1", nil, "embed:jwt", "initiate", %{"upload_id" => "up-1"}])
    rendition = Jason.encode!([nil, nil, "embed:jwt", "rendition", %{"container" => "hls"}])

    assert {:ok, ^state} = UploadChannel.handle_frame({:text, initiate}, state)
    assert_receive {:mave_upload, :initiate, %{"upload_id" => "up-1"}}

    assert {:ok, ^state} = UploadChannel.handle_frame({:text, rendition}, state)
    assert_receive {:mave_upload, :rendition, %{"container" => "hls"}}
  end

  defp state do
    %{
      token: "jwt",
      topic: "embed:jwt",
      owner: self(),
      ref: 1,
      closing?: false
    }
  end
end
