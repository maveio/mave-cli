defmodule MaveCli.PrivateFile do
  @moduledoc false

  # Parent is the OS temp root or selected config directory; child is cryptographically random.
  # sobelow_skip ["Traversal.FileModule"]
  def create_directory(parent) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    directory = Path.join(parent, "mave-cli-#{suffix}")

    with :ok <- File.mkdir(directory) do
      case restrict(directory, 0o700) do
        :ok ->
          {:ok, directory}

        error ->
          File.rmdir(directory)
          error
      end
    end
  end

  # Call only inside a directory returned by create_directory/1. Protecting the
  # directory first prevents another user opening the file before chmod runs.
  # Exclusive creation and chmod precede content.
  # sobelow_skip ["Traversal.FileModule"]
  def open(path, callback) do
    File.open(path, [:write, :binary, :exclusive], fn file ->
      with :ok <- restrict(path, 0o600), do: callback.(file)
    end)
  end

  # Target is the selected config file; staging is private and rename replaces rather than follows a target symlink.
  # sobelow_skip ["Traversal.FileModule"]
  def write_atomic(path, contents) do
    parent = Path.dirname(path)

    with :ok <- File.mkdir_p(parent),
         {:ok, directory} <- create_directory(parent) do
      temporary = Path.join(directory, "config.json")

      try do
        with {:ok, :ok} <- open(temporary, &IO.binwrite(&1, contents)),
             :ok <- File.rename(temporary, path) do
          :ok
        else
          {:ok, {:error, reason}} -> {:error, reason}
          {:error, reason} -> {:error, reason}
        end
      after
        File.rm(temporary)
        File.rmdir(directory)
      end
    end
  end

  # Only our generated staging directory/file reaches this permissions helper.
  # sobelow_skip ["Traversal.FileModule"]
  defp restrict(path, mode) do
    case :os.type() do
      {:win32, _} -> :ok
      _ -> File.chmod(path, mode)
    end
  end
end
