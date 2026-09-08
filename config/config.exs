import Config

config :mave_cli,
  api_base_url: "https://api.mave.io/v1/",
  run_cli: config_env() != :test
