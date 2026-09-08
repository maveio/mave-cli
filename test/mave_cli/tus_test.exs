defmodule MaveCli.TusTest do
  use ExUnit.Case, async: true

  alias MaveCli.Tus

  test "creates a TUS upload and sends chunks with increasing offsets" do
    path = Path.join(System.tmp_dir!(), "mave-tus-#{System.unique_integer([:positive])}.webm")
    File.write!(path, "abcdef")
    on_exit(fn -> File.rm(path) end)
    owner = self()

    request = fn opts ->
      method = Keyword.fetch!(opts, :method)
      headers = Keyword.fetch!(opts, :headers)

      case method do
        :post ->
          assert header(headers, "tus-resumable") == "1.0.0"
          assert header(headers, "upload-length") == "6"
          send(owner, {:metadata, header(headers, "upload-metadata")})
          {:ok, %{status: 201, headers: %{"location" => ["upload-1"]}, body: ""}}

        :patch ->
          offset = header(headers, "upload-offset") |> String.to_integer()
          body = Keyword.fetch!(opts, :body)
          send(owner, {:chunk, offset, body})

          {:ok,
           %{
             status: 204,
             headers: %{"upload-offset" => [Integer.to_string(offset + byte_size(body))]},
             body: ""
           }}
      end
    end

    assert {:ok, %{bytes: 6, url: "https://upload.test/files/upload-1"}} =
             Tus.upload(path, "jwt", "upload-id",
               endpoint: "https://upload.test/files",
               chunk_size: 2,
               progress: false,
               request: request
             )

    assert_receive {:metadata, encoded_metadata}
    assert decode_metadata(encoded_metadata)["token"] == "jwt"
    assert decode_metadata(encoded_metadata)["upload_id"] == "upload-id"
    assert_receive {:chunk, 0, "ab"}
    assert_receive {:chunk, 2, "cd"}
    assert_receive {:chunk, 4, "ef"}
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  defp decode_metadata(metadata) do
    Map.new(String.split(metadata, ","), fn item ->
      [key, value] = String.split(item, " ", parts: 2)
      {key, Base.decode64!(value)}
    end)
  end
end
