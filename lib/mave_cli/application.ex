defmodule MaveCli.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    if Application.fetch_env!(:mave_cli, :run_cli) do
      args = :init.get_plain_arguments() |> Enum.map(&to_string/1)
      exit_code = MaveCli.CLI.run(args)
      System.halt(exit_code)
    else
      Supervisor.start_link([], strategy: :one_for_one, name: MaveCli.Supervisor)
    end
  end
end
