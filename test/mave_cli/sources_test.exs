defmodule MaveCli.SourcesTest do
  use ExUnit.Case, async: true

  alias MaveCli.Sources

  @moduletag :tmp_dir

  test "does not overwrite a destination created during the download", %{tmp_dir: directory} do
    destination = Path.join(directory, "video.mp4")

    assert {:error, _} =
             Sources.download("ubg50Cq5Ilpnar1", "video.mp4", destination,
               progress: false,
               request: download_request(fn -> File.write!(destination, "keep") end)
             )

    assert File.read!(destination) == "keep"
  end

  test "does not follow a symlink inserted during the download", %{tmp_dir: directory} do
    if match?({:unix, _}, :os.type()) do
      destination = Path.join(directory, "video.mp4")
      target = Path.join(directory, "unrelated.txt")
      File.write!(target, "keep")

      assert {:error, _} =
               Sources.download("ubg50Cq5Ilpnar1", "video.mp4", destination,
                 progress: false,
                 request: download_request(fn -> File.ln_s!(target, destination) end)
               )

      assert File.read!(target) == "keep"
    end
  end

  test "creates a new destination and allows explicitly requested replacement", %{
    tmp_dir: directory
  } do
    destination = Path.join(directory, "video.mp4")
    opts = [progress: false, request: download_request(fn -> :ok end)]
    assert {:ok, _} = Sources.download("ubg50Cq5Ilpnar1", "video.mp4", destination, opts)
    assert File.read!(destination) == "video"
    assert {:error, _} = Sources.download("ubg50Cq5Ilpnar1", "video.mp4", destination, opts)

    assert {:ok, _} =
             Sources.download(
               "ubg50Cq5Ilpnar1",
               "video.mp4",
               destination,
               Keyword.put(opts, :overwrite, true)
             )
  end

  defp download_request(before_copy) do
    fn options ->
      before_copy.()
      response = %{status: 200, headers: %{}}
      {:cont, _} = options[:into].({:data, "video"}, {%{}, response})
      {:ok, response}
    end
  end

  test "builds deterministic source URLs from a combined embed ID" do
    assert {:ok, url} = Sources.url("ubg50Cq5Ilpnar1", "v8/h264_fhd.mp4")

    assert url ==
             "https://space-ubg50.video-dns.com/Cq5Ilpnar1/v8/h264_fhd.mp4"

    assert {:ok, hls_url} =
             Sources.url("ubg50Cq5Ilpnar1", "/h264_fhd_hls/playlist.m3u8")

    assert hls_url ==
             "https://space-ubg50.video-dns.com/Cq5Ilpnar1/h264_fhd_hls/playlist.m3u8"
  end

  test "rejects invalid embed IDs and unsafe paths" do
    assert {:error, _message} = Sources.url("short", "manifest.json")
    assert {:error, _message} = Sources.url("ubg50Cq5Ilpnar1", "../secret")
    assert {:error, _message} = Sources.url("ubg50Cq5Ilpnar1", "https://example.com/file")
  end

  test "supports a local CDN with path-based space buckets" do
    assert {:ok, "http://localhost:9010/space-ubg50/Cq5Ilpnar1/v8/my%20video.mp4"} =
             Sources.url("ubg50Cq5Ilpnar1", "v8/my video.mp4",
               cdn_base_url: "http://localhost:9010/space-{space}/"
             )
  end

  test "fetches the public manifest" do
    request = fn options ->
      assert options[:url] ==
               "https://space-ubg50.video-dns.com/Cq5Ilpnar1/manifest.json"

      {:ok, %{status: 200, body: %{"id" => "Cq5Ilpnar1"}}}
    end

    assert {:ok, %{"id" => "Cq5Ilpnar1"}} =
             Sources.manifest("ubg50Cq5Ilpnar1", request: request)
  end
end
