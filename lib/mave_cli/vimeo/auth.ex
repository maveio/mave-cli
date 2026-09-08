defmodule MaveCli.Vimeo.Auth do
  @moduledoc false

  alias MaveCli.{Config, PrivateFile, Terminal, Vimeo}
  alias MaveCli.Vimeo.RateLimit

  def token do
    case credentials() do
      {:ok, token, _source} -> {:ok, token}
      :missing -> authorize()
      error -> error
    end
  end

  def login do
    case credentials() do
      {:ok, _token, :config} ->
        {:ok,
         "Already logged in to Vimeo. Run `mave import vimeo logout` before logging in again."}

      {:ok, _token, :environment} ->
        {:ok,
         "Already authenticated via VIMEO_ACCESS_TOKEN. Unset VIMEO_ACCESS_TOKEN before saving another login."}

      :missing ->
        case authorize() do
          {:ok, _token} -> {:ok, "Logged in to Vimeo."}
          error -> error
        end

      error ->
        error
    end
  end

  # The path is fixed under the operator-selected configuration directory.
  # sobelow_skip ["Traversal.FileModule"]
  def logout do
    case File.rm(path()) do
      result when result in [:ok, {:error, :enoent}] ->
        suffix =
          if environment_token(),
            do: " VIMEO_ACCESS_TOKEN is still set; unset it to stop using that token.",
            else: ""

        {:ok, "Saved Vimeo token removed." <> suffix}

      {:error, _reason} ->
        {:error, "could not remove the saved Vimeo token"}
    end
  end

  def status do
    case credentials() do
      {:ok, _token, :environment} ->
        {:ok, "Logged in to Vimeo via VIMEO_ACCESS_TOKEN."}

      {:ok, _token, :config} ->
        {:ok, "Logged in to Vimeo via #{path()}."}

      :missing ->
        {:error, "no Vimeo token found; use `mave import vimeo login` or VIMEO_ACCESS_TOKEN"}

      error ->
        error
    end
  end

  def path, do: Path.join(Path.dirname(Config.path()), "vimeo.json")

  defp credentials do
    case environment_token() do
      nil -> stored_credentials()
      token -> {:ok, token, :environment}
    end
  end

  defp environment_token, do: normalize_token(System.get_env("VIMEO_ACCESS_TOKEN"))

  # Read only the fixed Vimeo credential file; remote data never selects a path.
  # sobelow_skip ["Traversal.FileModule"]
  defp stored_credentials do
    case File.read(path()) do
      {:ok, content} -> decode_credentials(content)
      {:error, :enoent} -> :missing
      {:error, _reason} -> {:error, "could not read the saved Vimeo token"}
    end
  end

  defp decode_credentials(content) do
    with {:ok, %{"token" => value}} <- Jason.decode(content),
         token when is_binary(token) <- normalize_token(value) do
      {:ok, token, :config}
    else
      _ -> {:error, "invalid saved Vimeo login; run `mave import vimeo logout` and log in again"}
    end
  end

  defp normalize_token(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      token -> token
    end
  end

  defp normalize_token(_value), do: nil

  defp authorize do
    with {:ok, token} <- prompt_for_token(),
         :ok <- validate(token),
         :ok <- save(token) do
      IO.puts(:stderr, "Vimeo token saved to #{path()}")
      {:ok, token}
    end
  end

  defp validate(token) do
    case Vimeo.get(Vimeo.new(token), "/me", fields: "uri") do
      {:ok, %{"uri" => "/users/" <> id}} when id != "" ->
        :ok

      {:ok, _body} ->
        {:error, "could not identify the Vimeo account; token was not saved"}

      {:error, %RateLimit{} = limit} ->
        {:error,
         RateLimit.message(limit) <>
           ". The token has not been saved; retry login after the cooldown"}

      error ->
        error
    end
  end

  defp save(token) do
    case PrivateFile.write_atomic(path(), Jason.encode!(%{"token" => token}, pretty: true)) do
      :ok -> :ok
      {:error, _reason} -> {:error, "could not save the Vimeo token to #{path()}"}
    end
  end

  defp prompt_for_token do
    IO.puts(:stderr, """
    To import your videos, create a Vimeo access token:
      https://developer.vimeo.com/apps

      1. Select an app, or create one (for example, "Mave import").
      2. Under Authentication, select Generate Access Token, then Authenticated (you).
      3. Enable Public, Private and Video Files, then select Generate.

    Paste the generated token below (input is hidden). It will be saved for future imports.
    """)

    case Terminal.read_secret("Vimeo access token: ") do
      value when is_binary(value) or is_list(value) ->
        case value |> to_string() |> normalize_token() do
          nil -> {:error, "Vimeo token must not be empty; set VIMEO_ACCESS_TOKEN"}
          token -> {:ok, token}
        end

      _ ->
        {:error, "could not read Vimeo token; set VIMEO_ACCESS_TOKEN"}
    end
  end
end
