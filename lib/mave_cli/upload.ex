defmodule MaveCli.Upload do
  @moduledoc false

  alias MaveCli.{Client, Downloader, Progress, TransferProgress, Tus, UploadChannel, UploadToken}

  def run(client, source, opts \\ []) do
    case Downloader.acquire(source, progress: progress?(opts)) do
      {:ok, acquired} ->
        try do
          upload_acquired(client, acquired, opts)
        after
          Downloader.cleanup(acquired)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp upload_acquired(client, acquired, opts) do
    body = maybe_collection(%{}, opts[:collection])

    with {:ok, %{"id" => id} = video} <- Client.create_video(client, body) do
      token = UploadToken.sign(id, Client.upload_key(client))

      case transfer(acquired, token, opts) do
        {:ok, channel} ->
          result = finish(client, video, opts)
          UploadChannel.close(channel)
          result

        {:error, _reason} = error ->
          Client.delete_video(client, id)
          error
      end
    end
  end

  defp transfer(acquired, token, opts) do
    if progress?(opts), do: TransferProgress.status("• Starting a secure Mave upload session…")

    socket_opts = if opts[:socket_url], do: [socket: opts[:socket_url]], else: []

    case UploadChannel.start(token, self(), socket_opts) do
      {:ok, channel} ->
        transfer_file(channel, acquired, token, opts)

      {:error, reason} ->
        message = reason |> exception_message() |> String.replace(token, "[REDACTED]")
        {:error, "could not connect to the Mave upload channel: #{message}"}
    end
  end

  defp transfer_file(channel, acquired, token, opts) do
    tus_opts = [progress: progress?(opts), content_type: acquired[:content_type]]

    tus_opts =
      if opts[:upload_url],
        do: Keyword.put(tus_opts, :endpoint, opts[:upload_url]),
        else: tus_opts

    with {:ok, upload_id} <- await_upload_id(30_000),
         {:ok, _result} <- Tus.upload(acquired.path, token, upload_id, tus_opts) do
      {:ok, channel}
    else
      {:error, _reason} = error ->
        UploadChannel.close(channel)
        error
    end
  end

  defp await_upload_id(timeout) do
    receive do
      {:mave_upload, :initiate, %{"upload_id" => upload_id}} when is_binary(upload_id) ->
        {:ok, upload_id}

      {:mave_upload, :error, payload} ->
        {:error, "Mave upload session rejected: #{event_message(payload)}"}

      {:mave_upload, :disconnected, reason} ->
        {:error, "Mave upload channel disconnected: #{inspect(reason)}"}
    after
      timeout -> {:error, "Mave did not return an upload ID within 30 seconds"}
    end
  end

  defp finish(client, %{"id" => id} = video, opts) do
    if wait_after_upload?(opts) do
      TransferProgress.processing("Mave received the original file", progress: progress?(opts))
      deadline = System.monotonic_time(:millisecond) + timeout(opts) * 1_000
      await_processing(client, video, id, deadline, opts)
    else
      {:ok, video}
    end
  end

  defp await_processing(client, video, id, deadline, opts) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:mave_upload, :completed, payload} ->
        embed = payload["embed"] || id
        TransferProgress.processing("original file saved (#{embed})", progress: progress?(opts))
        await_processing(client, video, id, deadline, opts)

      {:mave_upload, :rendition, payload} ->
        TransferProgress.processing(rendition_description(payload), progress: progress?(opts))

        if playable?(payload) do
          TransferProgress.ready("video is playable", progress: progress?(opts))
          Process.sleep(250)

          case Client.get_video(client, id) do
            {:ok, ready_video} -> {:ok, ready_video}
            {:error, _reason} -> {:ok, Map.put(video, "upload_status", "playable")}
          end
        else
          await_processing(client, video, id, deadline, opts)
        end

      {:mave_upload, :error, payload} ->
        {:error, "Mave processing failed: #{event_message(payload)}"}

      {:mave_upload, :disconnected, _reason} ->
        remaining_seconds = max(div(remaining, 1_000), 1)

        Progress.wait_for_video(client, id,
          timeout: remaining_seconds,
          progress: progress?(opts)
        )
    after
      remaining -> {:error, "video was not playable within #{timeout(opts)} seconds"}
    end
  end

  defp playable?(%{"container" => "hls", "type" => "video"}), do: true
  defp playable?(_payload), do: false

  defp rendition_description(payload) do
    details =
      [payload["type"], payload["container"], resolution(payload)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    if details == "", do: "new rendition ready", else: "rendition ready: #{details}"
  end

  defp resolution(%{"width" => width, "height" => height}), do: "#{width}×#{height}"
  defp resolution(%{"resolution" => resolution}), do: to_string(resolution)
  defp resolution(_payload), do: nil

  defp event_message(%{"message" => message}) when is_binary(message), do: message
  defp event_message(%{"error" => message}) when is_binary(message), do: message
  defp event_message(payload), do: inspect(payload, limit: 20)

  defp exception_message(%{__exception__: true} = exception), do: Exception.message(exception)
  defp exception_message(reason), do: inspect(reason, limit: 10)

  defp maybe_collection(body, nil), do: body
  defp maybe_collection(body, collection), do: Map.put(body, "collection", collection)

  defp wait_after_upload?(opts) do
    case Keyword.fetch(opts, :wait) do
      {:ok, wait?} -> wait?
      :error -> Progress.terminal?()
    end
  end

  defp progress?(opts), do: opts[:progress] != false
  defp timeout(opts), do: opts[:timeout] || 600
end
