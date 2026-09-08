defmodule MaveCli.Vimeo.Catalog do
  @moduledoc false

  alias MaveCli.Vimeo

  def load(client, folder_id \\ nil) do
    with {:ok, roots} <- roots(client, folder_id),
         {:ok, folders} <- walk(client, roots, nil, %{}, []),
         {:ok, folders} <- order(folders),
         {:ok, videos} <- folder_videos(client, folders),
         {:ok, videos} <- unfiled_videos(client, videos, folder_id) do
      {:ok, %{folders: folders, videos: videos |> Map.values() |> Enum.sort_by(& &1.id)}}
    end
  end

  defp roots(client, nil), do: Vimeo.all(client, "/me/projects")

  defp roots(client, id) do
    if Regex.match?(~r/^\d+$/, id) do
      with {:ok, folder} <- Vimeo.get(client, "/me/projects/#{id}"), do: {:ok, [folder]}
    else
      {:error, "--folder must be a numeric Vimeo folder ID"}
    end
  end

  defp walk(client, folders, parent, found, ancestors) do
    Enum.reduce_while(folders, {:ok, found}, fn folder, {:ok, found} ->
      case visit(client, folder, parent, found, ancestors) do
        {:ok, found} -> {:cont, {:ok, found}}
        error -> {:halt, error}
      end
    end)
  end

  defp visit(client, folder, parent, found, ancestors) do
    with {:ok, item} <- item(folder, parent),
         :ok <- valid_ancestry(item.id, ancestors),
         {:ok, item} <- merge_parent(item, found[item.id]) do
      visit_children(client, folder, item, found, ancestors)
    end
  end

  defp visit_children(client, folder, item, found, ancestors) do
    if Map.has_key?(found, item.id) do
      {:ok, Map.put(found, item.id, item)}
    else
      with {:ok, children} <- children(client, folder) do
        walk(client, children, item.id, Map.put(found, item.id, item), [item.id | ancestors])
      end
    end
  end

  defp children(client, folder) do
    connections = get_in(folder, ["metadata", "connections"]) || %{}
    connection = connections["folders"] || connections["items"]

    case connection do
      %{"total" => 0} ->
        {:ok, []}

      %{"uri" => uri} ->
        with {:ok, items} <- Vimeo.all(client, uri, filter: "folder") do
          {:ok, Enum.flat_map(items, &child_folder/1)}
        end

      _ ->
        {:ok, []}
    end
  end

  defp child_folder(%{"type" => "folder", "folder" => folder}), do: [folder]
  defp child_folder(_), do: []

  defp valid_ancestry(id, ancestors) do
    if id in ancestors or length(ancestors) >= 100,
      do: {:error, "Vimeo returned a cyclic or excessively deep folder structure"},
      else: :ok
  end

  defp merge_parent(item, nil), do: {:ok, item}
  defp merge_parent(%{parent_id: nil}, existing), do: {:ok, existing}
  defp merge_parent(item, %{parent_id: nil}), do: {:ok, item}
  defp merge_parent(%{parent_id: parent} = item, %{parent_id: parent}), do: {:ok, item}
  defp merge_parent(_, _), do: {:error, "Vimeo returned a folder with conflicting parents"}

  defp order(folders) do
    Enum.reduce_while(Map.values(folders), {:ok, []}, fn folder, {:ok, result} ->
      case folder_path(folder, folders, []) do
        {:ok, path} -> {:cont, {:ok, [Map.put(folder, :path, path) | result]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.sort_by(result, &{length(&1.path), &1.path, &1.id})}
      error -> error
    end
  end

  defp folder_path(folder, folders, ancestors) do
    with :ok <- valid_ancestry(folder.id, ancestors) do
      parent_path(folder, folders, ancestors)
    end
  end

  defp parent_path(%{parent_id: nil} = folder, _folders, _ancestors), do: {:ok, [folder.name]}

  defp parent_path(folder, folders, ancestors) do
    with {:ok, path} <- folder_path(folders[folder.parent_id], folders, [folder.id | ancestors]),
         do: {:ok, path ++ [folder.name]}
  end

  defp folder_videos(client, folders) do
    Enum.reduce_while(folders, {:ok, %{}}, fn folder, {:ok, found} ->
      with {:ok, videos} <-
             Vimeo.all(client, folder.uri <> "/videos",
               fields: "uri,name",
               include_subfolders: false
             ),
           {:ok, found} <- merge_videos(videos, found, folder.id) do
        {:cont, {:ok, found}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp unfiled_videos(client, found, nil) do
    with {:ok, videos} <- Vimeo.all(client, "/me/videos", fields: "uri,name"),
         do: merge_videos(videos, found, nil)
  end

  defp unfiled_videos(_client, found, _folder), do: {:ok, found}

  defp merge_videos(videos, found, parent) do
    Enum.reduce_while(videos, {:ok, found}, fn video, {:ok, found} ->
      case item(video, parent) do
        {:ok, item} ->
          item = preserve_parent(item, found[item.id])
          {:cont, {:ok, Map.put(found, item.id, item)}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp preserve_parent(%{parent_id: nil} = item, %{parent_id: parent}),
    do: %{item | parent_id: parent}

  defp preserve_parent(item, _existing), do: item

  defp item(%{"uri" => uri, "name" => name}, parent) when is_binary(name) and name != "" do
    with {:ok, id} <- Vimeo.id(uri),
         do: {:ok, %{id: id, uri: uri, name: name, parent_id: parent}}
  end

  defp item(_, _), do: {:error, "Vimeo returned an item without an identifier or title"}
end
