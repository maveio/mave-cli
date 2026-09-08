defmodule MaveCli.DownloaderTest do
  use ExUnit.Case, async: true

  alias MaveCli.Downloader

  test "streams into a private directory and removes it after cleanup" do
    name = "download-#{System.unique_integer([:positive])}.mp4"

    request = fn options ->
      response = %{status: 200, headers: %{"content-type" => ["video/mp4"]}}
      {:cont, _} = options[:into].({:data, "private video"}, {%{}, response})
      {:ok, response}
    end

    assert {:ok, source} =
             Downloader.acquire("https://example.test/#{name}", request: request, progress: false)

    assert File.read!(source.path) == "private video"
    assert Path.basename(source.path) == name

    if match?({:unix, _}, :os.type()) do
      assert Bitwise.band(File.stat!(source.path).mode, 0o777) == 0o600
      assert Bitwise.band(File.stat!(Path.dirname(source.path)).mode, 0o777) == 0o700
    end

    assert :ok = Downloader.cleanup(source)
    refute File.exists?(Path.dirname(source.path))
  end

  test "cleans partial media even when the request raises" do
    name = "failed-#{System.unique_integer([:positive])}.mp4"

    request = fn options ->
      options[:into].({:data, "partial"}, {%{}, %{headers: %{}}})
      raise "synthetic transfer failure"
    end

    assert_raise RuntimeError, "synthetic transfer failure", fn ->
      Downloader.acquire("https://example.test/#{name}", request: request, progress: false)
    end

    assert Path.wildcard(Path.join([System.tmp_dir!(), "mave-cli-*", name])) == []
  end

  test "accepts an existing local file without marking it temporary" do
    path = Path.join(System.tmp_dir!(), "mave-source-#{System.unique_integer([:positive])}.mp4")
    File.write!(path, "video")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{path: expanded, temporary?: false}} = Downloader.acquire(path)
    assert expanded == Path.expand(path)
    assert :ok = Downloader.cleanup(%{path: expanded, temporary?: false})
    assert File.exists?(path)
  end
end
