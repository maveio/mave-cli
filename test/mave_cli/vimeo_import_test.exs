defmodule MaveCli.VimeoImportTest do
  use ExUnit.Case, async: true

  alias MaveCli.{Client, Vimeo}
  alias MaveCli.Vimeo.Import

  @moduletag :tmp_dir

  setup {Req.Test, :verify_on_exit!}

  setup %{tmp_dir: directory} do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      body = if conn.method == "POST", do: Jason.decode!(Req.Test.raw_body(conn)), else: nil
      send(owner, {:request, conn.host, conn.method, conn.request_path, body})
      respond(conn, body)
    end)

    %{
      mave:
        Client.new("mave-secret", base_url: "https://mave.test/v1/", plug: {Req.Test, __MODULE__}),
      vimeo: Vimeo.new("vimeo-secret") |> Req.merge(plug: {Req.Test, __MODULE__}),
      opts: [state_file: Path.join(directory, "import.json"), progress: false]
    }
  end

  test "imports titles and nested folders using only the existing Mave API", ctx do
    assert {:ok, result} = run(ctx, collection: "destination")
    assert result["folders"] == 3
    assert result["videos"] == 3
    assert result["failed"] == 0

    assert_receive {:request, "mave.test", "POST", "/v1/collections",
                    %{"name" => "Campaign", "collection" => "destination"}}

    assert_receive {:request, "mave.test", "POST", "/v1/collections",
                    %{"name" => "Empty", "collection" => "destination"}}

    assert_receive {:request, "mave.test", "POST", "/v1/collections",
                    %{"name" => "Edits", "collection" => "collection-Campaign"}}

    assert_receive {:request, "mave.test", "POST", "/v1/videos",
                    %{
                      "name" => "Één & twee 🎬",
                      "collection" => "collection-Edits",
                      "input_url" => "https://cdn.test/101.mp4?signature=private"
                    }}

    assert_receive {:request, "mave.test", "POST", "/v1/videos",
                    %{
                      "name" => "Overview",
                      "collection" => "collection-Campaign",
                      "input_url" => "https://cdn.test/102.mp4?signature=private"
                    }}

    assert_receive {:request, "mave.test", "POST", "/v1/videos",
                    %{
                      "name" => "Unfiled",
                      "collection" => "destination",
                      "input_url" => "https://cdn.test/103.mp4?signature=private"
                    }}

    state = File.read!(ctx.opts[:state_file])
    refute state =~ "secret"
    refute state =~ "signature"
    refute Jason.encode!(result) =~ "signature"
    assert Bitwise.band(File.stat!(ctx.opts[:state_file]).mode, 0o777) == 0o600
    assert Enum.find(result["data"], &(&1["vimeo_id"] == "101"))["folder"] == "Campaign/Edits"
  end

  test "dry-run previews nesting without changing Mave or writing state", ctx do
    assert {:ok, result} = run(ctx, dry_run: true)
    assert result["dry_run"]
    assert result["folders"] == 3
    assert result["videos"] == 3
    refute File.exists?(ctx.opts[:state_file])
    refute_receive {:request, _, "POST", _, _}
    refute_receive {:request, "api.vimeo.com", _, "/videos/101", _}
  end

  test "a selected folder imports its subtree including the selected folder", ctx do
    assert {:ok, result} = run(ctx, folder: "10", dry_run: true)
    assert result["folders"] == 2
    assert result["videos"] == 2
    refute_receive {:request, "api.vimeo.com", _, "/me/videos", _}
    refute Enum.any?(result["data"], &(&1["name"] == "Empty"))
  end

  test "resume reuses saved IDs without creating videos or collections twice", ctx do
    assert {:ok, _} = run(ctx)
    flush_requests()
    assert {:ok, result} = run(ctx, resume: true)
    assert Enum.all?(result["data"], &(&1["status"] == "existing"))
    refute_receive {:request, _, "POST", _, _}
    refute_receive {:request, "api.vimeo.com", _, "/videos/101", _}
    assert {:error, message} = run(ctx)
    assert message =~ "use --resume"
  end

  test "resume is bound to the Mave destination", ctx do
    assert {:ok, _} = run(ctx)
    assert {:error, message} = run(ctx, resume: true, collection: "different")
    assert message =~ "different Vimeo account, Mave destination or folder selection"
  end

  test "an interrupted create remains pending and is never retried blindly", ctx do
    owner = self()

    Req.Test.stub(:failing_mave, fn conn ->
      if conn.method == "POST" do
        send(owner, :create_attempt)
        state = Jason.decode!(File.read!(ctx.opts[:state_file]))
        assert state["pending"]["kind"] == "folders"
        Plug.Conn.send_resp(conn, 503, "private response")
      else
        respond(conn, nil)
      end
    end)

    mave =
      Client.new("mave-secret",
        base_url: "https://mave.test/v1/",
        plug: {Req.Test, :failing_mave}
      )

    assert {:error, message} = Import.run_with_client(mave, ctx.vimeo, ctx.opts)
    assert message =~ "did not confirm"
    refute message =~ "private response"
    assert_receive :create_attempt
    refute_receive :create_attempt
    assert {:error, message} = run(ctx, resume: true)
    assert message =~ "unknown outcome"
    refute_receive {:request, _, "POST", _, _}
  end

  test "videos without files are reported while other videos import and can be retried", ctx do
    Req.Test.stub(:missing_file, fn conn ->
      if conn.request_path == "/videos/101",
        do: Req.Test.json(conn, %{"files" => []}),
        else: respond(conn, nil)
    end)

    vimeo = Vimeo.new("vimeo-secret") |> Req.merge(plug: {Req.Test, :missing_file})
    assert {:error, {:import, result}} = Import.run_with_client(ctx.mave, vimeo, ctx.opts)
    assert result["failed"] == 1
    state = Jason.decode!(File.read!(ctx.opts[:state_file]))
    refute Map.has_key?(state["videos"], "101")
    assert Map.has_key?(state["videos"], "102")
    assert {:ok, result} = run(ctx, resume: true)
    assert result["failed"] == 0
  end

  test "rate limiting stops further video requests and preserves progress for resume", ctx do
    owner = self()

    Req.Test.stub(:limited_vimeo, fn conn ->
      send(owner, {:vimeo_request, conn.request_path})

      if conn.request_path == "/videos/102" do
        conn
        |> Plug.Conn.put_resp_header("retry-after", "900")
        |> Plug.Conn.send_resp(429, "private-body")
      else
        respond(conn, nil)
      end
    end)

    vimeo = Vimeo.new("vimeo-secret") |> Req.merge(plug: {Req.Test, :limited_vimeo})

    assert {:error, message} = Import.run_with_client(ctx.mave, vimeo, ctx.opts)
    assert message =~ "Vimeo rate limit reached"
    assert message =~ "--resume"
    refute message =~ "private-body"
    refute_receive {:vimeo_request, "/videos/103"}
    state = Jason.decode!(File.read!(ctx.opts[:state_file]))
    assert state["videos"] == %{"101" => "video-101"}
    assert state["pending"] == nil

    flush_requests()
    assert {:ok, result} = run(ctx, resume: true)
    assert result["failed"] == 0
    refute_receive {:request, "api.vimeo.com", _, "/videos/101", _}
    refute_receive {:request, _, "POST", "/v1/collections", _}
  end

  test "wait checks processing after saving the returned video ID", ctx do
    assert {:ok, result} = run(ctx, wait: true)

    assert Enum.all?(
             Enum.filter(result["data"], &(&1["type"] == "video")),
             &(&1["status"] == "playable")
           )

    assert_receive {:request, "mave.test", "GET", "/v1/videos/video-101", nil}
  end

  test "folder lists that also include children do not flatten or duplicate them", ctx do
    Req.Test.stub(:all_folders, fn conn ->
      if conn.request_path == "/me/projects" do
        Req.Test.json(
          conn,
          page([folder("11", "Edits", 0), folder("10", "Campaign", 1), folder("12", "Empty", 0)])
        )
      else
        respond(conn, nil)
      end
    end)

    vimeo = Vimeo.new("vimeo-secret") |> Req.merge(plug: {Req.Test, :all_folders})

    assert {:ok, result} =
             Import.run_with_client(ctx.mave, vimeo, Keyword.put(ctx.opts, :dry_run, true))

    assert result["folders"] == 3
    edits = Enum.find(result["data"], &(&1["vimeo_id"] == "11"))
    assert edits["folder"] == "Campaign"
    assert Enum.find(result["data"], &(&1["vimeo_id"] == "101"))["folder"] == "Campaign/Edits"
  end

  test "cycles fail during discovery before any Mave writes", ctx do
    Req.Test.stub(:cyclic_folders, fn conn ->
      if conn.request_path == "/users/42/projects/10/items" do
        Req.Test.json(
          conn,
          page([%{"type" => "folder", "folder" => folder("10", "Campaign", 1)}])
        )
      else
        respond(conn, nil)
      end
    end)

    vimeo = Vimeo.new("vimeo-secret") |> Req.merge(plug: {Req.Test, :cyclic_folders})
    assert {:error, message} = Import.run_with_client(ctx.mave, vimeo, ctx.opts)
    assert message =~ "cyclic"
    refute_receive {:request, _, "POST", _, _}
    refute File.exists?(ctx.opts[:state_file])
  end

  test "processing failure retains the ID and resumes polling without another import", ctx do
    Req.Test.stub(:processing_error, fn conn ->
      if conn.method == "GET" and String.starts_with?(conn.request_path, "/v1/videos/") do
        Plug.Conn.send_resp(conn, 500, "processing failed")
      else
        body = if conn.method == "POST", do: Jason.decode!(Req.Test.raw_body(conn)), else: nil
        respond(conn, body)
      end
    end)

    mave =
      Client.new("mave-secret",
        base_url: "https://mave.test/v1/",
        plug: {Req.Test, :processing_error}
      )

    assert {:error, {:import, result}} =
             Import.run_with_client(mave, ctx.vimeo, Keyword.put(ctx.opts, :wait, true))

    assert result["failed"] == 3
    assert map_size(Jason.decode!(File.read!(ctx.opts[:state_file]))["videos"]) == 3
    flush_requests()
    assert {:ok, result} = run(ctx, resume: true, wait: true)
    assert result["failed"] == 0
    refute_receive {:request, _, "POST", _, _}
  end

  test "invalid or missing resume state cannot start an import", ctx do
    assert {:error, message} = run(ctx, resume: true)
    assert message =~ "no import state"
    File.write!(ctx.opts[:state_file], "not json")
    assert {:error, message} = run(ctx, resume: true)
    assert message =~ "import state is invalid"
    refute_receive {:request, _, "POST", _, _}
  end

  defp run(ctx, extra \\ []),
    do: Import.run_with_client(ctx.mave, ctx.vimeo, Keyword.merge(ctx.opts, extra))

  defp respond(%{host: "mave.test"} = conn, body) do
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer mave-secret"]

    case {conn.method, conn.request_path} do
      {"GET", "/v1/videos"} ->
        Req.Test.json(conn, %{"space_id" => "space-1", "data" => []})

      {"POST", "/v1/collections"} ->
        Req.Test.json(conn, %{"id" => "collection-#{body["name"]}"})

      {"POST", "/v1/videos"} ->
        id = body["input_url"] |> URI.parse() |> Map.fetch!(:path) |> Path.basename(".mp4")
        Req.Test.json(conn, %{"id" => "video-#{id}"})

      {"GET", "/v1/videos/" <> id} ->
        Req.Test.json(conn, %{"id" => id, "renditions" => ["hls"]})
    end
  end

  defp respond(%{host: "api.vimeo.com"} = conn, _body) do
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer vimeo-secret"]
    assert_folder_query(conn)
    vimeo_json(conn, vimeo_response(conn.request_path))
  end

  defp vimeo_json(%{request_path: "/videos/" <> _id} = conn, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/vnd.vimeo.video+json;version=3.4")
    |> Plug.Conn.put_resp_header("content-encoding", "gzip")
    |> Plug.Conn.send_resp(200, :zlib.gzip(Jason.encode!(body)))
  end

  defp vimeo_json(conn, body), do: Req.Test.json(conn, body)

  # Synthetic responses follow Vimeo's project and project-item response schemas.
  # https://developer.vimeo.com/api/reference/response/project-item
  defp assert_folder_query(%{request_path: "/users/42/projects/" <> path} = conn) do
    query = URI.decode_query(conn.query_string)

    if String.ends_with?(path, "/items") do
      assert query["filter"] == "folder"
    else
      assert query["fields"] == "uri,name"
      assert query["include_subfolders"] == "false"
    end
  end

  defp assert_folder_query(_conn), do: :ok

  defp vimeo_response("/me"), do: %{"uri" => "/users/42"}

  defp vimeo_response("/me/projects"),
    do: page([folder("10", "Campaign", 1), folder("12", "Empty", 0)])

  defp vimeo_response("/me/projects/10"), do: folder("10", "Campaign", 1)

  defp vimeo_response("/users/42/projects/10/items"),
    do: page([%{"type" => "folder", "folder" => folder("11", "Edits", 0)}])

  defp vimeo_response("/users/42/projects/10/videos"), do: page([video("102", "Overview")])

  defp vimeo_response("/users/42/projects/11/videos"),
    do: page([video("101", "Één & twee 🎬")])

  defp vimeo_response("/users/42/projects/12/videos"), do: page([])

  defp vimeo_response("/me/videos"),
    do:
      page([
        video("101", "Één & twee 🎬"),
        video("102", "Overview"),
        video("103", "Unfiled")
      ])

  defp vimeo_response("/videos/" <> id),
    do: %{
      "files" => [
        %{
          "type" => "video/mp4",
          "width" => 1920,
          "height" => 1080,
          "link" => "https://cdn.test/#{id}.mp4?signature=private"
        }
      ]
    }

  defp folder(id, name, children) do
    %{
      "uri" => "/users/42/projects/#{id}",
      "name" => name,
      "metadata" => %{
        "connections" => %{
          "folders" => %{"total" => children, "uri" => "/users/42/projects/#{id}/items"}
        }
      }
    }
  end

  defp video(id, name) do
    %{
      "uri" => "/videos/#{id}",
      "name" => name
    }
  end

  defp page(items), do: %{"data" => items, "paging" => %{"next" => nil}}

  defp flush_requests do
    receive do
      {:request, _, _, _, _} -> flush_requests()
    after
      0 -> :ok
    end
  end
end
