defmodule MaveCli.InputTest do
  use ExUnit.Case, async: true

  alias MaveCli.Input

  test "accepts a positional HTTP or HTTPS URL" do
    assert Input.resolve_url("https://example.com/video.mp4", nil, required: true) ==
             {:ok, "https://example.com/video.mp4"}

    assert Input.resolve_url("http://example.com/video.mp4", nil, required: true) ==
             {:ok, "http://example.com/video.mp4"}
  end

  test "keeps --input-url compatibility" do
    assert Input.resolve_url(nil, "https://example.com/video.mp4") ==
             {:ok, "https://example.com/video.mp4"}
  end

  test "rejects missing, relative, and conflicting URLs" do
    assert {:error, _} = Input.resolve_url(nil, nil, required: true)
    assert {:error, _} = Input.resolve_url("video.mp4", nil, required: true)

    assert {:error, _} =
             Input.resolve_url(
               "https://one.example/video.mp4",
               "https://two.example/video.mp4"
             )
  end
end
