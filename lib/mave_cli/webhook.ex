defmodule MaveCli.Webhook do
  @moduledoc false

  def verify(payload, signature_header, secret)
      when is_binary(payload) and is_binary(signature_header) and is_binary(secret) do
    with {:ok, timestamp, signatures} <- parse(signature_header) do
      key = timestamp <> "." <> secret

      expected =
        :crypto.mac(:hmac, :sha256, key, payload)
        |> Base.encode16(case: :lower)

      {:ok, Enum.any?(signatures, &secure_equal?(String.downcase(&1), expected)), timestamp}
    end
  end

  def parse(header) when is_binary(header) do
    values =
      header
      |> String.split(",", trim: true)
      |> Enum.map(&String.split(&1, "=", parts: 2))

    timestamp =
      Enum.find_value(values, fn
        [key, value] -> if String.trim(key) == "t", do: String.trim(value)
        _ -> nil
      end)

    signatures =
      Enum.flat_map(values, fn
        [key, value] -> if String.trim(key) == "v1", do: [String.trim(value)], else: []
        _ -> []
      end)

    cond do
      is_nil(timestamp) -> {:error, "Mave-Signature is missing a t value"}
      signatures == [] -> {:error, "Mave-Signature is missing a v1 signature"}
      true -> {:ok, timestamp, signatures}
    end
  end

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false
end
