defmodule MaveCli.Terminal do
  @moduledoc false

  # Burrito pipes BEAM's stdout, which prevents OTP's raw terminal mode even
  # when stdin is a terminal. Preserve stdin for this fixed POSIX helper;
  # return the secret through the port's private fd 4, never terminal output.
  @read_secret_script ~S"""
  saved=$(stty -g) || exit 1
  trap 'stty "$saved"' EXIT
  trap 'exit 1' HUP INT TERM
  stty -echo || exit 1
  printf '%s' "$1" >&2
  IFS= read -r token
  result=$?
  printf '\n' >&2
  [ "$result" -eq 0 ] || exit 1
  printf '%s\n' "$token" >&4
  """

  def read_secret(prompt) do
    case :io.getopts() do
      options when is_list(options) ->
        if Keyword.get(options, :stdin, false) do
          read_terminal_secret(:os.type(), prompt)
        else
          IO.write(:stderr, prompt)
          IO.read(:line)
        end

      _ ->
        {:error, :terminal_unavailable}
    end
  end

  defp read_terminal_secret({:unix, _}, prompt) do
    port =
      Port.open({:spawn_executable, ~c"/bin/sh"}, [
        :binary,
        :exit_status,
        :nouse_stdio,
        args: ["-c", @read_secret_script, "mave", prompt]
      ])

    collect_secret(port, [])
  end

  defp read_terminal_secret({:win32, _}, prompt) do
    case :shell.start_interactive({:noshell, :raw}) do
      :ok ->
        try do
          IO.write(:stderr, prompt)
          :io.get_password()
        after
          :shell.start_interactive({:noshell, :cooked})
        end

      error ->
        error
    end
  end

  defp collect_secret(port, chunks) do
    receive do
      {^port, {:data, chunk}} -> collect_secret(port, [chunk | chunks])
      {^port, {:exit_status, 0}} -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
      {^port, {:exit_status, _}} -> {:error, :terminal_unavailable}
    end
  end
end
