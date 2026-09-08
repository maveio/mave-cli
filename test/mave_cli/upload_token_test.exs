defmodule MaveCli.UploadTokenTest do
  use ExUnit.Case, async: true

  alias MaveCli.UploadToken

  test "creates an HS256 token scoped to the video" do
    token = UploadToken.sign("video-123", "secret", now: 100, expires_in: 60)
    [header, payload, signature] = String.split(token, ".")

    assert header |> decode() |> Jason.decode!() == %{"alg" => "HS256", "typ" => "JWT"}

    assert payload |> decode() |> Jason.decode!() == %{
             "sub" => "video-123",
             "iat" => 100,
             "exp" => 160
           }

    expected = :crypto.mac(:hmac, :sha256, "secret", header <> "." <> payload)
    assert decode(signature) == expected
  end

  defp decode(value), do: Base.url_decode64!(value, padding: false)
end
