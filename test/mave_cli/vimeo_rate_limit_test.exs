defmodule MaveCli.VimeoRateLimitTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias MaveCli.Vimeo
  alias MaveCli.Vimeo.RateLimit

  @now ~U[2026-09-08 15:00:00Z]
  setup {Req.Test, :verify_on_exit!}

  test "reads Vimeo reset timestamps and accounts for server clock differences" do
    for reset <- [
          "2026-09-08T15:01:30Z",
          "Tue, 08 Sep 2026 15:01:30 GMT",
          to_string(DateTime.to_unix(DateTime.add(@now, 90)))
        ] do
      response =
        response([{"x-ratelimit-reset", reset}, {"date", "Tue, 08 Sep 2026 15:00:00 GMT"}])

      limit = RateLimit.from_response(response, DateTime.add(@now, -120))
      assert limit.seconds == 91
      assert limit.reset_known?
      assert limit.retry_at == ~U[2026-09-08 14:59:31Z]
      assert RateLimit.message(limit) =~ "2026-09-08 14:59:31 UTC"
    end
  end

  test "honors Retry-After seconds and dates, using the later of both reset headers" do
    assert RateLimit.from_response(response([{"retry-after", "120"}]), @now).seconds == 120

    assert RateLimit.from_response(
             response([{"retry-after", "Tue, 08 Sep 2026 15:02:00 GMT"}]),
             @now
           ).seconds == 121

    limit =
      RateLimit.from_response(
        response([{"retry-after", "5"}, {"x-ratelimit-reset", "2026-09-08T15:03:00Z"}]),
        @now
      )

    assert limit.seconds == 181
  end

  test "missing, malformed and stale reset headers use a minute without exposing header contents" do
    for headers <- [
          [],
          [{"retry-after", "invalid-private-header"}],
          [{"retry-after", "-1"}],
          [{"retry-after", "1.5"}],
          [{"x-ratelimit-reset", "invalid-private-header"}],
          [{"x-ratelimit-reset", "2020-01-01T00:00:00Z"}]
        ] do
      limit = RateLimit.from_response(response(headers), @now)
      assert limit.seconds == 60
      refute limit.reset_known?
      assert RateLimit.message(limit) =~ "Wait at least 60 seconds"
      refute RateLimit.message(limit) =~ "private"
    end
  end

  test "the response step supplies a conservative Retry-After before Req retries" do
    message =
      capture_io(:stderr, fn ->
        {request, response} = RateLimit.handle({Vimeo.new("test-secret"), response([])})
        refute request.halted
        assert Req.Response.get_header(response, "retry-after") == ["60"]
      end)

    assert message =~ "waiting 60s"
    assert message =~ "(1/3)"
  end

  test "long waits and exhausted or disabled retries halt without a misleading wait message" do
    request = Vimeo.new("test-secret")
    exhausted = Req.Request.put_private(request, :req_retry_count, 3)

    for {request, response} <- [
          {request, response([{"retry-after", "900"}])},
          {exhausted, response([])},
          {Req.merge(request, retry: false), response([])}
        ] do
      assert capture_io(:stderr, fn ->
               {request, _response} = RateLimit.handle({request, response})
               assert request.halted
             end) == ""
    end
  end

  test "a real retry waits for the declared cooldown and keeps stdout clean" do
    started = System.monotonic_time(:millisecond)

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "1")
      |> Plug.Conn.send_resp(429, "private-body")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert System.monotonic_time(:millisecond) - started >= 1000
      Req.Test.json(conn, %{"uri" => "/users/42"})
    end)

    message =
      capture_io(:stderr, fn ->
        assert capture_io(fn ->
                 assert {:ok, %{"uri" => "/users/42"}} = Vimeo.get(client(), "/me")
               end) == ""
      end)

    assert message =~ "waiting 1s"
    refute message =~ "private-body"
  end

  test "persistent rate limiting stops after the retry budget" do
    for _ <- 1..4 do
      Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 429, "private-body") end)
    end

    message =
      capture_io(:stderr, fn ->
        assert {:error, %RateLimit{seconds: 60}} =
                 Vimeo.get(Req.merge(client(), retry_delay: fn _ -> 0 end), "/me")
      end)

    assert length(Regex.scan(~r/waiting 60s/, message)) == 3
    refute message =~ "private-body"
  end

  defp response(headers),
    do: Req.Response.new(status: 429, headers: headers, body: "private-body")

  defp client, do: Vimeo.new("test-secret") |> Req.merge(plug: {Req.Test, __MODULE__})
end
