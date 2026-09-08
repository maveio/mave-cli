defmodule MaveCli.CLI do
  @moduledoc false

  alias MaveCli.{
    BrowserAuth,
    Client,
    Config,
    Input,
    Output,
    Progress,
    Sources,
    Upload,
    UploadToken,
    Webhook
  }

  @switches [
    token: :string,
    browser: :boolean,
    basic: :boolean,
    base_url: :string,
    socket_url: :string,
    upload_url: :string,
    cdn_base_url: :string,
    format: :string,
    page: :integer,
    per_page: :integer,
    uploaded: :boolean,
    collection: :string,
    show_collections: :boolean,
    input_url: :string,
    name: :string,
    root: :boolean,
    wait: :boolean,
    progress: :boolean,
    timeout: :integer,
    expires_in: :integer,
    domain: :string,
    return_key: :boolean,
    signature: :string,
    secret: :string,
    output: :string,
    yes: :boolean,
    help: :boolean,
    version: :boolean
  ]

  @aliases [t: :token, f: :format, o: :output, h: :help, v: :version]

  def run(args) do
    case OptionParser.parse(args, strict: @switches, aliases: @aliases) do
      {opts, positional, []} -> route(positional, opts)
      {_opts, _positional, invalid} -> fail("invalid option(s): #{format_invalid(invalid)}")
    end
  rescue
    error -> fail(Exception.message(error))
  end

  defp route(positional, opts) do
    cond do
      opts[:version] ->
        IO.puts(MaveCli.version())
        0

      opts[:help] == true or positional == [] ->
        IO.puts(help())
        0

      true ->
        execute(positional, opts)
    end
  end

  defp execute(["auth", "login" | rest], opts) do
    with {:ok, token} <- login_token(rest, opts),
         :ok <- Config.save_token(token, base_url: opts[:base_url]) do
      IO.puts("Mave token saved to #{Config.path()}")
      0
    else
      {:error, reason} -> fail(reason)
    end
  end

  defp execute(["auth", "logout"], _opts) do
    case Config.delete_token() do
      :ok -> IO.puts("Saved Mave token removed.") && 0
      {:error, reason} -> fail("could not remove token: #{:file.format_error(reason)}")
    end
  end

  defp execute(["auth", "status"], opts) do
    auth_status(Config.source(opts[:token], base_url: opts[:base_url]))
  end

  defp execute(["webhooks", "verify" | rest], opts) do
    with {:ok, payload} <- webhook_payload(rest),
         {:ok, signature} <- required_value(opts[:signature], "--signature is required"),
         {:ok, secret} <- webhook_secret(opts[:secret]),
         {:ok, valid?, timestamp} <- Webhook.verify(payload, signature, secret),
         :ok <-
           Output.print(%{"valid" => valid?, "timestamp" => timestamp}, opts[:format] || "json") do
      if valid?, do: 0, else: 1
    else
      {:error, message} when is_binary(message) -> fail(message)
    end
  end

  defp execute(["sources", "manifest", embed], opts) do
    execute_public(fn -> Sources.manifest(embed, opts) end, opts)
  end

  defp execute(["sources", "url", embed, path], opts) do
    execute_public(
      fn ->
        with {:ok, url} <- Sources.url(embed, path, opts), do: {:ok, %{"url" => url}}
      end,
      opts
    )
  end

  defp execute(["sources", "download", embed, path], opts) do
    destination = opts[:output] || Path.basename(path)

    execute_public(
      fn ->
        Sources.download(embed, path, destination,
          cdn_base_url: opts[:cdn_base_url],
          overwrite: opts[:yes] == true,
          progress: opts[:progress] != false
        )
      end,
      opts
    )
  end

  defp execute(command, opts) do
    with {:ok, client} <- client(opts),
         {:ok, result} <- dispatch(command, opts, client),
         :ok <- Output.print(result, opts[:format] || "json") do
      0
    else
      {:error, {:api, status, message}} -> fail("Mave API (HTTP #{status}): #{message}")
      {:error, {:transport, message}} -> fail("network error: #{message}")
      {:error, message} when is_binary(message) -> fail(message)
    end
  end

  defp dispatch(["videos", "list"], opts, client) do
    query =
      []
      |> put_query(:page, opts[:page])
      |> put_query(:per_page, opts[:per_page])
      |> put_query(:uploaded, opts[:uploaded])
      |> put_query(:collection, opts[:collection])
      |> put_query(:show_collections, opts[:show_collections])

    Client.list_videos(client, query)
  end

  defp dispatch(["videos", "get", id], _opts, client), do: Client.get_video(client, id)

  defp dispatch(["videos", "create"], opts, client),
    do: create_video(client, nil, opts, false)

  defp dispatch(["videos", "create", url], opts, client),
    do: create_video(client, url, opts, false)

  defp dispatch(["videos", "upload", url], opts, client),
    do: Upload.run(client, url, opts)

  defp dispatch(["videos", "upload"], opts, client) do
    case opts[:input_url] do
      source when is_binary(source) -> Upload.run(client, source, opts)
      nil -> {:error, "provide a local file or URL"}
    end
  end

  defp dispatch(["videos", "wait", id], opts, client) do
    Progress.wait_for_video(client, id,
      timeout: opts[:timeout] || 600,
      progress: opts[:progress] != false
    )
  end

  defp dispatch(["videos", "update", id], opts, client) do
    collection = if opts[:root], do: nil, else: opts[:collection]

    body =
      %{}
      |> put_body("name", opts[:name])
      |> maybe_put_collection(collection, opts[:root] == true)

    if map_size(body) == 0,
      do: {:error, "provide --name, --collection or --root"},
      else: Client.update_video(client, id, body)
  end

  defp dispatch(["videos", "delete", id], opts, client) do
    with :ok <- confirm_delete("video", id, opts[:yes]),
         {:ok, response} <- Client.delete_video(client, id) do
      {:ok, deletion_result(response, id)}
    end
  end

  defp dispatch(["collections", "list"], opts, client) do
    query = [] |> put_query(:page, opts[:page]) |> put_query(:per_page, opts[:per_page])
    Client.list_collections(client, query)
  end

  defp dispatch(["collections", "create"], opts, client) do
    if opts[:name] do
      body = %{"name" => opts[:name]} |> put_body("collection", opts[:collection])
      Client.create_collection(client, body)
    else
      {:error, "--name is required"}
    end
  end

  defp dispatch(["collections", "update", id], opts, client) do
    collection = if opts[:root], do: "", else: opts[:collection]

    body =
      %{}
      |> put_body("name", opts[:name])
      |> maybe_put_collection(collection, opts[:root] == true)

    if map_size(body) == 0,
      do: {:error, "provide --name, --collection or --root"},
      else: Client.update_collection(client, id, body)
  end

  defp dispatch(["collections", "delete", id], opts, client) do
    with :ok <- confirm_delete("collection", id, opts[:yes]),
         {:ok, response} <- Client.delete_collection(client, id) do
      {:ok, deletion_result(response, id)}
    end
  end

  defp dispatch(["spaces", "create"], opts, client) do
    with {:ok, domain} <- required_value(trim_value(opts[:domain]), "--domain is required") do
      body = %{"domain" => domain, "return_key" => opts[:return_key] == true}
      Client.create_space(client, body)
    end
  end

  defp dispatch(["upload-token", subject], opts, client) do
    expires_in = opts[:expires_in] || 3_600
    subject = String.trim(subject)

    if subject == "" do
      {:error, "SUBJECT must not be empty"}
    else
      create_upload_token(subject, expires_in, client)
    end
  end

  defp dispatch(_, _opts, _client), do: {:error, "unknown command; use `mave --help`"}

  defp create_upload_token(subject, expires_in, client) do
    if expires_in > 0 do
      now = System.system_time(:second)

      {:ok,
       %{
         "token" =>
           UploadToken.sign(subject, Client.upload_key(client), now: now, expires_in: expires_in),
         "subject" => subject,
         "expires_at" => now + expires_in
       }}
    else
      {:error, "--expires-in must be greater than zero"}
    end
  end

  defp create_video(client, positional_url, opts, required?) do
    with {:ok, input_url} <-
           Input.resolve_url(positional_url, opts[:input_url], required: required?) do
      body =
        %{}
        |> put_body("collection", opts[:collection])
        |> put_body("input_url", input_url)

      with {:ok, video} <- Client.create_video(client, body) do
        maybe_wait_for_video(client, video, Keyword.put(opts, :input_url, input_url))
      end
    end
  end

  defp maybe_wait_for_video(client, %{"id" => id} = video, opts) do
    if wait_after_create?(opts) do
      Progress.wait_for_video(client, id,
        initial: video,
        timeout: opts[:timeout] || 600,
        progress: opts[:progress] != false
      )
    else
      {:ok, video}
    end
  end

  defp maybe_wait_for_video(_client, video, _opts), do: {:ok, video}

  defp wait_after_create?(opts) do
    case Keyword.fetch(opts, :wait) do
      {:ok, wait?} -> wait?
      :error -> is_binary(opts[:input_url]) and Progress.terminal?()
    end
  end

  defp client(opts) do
    case Config.token(opts[:token], base_url: opts[:base_url]) do
      {:ok, token} ->
        auth = if opts[:basic], do: :basic, else: :bearer
        {:ok, Client.new(token, base_url: opts[:base_url], auth: auth)}

      {:error, _reason} = error ->
        error
    end
  end

  defp auth_status(:flag), do: IO.puts("Logged in via --token.") && 0
  defp auth_status(:environment), do: IO.puts("Logged in via MAVE_TOKEN.") && 0
  defp auth_status(:config), do: IO.puts("Logged in via #{Config.path()}.") && 0

  defp auth_status(:unbound),
    do: fail("stored token is not bound to a server; log in again")

  defp auth_status(:different_server), do: fail("stored token belongs to a different server")

  defp auth_status(:missing),
    do: fail("no token found; use `mave auth login` or MAVE_TOKEN")

  defp login_token([token], _opts), do: validate_token(token)

  defp login_token([], opts) do
    cond do
      is_binary(opts[:token]) ->
        validate_token(opts[:token])

      opts[:browser] == false ->
        prompt_for_token()

      true ->
        case BrowserAuth.login(base_url: opts[:base_url]) do
          {:ok, token} ->
            validate_token(token)

          {:fallback, reason} ->
            IO.puts(:stderr, browser_fallback_message(reason))
            prompt_for_token()

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp login_token(_, _opts), do: {:error, "usage: mave auth login [TOKEN]"}

  defp validate_token(token) do
    case String.trim(token) do
      "" -> {:error, "token must not be empty"}
      value -> {:ok, value}
    end
  end

  defp prompt_for_token do
    case MaveCli.Terminal.read_secret("Mave API token: ") do
      token when is_list(token) or is_binary(token) -> token |> to_string() |> validate_token()
      _ -> {:error, "could not read token"}
    end
  end

  defp browser_fallback_message(:unsupported),
    do: "Browser login is not available on this Mave server yet; falling back to an API token."

  defp browser_fallback_message(:unavailable),
    do: "Browser login could not reach the Mave server; falling back to an API token."

  defp browser_fallback_message(_reason),
    do: "Browser login is unavailable; falling back to an API token."

  defp execute_public(operation, opts) do
    with {:ok, result} <- operation.(),
         :ok <- Output.print(result, opts[:format] || "json") do
      0
    else
      {:error, {:api, status, message}} -> fail("Mave CDN (HTTP #{status}): #{message}")
      {:error, {:transport, message}} -> fail("network error: #{message}")
      {:error, message} when is_binary(message) -> fail(message)
    end
  end

  defp webhook_payload([]), do: read_stdin()
  defp webhook_payload(["-"]), do: read_stdin()

  # The operator explicitly chooses the local payload file; no remote response supplies this path.
  # sobelow_skip ["Traversal.FileModule"]
  defp webhook_payload([path]) do
    case File.read(path) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, "could not read payload: #{:file.format_error(reason)}"}
    end
  end

  defp webhook_payload(_), do: {:error, "usage: mave webhooks verify [PAYLOAD_FILE|-]"}

  defp read_stdin do
    case IO.read(:stdio, :eof) do
      payload when is_binary(payload) -> {:ok, payload}
      {:error, reason} -> {:error, "could not read stdin: #{inspect(reason)}"}
    end
  end

  defp webhook_secret(explicit) do
    case explicit || System.get_env("MAVE_WEBHOOK_SECRET") do
      value when is_binary(value) ->
        required_value(String.trim(value), "webhook secret must not be empty")

      _ ->
        {:error, "no webhook secret found; use --secret or MAVE_WEBHOOK_SECRET"}
    end
  end

  defp required_value(value, _message) when is_binary(value) and value != "", do: {:ok, value}
  defp required_value(_value, message), do: {:error, message}
  defp trim_value(value) when is_binary(value), do: String.trim(value)
  defp trim_value(value), do: value

  defp confirm_delete(_kind, _id, true), do: :ok

  defp confirm_delete(kind, id, _yes) do
    if IO.ANSI.enabled?() do
      case IO.gets("Permanently delete #{kind} #{id}? [y/N] ") do
        answer when answer in ["y\n", "Y\n", "yes\n", "YES\n"] -> :ok
        _ -> {:error, "deletion cancelled"}
      end
    else
      {:error, "use --yes to delete non-interactively"}
    end
  end

  defp put_query(query, _key, nil), do: query
  defp put_query(query, key, value), do: Keyword.put(query, key, value)
  defp put_body(body, _key, nil), do: body
  defp put_body(body, key, value), do: Map.put(body, key, value)
  defp maybe_put_collection(body, nil, false), do: body
  defp maybe_put_collection(body, value, false), do: Map.put(body, "collection", value)
  defp maybe_put_collection(body, value, true), do: Map.put(body, "collection", value)

  defp deletion_result(response, id) when is_map(response),
    do: Map.merge(%{"deleted" => true, "id" => id}, response)

  defp deletion_result(_response, id), do: %{"deleted" => true, "id" => id}

  defp format_invalid(invalid),
    do: Enum.map_join(invalid, ", ", fn {key, value} -> "#{key}=#{value}" end)

  defp fail(message) do
    IO.puts(:stderr, "Error: #{message}")
    1
  end

  defp help do
    """
    mave #{MaveCli.version()} — command-line client for mave.io

    Usage:
      mave auth login [TOKEN] [--no-browser]
      mave auth status | logout
      mave videos list [--page N] [--per-page N] [--collection ID]
      mave videos get ID
      mave videos upload FILE_OR_URL [--collection ID] [--wait]
      mave videos create [URL | --input-url URL] [--collection ID] [--wait]
      mave videos wait ID [--timeout SECONDS]
      mave videos update ID [--name NAME] [--collection ID | --root]
      mave videos delete ID [--yes]
      mave collections list [--page N] [--per-page N]
      mave collections create --name NAME [--collection ID]
      mave collections update ID [--name NAME] [--collection ID | --root]
      mave collections delete ID [--yes]
      mave spaces create --domain DOMAIN [--return-key]
      mave upload-token SUBJECT [--expires-in SECONDS]
      mave webhooks verify [PAYLOAD_FILE|-] --signature HEADER [--secret SECRET]
      mave sources manifest EMBED_ID
      mave sources url EMBED_ID SOURCE_PATH
      mave sources download EMBED_ID SOURCE_PATH [-o FILE] [--yes]

    Global options:
      -t, --token TOKEN        override MAVE_TOKEN/stored token
          --no-browser         skip browser login and prompt for a token
          --basic              use Basic instead of Bearer authentication
      -f, --format FORMAT      json (default) or table
          --base-url URL       alternative API base URL
          --socket-url URL     alternative upload socket URL (ws:// or wss://)
          --upload-url URL     alternative TUS endpoint, including /files
          --cdn-base-url URL   alternative CDN base URL; {space} expands to the space hash
          --wait               wait until the video is playable
          --no-wait            stop after TUS receives the original
          --no-progress        hide transfer and processing progress
          --timeout SECONDS    maximum wait time (default: 600)
      -h, --help               show this help
      -v, --version            show the version
    """
  end
end
