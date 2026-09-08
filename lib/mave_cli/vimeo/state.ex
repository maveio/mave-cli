defmodule MaveCli.Vimeo.State do
  @moduledoc false

  alias MaveCli.{Config, PrivateFile}

  def open(scope, opts) do
    path = Path.expand(opts[:state_file] || default_path(scope))

    with {:ok, data} <- load(path, scope, opts),
         :ok <- reconciled(data, path) do
      {:ok, %{path: path, data: data}}
    end
  end

  def save(state) do
    case PrivateFile.write_atomic(state.path, Jason.encode!(state.data, pretty: true)) do
      :ok ->
        {:ok, state}

      {:error, _} ->
        {:error,
         "could not save import state to #{state.path}; stop and reconcile before resuming"}
    end
  end

  def lookup(state, kind, id), do: get_in(state.data, [kind, id])

  def begin_item(state, kind, item) do
    pending = %{"kind" => kind, "source_id" => item.id, "name" => item.name}
    save(%{state | data: Map.put(state.data, "pending", pending)})
  end

  def finish_item(state, kind, source_id, mave_id) do
    data = state.data |> put_in([kind, source_id], mave_id) |> Map.put("pending", nil)
    save(%{state | data: data})
  end

  defp default_path(scope) do
    suffix =
      :crypto.hash(:sha256, :erlang.term_to_binary(Enum.sort(scope)))
      |> Base.encode16(case: :lower)

    Path.join([Path.dirname(Config.path()), "imports", "vimeo-#{suffix}.json"])
  end

  # The path is the operator's state file or a hash under their config directory.
  # Remote data never selects a filesystem path.
  # sobelow_skip ["Traversal.FileModule"]
  defp load(path, scope, opts) do
    resume = opts[:resume] == true
    dry_run = opts[:dry_run] == true

    case File.read(path) do
      {:ok, contents} when resume -> decode(contents, scope)
      {:ok, _} when dry_run -> {:ok, empty(scope)}
      {:ok, _} -> {:error, "an import state already exists at #{path}; use --resume"}
      {:error, :enoent} when not resume -> {:ok, empty(scope)}
      {:error, :enoent} -> {:error, "no import state found at #{path}; start without --resume"}
      {:error, _} -> {:error, "could not read import state at #{path}"}
    end
  end

  defp empty(scope),
    do: %{"version" => 1, "scope" => scope, "folders" => %{}, "videos" => %{}, "pending" => nil}

  defp decode(contents, scope) do
    with {:ok,
          %{"version" => 1, "scope" => ^scope, "folders" => folders, "videos" => videos} = data} <-
           Jason.decode(contents),
         true <- valid_mapping?(folders) and valid_mapping?(videos) do
      {:ok, data}
    else
      _ ->
        {:error,
         "import state is invalid or belongs to a different Vimeo account, Mave destination or folder selection"}
    end
  end

  defp valid_mapping?(mapping) when is_map(mapping) do
    Enum.all?(mapping, fn {source, target} ->
      is_binary(source) and is_binary(target) and target != ""
    end)
  end

  defp valid_mapping?(_), do: false

  defp reconciled(%{"pending" => nil}, _path), do: :ok

  defp reconciled(%{"pending" => %{"kind" => kind, "source_id" => id}}, path) do
    {:error,
     "the previous create request for #{kind} Vimeo ID #{id} has an unknown outcome; " <>
       "check Mave and reconcile the pending item in #{path} before using --resume (see the import documentation)"}
  end

  defp reconciled(_, _path), do: {:error, "invalid pending item in import state"}
end
