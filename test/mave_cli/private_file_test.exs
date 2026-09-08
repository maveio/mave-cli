defmodule MaveCli.PrivateFileTest do
  use ExUnit.Case, async: true

  alias MaveCli.PrivateFile

  @moduletag :tmp_dir

  test "directory and file are private before any content is written", %{tmp_dir: parent} do
    assert {:ok, directory} = PrivateFile.create_directory(parent)
    path = Path.join(directory, "secret.json")

    assert {:ok, :ok} =
             PrivateFile.open(path, fn file ->
               if match?({:unix, _}, :os.type()) do
                 assert Bitwise.band(File.stat!(directory).mode, 0o777) == 0o700
                 assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
               end

               assert File.read!(path) == ""
               IO.binwrite(file, "synthetic secret")
             end)

    assert File.read!(path) == "synthetic secret"
  end

  test "failed atomic replacement removes its temporary data", %{tmp_dir: parent} do
    destination = Path.join(parent, "existing-directory")
    File.mkdir!(destination)
    File.write!(Path.join(destination, "keep"), "keep")

    assert {:error, _} = PrivateFile.write_atomic(destination, "synthetic secret")
    assert File.read!(Path.join(destination, "keep")) == "keep"
    assert Path.wildcard(Path.join(parent, "mave-cli-*")) == []
  end
end
