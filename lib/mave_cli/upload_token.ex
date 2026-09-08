defmodule MaveCli.UploadToken do
  @moduledoc false

  def sign(subject, api_key, opts \\ []) when is_binary(subject) and is_binary(api_key) do
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)
    expires_in = Keyword.get(opts, :expires_in, 3_600)

    header = encode(%{"alg" => "HS256", "typ" => "JWT"})
    payload = encode(%{"sub" => subject, "iat" => now, "exp" => now + expires_in})
    signing_input = header <> "." <> payload
    signature = :crypto.mac(:hmac, :sha256, api_key, signing_input) |> base64url()

    signing_input <> "." <> signature
  end

  defp encode(value), do: value |> Jason.encode!() |> base64url()
  defp base64url(value), do: Base.url_encode64(value, padding: false)
end
