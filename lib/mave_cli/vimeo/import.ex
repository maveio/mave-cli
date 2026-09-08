defmodule MaveCli.Vimeo.Import do
  @moduledoc false

  alias MaveCli.{Client, Progress, Vimeo}
  alias MaveCli.Vimeo.{Catalog, RateLimit, State}

  def run(client, opts \\ []) do
    with :ok <- validate_options(opts),
         {:ok, token} <- Vimeo.token() do
      run_with_client(client, Vimeo.new(token), opts)
    end
  end

  def run_with_client(client, vimeo, opts \\ []) do
    report(opts, "Reading Vimeo videos and folders…")

    with :ok <- validate_options(opts),
         {:ok, scope} <- scope(client, vimeo, opts),
         {:ok, state} <- State.open(scope, opts),
         {:ok, catalog} <- Catalog.load(vimeo, opts[:folder]) do
      report(opts, "Import state: #{state.path}")

      if opts[:dry_run] do
        {:ok, preview(catalog, state)}
      else
        execute(Client.without_retries(client), vimeo, catalog, state, opts)
      end
    else
      {:error, %RateLimit{} = limit} -> {:error, RateLimit.message(limit)}
      error -> error
    end
  end

  defp validate_options(opts) do
    cond do
      opts[:format] not in [nil, "json", "table"] ->
        {:error, "--format must be json or table"}

      opts[:timeout] && opts[:timeout] <= 0 ->
        {:error, "--timeout must be greater than zero"}

      opts[:folder] && not Regex.match?(~r/^\d+$/, opts[:folder]) ->
        {:error, "--folder must be a numeric Vimeo folder ID"}

      true ->
        :ok
    end
  end

  defp scope(client, vimeo, opts) do
    with {:ok, %{"uri" => account}} when is_binary(account) <-
           Vimeo.get(vimeo, "/me", fields: "uri"),
         {:ok, %{"space_id" => space}} when is_binary(space) <-
           Client.list_videos(client, per_page: 1) do
      {:ok,
       %{
         "vimeo_account" => account,
         "mave_server" => String.trim_trailing(Client.base_url(client), "/"),
         "mave_space" => space,
         "collection" => opts[:collection],
         "folder" => opts[:folder]
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, "could not identify the Vimeo account or Mave space"}
    end
  end

  defp preview(catalog, state) do
    rows =
      Enum.map(
        catalog.folders,
        &row(&1, "folder", catalog, State.lookup(state, "folders", &1.id), "planned")
      ) ++
        Enum.map(
          catalog.videos,
          &row(&1, "video", catalog, State.lookup(state, "videos", &1.id), "planned")
        )

    result(rows, state, true)
  end

  defp execute(client, vimeo, catalog, state, opts) do
    with {:ok, state} <- State.save(state),
         {:ok, state, folders} <- create_folders(client, catalog, state, opts),
         {:ok, state, videos} <- create_videos(client, vimeo, catalog, state, opts) do
      result = result(folders ++ videos, state, false)
      if result["failed"] == 0, do: {:ok, result}, else: {:error, {:import, result}}
    end
  end

  defp create_folders(client, catalog, state, opts) do
    Enum.reduce_while(catalog.folders, {:ok, state, []}, fn folder, {:ok, state, rows} ->
      case create_folder(client, folder, state, opts) do
        {:ok, state, id, status} ->
          {:cont, {:ok, state, rows ++ [row(folder, "folder", catalog, id, status)]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp create_folder(client, folder, state, opts) do
    case State.lookup(state, "folders", folder.id) do
      nil ->
        report(opts, "Creating folder #{inspect(folder.name)}")
        body = body(folder, state, opts)

        with {:ok, state} <- State.begin_item(state, "folders", folder),
             {:ok, id} <- created_id(Client.create_collection(client, body), state.path),
             {:ok, state} <- State.finish_item(state, "folders", folder.id, id) do
          {:ok, state, id, "created"}
        end

      id ->
        {:ok, state, id, "existing"}
    end
  end

  defp create_videos(client, vimeo, catalog, state, opts) do
    Enum.reduce_while(catalog.videos, {:ok, state, []}, fn video, {:ok, state, rows} ->
      case create_video(client, vimeo, video, state, opts) do
        {:ok, state, id, status} ->
          entry = row(video, "video", catalog, id, status)
          {:cont, {:ok, state, rows ++ [entry]}}

        {:unavailable, message} ->
          entry = row(video, "video", catalog, nil, "failed") |> Map.put("error", message)
          report(opts, "Could not import #{inspect(video.name)}: #{message}")
          {:cont, {:ok, state, rows ++ [entry]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp create_video(client, vimeo, video, state, opts) do
    case State.lookup(state, "videos", video.id) do
      nil -> submit_video(client, vimeo, video, state, opts)
      id -> wait(client, state, id, "existing", opts)
    end
  end

  defp submit_video(client, vimeo, video, state, opts) do
    report(opts, "Importing #{inspect(video.name)}")

    case Vimeo.source(vimeo, video.id) do
      {:ok, url} ->
        body = body(video, state, opts) |> Map.put("input_url", url)

        with {:ok, state} <- State.begin_item(state, "videos", video),
             {:ok, id} <- created_id(Client.create_video(client, body), state.path),
             {:ok, state} <- State.finish_item(state, "videos", video.id, id) do
          wait(client, state, id, "submitted", opts)
        end

      {:error, %RateLimit{} = limit} ->
        {:error,
         RateLimit.message(limit) <>
           ". Import stopped; progress is saved. Rerun with --resume after the cooldown"}

      {:error, message} ->
        {:unavailable, message}
    end
  end

  defp wait(client, state, id, status, opts) do
    if opts[:wait] do
      case Progress.wait_for_video(client, id,
             timeout: opts[:timeout] || 600,
             progress: opts[:progress] != false
           ) do
        {:ok, _} -> {:ok, state, id, "playable"}
        {:error, _} -> {:ok, state, id, "failed"}
      end
    else
      {:ok, state, id, status}
    end
  end

  defp body(item, state, opts) do
    parent =
      if item.parent_id,
        do: State.lookup(state, "folders", item.parent_id),
        else: opts[:collection]

    if parent, do: %{"name" => item.name, "collection" => parent}, else: %{"name" => item.name}
  end

  defp created_id({:ok, %{"id" => id}}, _path) when is_binary(id) and id != "", do: {:ok, id}

  defp created_id(_, path) do
    {:error,
     "Mave did not confirm the create request; import stopped to avoid duplicates. " <>
       "Check the destination and reconcile the pending item in #{path} before resuming"}
  end

  defp row(item, kind, catalog, id, status) do
    folder = Enum.find(catalog.folders, &(&1.id == item.parent_id))

    %{
      "object" => "vimeo_import_item",
      "type" => kind,
      "vimeo_id" => item.id,
      "name" => item.name,
      "folder" => if(folder, do: Enum.join(folder.path, "/"), else: "/"),
      "mave_id" => id,
      "status" => if(id && status == "planned", do: "existing", else: status)
    }
    |> processing_error(status, id)
  end

  defp processing_error(row, "failed", id) when is_binary(id),
    do:
      Map.put(row, "error", "Mave has not confirmed playback; resume with --wait to check again")

  defp processing_error(row, _status, _id), do: row

  defp result(rows, state, dry_run) do
    %{
      "data" => rows,
      "dry_run" => dry_run,
      "state_file" => state.path,
      "space_id" => state.data["scope"]["mave_space"],
      "collection" => state.data["scope"]["collection"],
      "folders" => Enum.count(rows, &(&1["type"] == "folder")),
      "videos" => Enum.count(rows, &(&1["type"] == "video")),
      "failed" => Enum.count(rows, &(&1["status"] == "failed"))
    }
  end

  defp report(opts, message) do
    if opts[:progress] != false, do: IO.puts(:stderr, message)
  end
end
