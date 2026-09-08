defmodule MaveCli.DeviceName do
  @moduledoc false

  @maximum_length 160

  def get(opts \\ []) do
    computer_name =
      if Keyword.get(opts, :os, :os.type()) == {:unix, :darwin} do
        read(Keyword.get(opts, :computer_name, &macos_computer_name/0))
      end

    computer_name || read(Keyword.get(opts, :hostname, &hostname/0))
  end

  defp read(provider) do
    case provider.() do
      name when is_binary(name) -> normalize(name)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp normalize(name) do
    if String.valid?(name) do
      name = name |> String.replace(~r/[\p{Cc}\p{Cf}]/u, "") |> String.trim()

      if name not in ["", "localhost", "localhost.localdomain", "(none)"] and
           String.length(name) <= @maximum_length do
        name
      end
    end
  end

  # Read the OS setting using a fixed system executable and arguments, without a shell.
  # sobelow_skip ["CI.System"]
  defp macos_computer_name do
    case System.cmd("/usr/sbin/scutil", ["--get", "ComputerName"], stderr_to_stdout: true) do
      {name, 0} -> name
      _ -> nil
    end
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      _ -> nil
    end
  end
end
