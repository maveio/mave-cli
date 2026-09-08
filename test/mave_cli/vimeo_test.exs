defmodule MaveCli.VimeoTest do
  use ExUnit.Case, async: true

  alias MaveCli.Vimeo

  setup {Req.Test, :verify_on_exit!}

  test "paginates Vimeo responses with isolated credentials" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "api.vimeo.com"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer vimeo-secret"]
      assert URI.decode_query(conn.query_string)["per_page"] == "100"

      Req.Test.json(conn, %{
        "data" => [%{"uri" => "/videos/1"}],
        "paging" => %{"next" => "/me/videos?page=2&per_page=100"}
      })
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert URI.decode_query(conn.query_string)["page"] == "2"
      Req.Test.json(conn, %{"data" => [%{"uri" => "/videos/2"}], "paging" => %{"next" => nil}})
    end)

    assert {:ok, [%{"uri" => "/videos/1"}, %{"uri" => "/videos/2"}]} =
             Vimeo.all(client(), "/me/videos")
  end

  test "rejects cross-origin pagination and does not follow HTTP redirects" do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"data" => [], "paging" => %{"next" => "https://other.test/token"}})
    end)

    assert {:error, "Vimeo returned a URL outside its API"} = Vimeo.all(client(), "/me/videos")

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://other.test/token")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, "Vimeo API returned HTTP 302"} = Vimeo.get(client(), "/me")
  end

  test "detects repeating pages rather than looping forever" do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"data" => [], "paging" => %{"next" => "/me/videos"}})
    end)

    assert {:error, "Vimeo returned invalid or repeating pagination"} =
             Vimeo.all(client(), "/me/videos")
  end

  test "selects a source video ahead of renditions and ignores expired and HLS links" do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "download" => [
          file("old-original", %{"quality" => "source", "expires" => "2000-01-01T00:00:00Z"}),
          file("original", %{"quality" => "source"}),
          file("4k", %{"width" => 3840, "height" => 2160})
        ],
        "files" => [
          %{
            "link" => "https://cdn.test/video.m3u8",
            "type" => "application/x-mpegURL",
            "quality" => "hls"
          }
        ]
      })
    end)

    assert {:ok, "https://cdn.test/original.mp4"} = Vimeo.source(client(), "1")
  end

  test "falls back to the best MP4 in files when downloads are unavailable" do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "files" => [file("sd", %{"height" => 360}), file("hd", %{"height" => 1080})]
      })
    end)

    assert {:ok, "https://cdn.test/hd.mp4"} = Vimeo.source(client(), "1")
  end

  test "reads compressed video responses with Vimeo's vendor JSON content type" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert URI.decode_query(conn.query_string)["fields"] == "uri,files,download"
      body = Jason.encode!(%{"files" => [file("original", %{"quality" => "source"})]})

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/vnd.vimeo.video+json;version=3.4")
      |> Plug.Conn.put_resp_header("content-encoding", "gzip")
      |> Plug.Conn.send_resp(200, :zlib.gzip(body))
    end)

    assert {:ok, "https://cdn.test/original.mp4"} = Vimeo.source(client(), "1")
  end

  test "reads JSON objects even when the response is not labelled as JSON" do
    for content_type <- [nil, "text/plain", "application/octet-stream"] do
      Req.Test.expect(__MODULE__, fn conn ->
        conn =
          if content_type,
            do: Plug.Conn.put_resp_header(conn, "content-type", content_type),
            else: conn

        Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"files" => [file("hd", %{})]}))
      end)

      assert {:ok, "https://cdn.test/hd.mp4"} = Vimeo.source(client(), "1")
    end
  end

  test "reports invalid successful responses without exposing their contents" do
    for body <- ["", "<html>private-response</html>", "{invalid", "[]", "null", "42"] do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(200, body)
      end)

      assert {:error, "Vimeo returned an invalid JSON object (HTTP 200)"} =
               Vimeo.get(client(), "/videos/1")
    end
  end

  test "reports inaccessible videos without exposing responses or tokens" do
    for fields <- [%{}, %{"files" => [], "download" => []}, %{"files" => nil, "download" => nil}] do
      Req.Test.expect(__MODULE__, fn conn ->
        assert "uri" in String.split(URI.decode_query(conn.query_string)["fields"], ",")
        Req.Test.json(conn, Map.put(fields, "uri", "/videos/1"))
      end)

      assert {:error, message} = Vimeo.source(client(), "1")
      assert message =~ "no accessible video file"
    end

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(Plug.Conn.put_status(conn, 403), %{"error" => "secret: vimeo-secret"})
    end)

    assert {:error, message} = Vimeo.get(client(), "/me")
    refute message =~ "vimeo-secret"
  end

  test "retries rate-limited read requests" do
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 429, "") end)
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, %{"uri" => "/users/1"}) end)

    request = Req.merge(client(), retry_delay: fn _ -> 0 end, retry_log_level: false)

    message =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:ok, %{"uri" => "/users/1"}} = Vimeo.get(request, "/me")
      end)

    assert message =~ "waiting 60s"
  end

  defp file(name, attrs) do
    Map.merge(
      %{"link" => "https://cdn.test/#{name}.mp4", "type" => "video/mp4", "width" => 1920},
      attrs
    )
  end

  defp client, do: Vimeo.new("vimeo-secret") |> Req.merge(plug: {Req.Test, __MODULE__})
end
