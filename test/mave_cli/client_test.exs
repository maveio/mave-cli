defmodule MaveCli.ClientTest do
  use ExUnit.Case, async: true

  alias MaveCli.Client

  setup {Req.Test, :verify_on_exit!}

  test "sends bearer auth and list query parameters" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/videos"
      assert URI.decode_query(conn.query_string) == %{"page" => "2", "per_page" => "50"}
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret"]

      Req.Test.json(conn, %{"data" => [], "object" => "list"})
    end)

    assert {:ok, %{"data" => []}} =
             client()
             |> Client.list_videos(page: 2, per_page: 50)
  end

  test "encodes video updates as JSON" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/v1/videos/video-1"
      assert Jason.decode!(Req.Test.raw_body(conn)) == %{"name" => "Demo"}

      Req.Test.json(conn, %{"id" => "video-1", "name" => "Demo"})
    end)

    assert {:ok, %{"name" => "Demo"}} =
             Client.update_video(client(), "video-1", %{"name" => "Demo"})
  end

  test "supports Basic authentication with the encoded API token" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Basic encoded-key-and-secret"]
      Req.Test.json(conn, %{"data" => []})
    end)

    basic_client =
      Client.new("encoded-key-and-secret",
        auth: :basic,
        base_url: "http://mave.test/v1/",
        plug: {Req.Test, __MODULE__}
      )

    assert {:ok, %{"data" => []}} = Client.list_videos(basic_client, [])
  end

  test "creates spaces with their domain and return-key preference" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/spaces"

      assert Jason.decode!(Req.Test.raw_body(conn)) == %{
               "domain" => "example.com",
               "return_key" => true
             }

      Req.Test.json(conn, %{"id" => "space-1", "object" => "space"})
    end)

    assert {:ok, %{"id" => "space-1"}} =
             Client.create_space(client(), %{"domain" => "example.com", "return_key" => true})
  end

  test "returns useful API errors" do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(Plug.Conn.put_status(conn, 401), %{"message" => "invalid token"})
    end)

    assert {:error, {:api, 401, "invalid token"}} = Client.get_video(client(), "video-1")
  end

  defp client do
    Client.new("secret", base_url: "http://mave.test/v1/", plug: {Req.Test, __MODULE__})
  end
end
