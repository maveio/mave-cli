defmodule MaveCli.WebhookTest do
  use ExUnit.Case, async: true

  alias MaveCli.Webhook

  test "verifies the documented timestamp-and-secret HMAC" do
    payload = ~s({"type":"video.ready"})
    timestamp = "1785443715"
    secret = "webhook-secret"

    signature =
      :crypto.mac(:hmac, :sha256, timestamp <> "." <> secret, payload)
      |> Base.encode16(case: :lower)

    assert {:ok, true, ^timestamp} =
             Webhook.verify(payload, "t=#{timestamp}, v1=#{signature}", secret)

    assert {:ok, false, ^timestamp} =
             Webhook.verify(payload <> "!", "t=#{timestamp}, v1=#{signature}", secret)
  end

  test "accepts rotated signatures and rejects malformed headers" do
    payload = "body"
    timestamp = "100"
    secret = "secret"

    valid =
      :crypto.mac(:hmac, :sha256, timestamp <> "." <> secret, payload)
      |> Base.encode16(case: :lower)

    assert {:ok, true, "100"} =
             Webhook.verify(payload, "t=100,v1=invalid,v1=#{valid}", secret)

    assert {:error, _message} = Webhook.verify(payload, "v1=#{valid}", secret)
  end
end
