defmodule Looot do
  @moduledoc """
  Elixir client for the [looot](https://looot.ai) API.

  looot is one gateway to data providers (email find and verify, company enrichment, SERP
  data, social profiles, web scraping) with one token and one prepaid balance. Reference:
  https://docs.looot.ai/reference.

      client = Looot.new()                      # reads LOOOT_TOKEN
      {:ok, bal} = Looot.balance(client)
      {:ok, run} =
        Looot.run_job(client, "people.email.find", %{"domain" => "example.com"},
          fallback: true, wait: 30)

  Every function returns `{:ok, map}` or `{:error, %Looot.Error{}}`. Each has a bang twin
  (`balance!/1`) that returns the map or raises the error. Responses are the decoded JSON as
  maps with string keys, so fields this library does not know about stay reachable.

  A run that failed is not an error. `run/4` and `run_job/4` return the run, and the caller
  reads `"status"`, `"outcome"` and `"error"` on it. See `Looot.Run`.

  Request options are keyword lists (or maps) with snake_case atom keys. They are sent as
  camelCase where the API expects it: `max_price_micros` goes out as `maxPriceMicros`. An
  unknown key raises `ArgumentError`.
  """

  alias Looot.{Client, Error, Request}

  @version Mix.Project.config()[:version]
  @default_base_url "https://api.looot.ai"
  @default_timeout 75_000
  @default_max_retries 2
  @max_agent_length 64

  @doc "The SDK version."
  @spec version() :: String.t()
  def version, do: @version

  @doc "The production API URL."
  @spec default_base_url() :: String.t()
  def default_base_url, do: @default_base_url

  @doc """
  Builds a client.

  Options:

    * `:token` - bearer token. Wins over `LOOOT_TOKEN`, even when it is empty: an explicit
      empty token means "no token".
    * `:base_url` - another gateway, for example a local one. Trailing slashes are stripped.
      Default `#{@default_base_url}`.
    * `:timeout` - per-request timeout in milliseconds. Default `#{@default_timeout}`, enough
      for a 60 s `wait`.
    * `:max_retries` - how many times a retryable error is retried with the same idempotency
      key. `0` turns retries off. Default `#{@default_max_retries}`.
    * `:agent` - name of your app or agent, sent as `X-Looot-Agent` (cut to 64 characters).
      looot uses it for usage analytics only.
    * `:req_options` - extra options merged into every `Req.request/1` call. Tests pass
      `plug: {Req.Test, MyStub}` here.
    * `:sleep` - function called with milliseconds between retries. Default `Process.sleep/1`.
  """
  @spec new(keyword()) :: Client.t()
  def new(opts \\ []) do
    token =
      if Keyword.has_key?(opts, :token) and opts[:token] != nil,
        do: clean_token(opts[:token]),
        else: clean_token(System.get_env("LOOOT_TOKEN"))

    %Client{
      base_url: opts |> Keyword.get(:base_url, @default_base_url) |> clean_base_url(),
      token: token,
      agent: clean_agent(opts[:agent]),
      user_agent: "looot-elixir/#{@version} elixir/#{System.version()}",
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      max_retries: Keyword.get(opts, :max_retries, @default_max_retries),
      req_options: Keyword.get(opts, :req_options, []),
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
      new_key: &Request.new_idempotency_key/0
    }
  end

  defp clean_token(nil), do: nil

  defp clean_token(token) do
    case token |> to_string() |> String.trim() do
      "" -> nil
      t -> t
    end
  end

  defp clean_base_url(url), do: url |> to_string() |> String.trim() |> String.trim_trailing("/")

  defp clean_agent(nil), do: nil

  defp clean_agent(name) do
    case name |> to_string() |> String.trim() |> String.slice(0, @max_agent_length) do
      "" -> nil
      n -> n
    end
  end

  # ---------------------------------------------------------------- free routes

  @overview_spec %{depth: "depth", category: "category", platform: "platform", topic: "topic"}

  @doc """
  Maps the catalog: categories by default, matching jobs with `topic:`. Free, no token sent.

  Options: `:depth` (`"summary"`, `"platforms"`, `"jobs"`, `"full"`), `:category`, `:platform`,
  `:topic`.
  """
  @spec catalog_overview(Client.t(), keyword() | map()) :: {:ok, map()} | {:error, Error.t()}
  def catalog_overview(%Client{} = c, params \\ []) do
    get(c, "/v1/catalog/overview", params, @overview_spec, auth: false)
  end

  @public_spec %{
    q: "q",
    text: "text",
    capability: "capability",
    category: "category",
    provider: "provider",
    operation_id: "operationId",
    limit: "limit",
    cursor: "cursor"
  }

  @doc """
  Lists published catalog items. Free, no token sent.

  Options: `:q`, `:text`, `:capability` (job id with dots turned into underscores,
  `"people_email_verify"`), `:category`, `:provider`, `:operation_id`, `:limit` (1 to 100),
  `:cursor`.
  """
  @spec public_catalog(Client.t(), keyword() | map()) :: {:ok, map()} | {:error, Error.t()}
  def public_catalog(%Client{} = c, params \\ []) do
    get(c, "/v1/public-catalog", params, @public_spec, auth: false)
  end

  @doc "Returns one published catalog item. Free, no token sent."
  @spec public_catalog_item(Client.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def public_catalog_item(%Client{} = c, catalog_item_id) do
    get(c, "/v1/public-catalog/" <> Request.seg(catalog_item_id), [], %{}, auth: false)
  end

  @doc "Compares 2 to 20 public catalog items. Free, no token sent."
  @spec compare_public_catalog(Client.t(), [String.t()]) :: {:ok, map()} | {:error, Error.t()}
  def compare_public_catalog(%Client{} = c, catalog_item_ids) when is_list(catalog_item_ids) do
    Request.request(c, :post, "/v1/public-catalog/compare",
      auth: false,
      body: %{"catalogItemIds" => catalog_item_ids}
    )
  end

  # ---------------------------------------------------------------- discovery

  @search_spec %{
    q: "q",
    limit: "limit",
    offset: "offset",
    category: "category",
    platform: "platform",
    provider: "provider",
    capability: "capability",
    keyless: "keyless",
    verified: "verified",
    mock: "mock",
    max_price_micros: "maxPriceMicros",
    prefer: "prefer"
  }

  @doc """
  Finds endpoints for a task in plain words. Needs `catalog.read`. Free.

  Options: `:q`, `:limit` (1 to 200), `:offset`, `:category`, `:platform`, `:provider`,
  `:capability` (job id with dots, `"people.email.find"`), `:keyless`, `:verified`, `:mock`,
  `:max_price_micros`, `:prefer` (`:cheapest`, `:reliable`, `:fastest`, `:balanced`).
  """
  @spec search(Client.t(), keyword() | map()) :: {:ok, map()} | {:error, Error.t()}
  def search(%Client{} = c, params \\ []) do
    get(c, "/v1/catalog/search", params, @search_spec)
  end

  @discover_spec %{
    query: "query",
    mode: "mode",
    capability: "capability",
    category: "category",
    provider: "provider",
    prefer: "prefer",
    result_limit: "resultLimit",
    max_price: "maxPrice",
    include_unavailable: "includeUnavailable"
  }

  @doc """
  Returns up to 5 ranked candidates for a task. Needs `catalog.read`. Free.

  Options: `:query`, `:mode`, `:capability`, `:category`, `:provider`, `:prefer`,
  `:result_limit`, `:max_price` (USD), `:include_unavailable`.
  """
  @spec discover(Client.t(), keyword() | map()) :: {:ok, map()} | {:error, Error.t()}
  def discover(%Client{} = c, params \\ []) do
    get(c, "/v1/discover", params, @discover_spec)
  end

  @endpoints_spec %{
    capability: "capability",
    category: "category",
    platform: "platform",
    provider: "provider",
    keyless: "keyless",
    verified: "verified",
    mock: "mock",
    max_price_micros: "maxPriceMicros",
    include_unavailable: "includeUnavailable",
    facets: "facets",
    limit: "limit",
    cursor: "cursor"
  }

  @doc """
  Lists endpoints page by page. Needs `catalog.read`. Free. Pass the `"nextCursor"` of one
  page as `:cursor` for the next. `facets: true` adds counts.
  """
  @spec catalog_endpoints(Client.t(), keyword() | map()) :: {:ok, map()} | {:error, Error.t()}
  def catalog_endpoints(%Client{} = c, params \\ []) do
    get(c, "/v1/catalog/endpoints", params, @endpoints_spec)
  end

  @doc """
  Returns one endpoint's inputs, price and hints. It takes an endpoint id, not `"job:<id>"`.
  Needs `catalog.read`. Free.
  """
  @spec inspect_endpoint(Client.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def inspect_endpoint(%Client{} = c, endpoint_id) do
    get(c, "/v1/operations/" <> Request.seg(endpoint_id), [], %{})
  end

  # ---------------------------------------------------------------- runs

  @doc """
  Runs one endpoint. Paid. Needs `runs.execute`.

  `input` is a map validated against the endpoint's own schema. Options:

    * `:idempotency_key` - build it from your record (`"lead-4821-email"`) so a crashed worker
      replays the first run instead of paying twice. Default `sdk-<uuid v4>`.
    * `:wait` - seconds (0 to 60) to wait for the answer, or `true` for 20 s. Sent in the
      query.
    * `:fallback` - `true`, or a map/keyword with `:enabled`, `:max_attempts`, `:max_cost_usd`,
      `:prefer`, `:exclude`, `:stop_at_first_miss`.
    * `:output` - output selection map.

  A run refused before dispatch comes back as a run with `"status" => "failed"`, not as an
  error. `{:error, _}` means the HTTP call failed (402 `insufficient_balance`, 429, ...).
  After a failed run or a 402, run again with a new key.
  """
  @spec run(Client.t(), String.t(), map() | nil, keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(%Client{} = c, endpoint_id, input \\ %{}, opts \\ []) do
    key =
      case Keyword.get(opts, :idempotency_key) do
        k when k in [nil, ""] -> c.new_key.()
        k -> k
      end

    body =
      %{
        "endpointId" => endpoint_id,
        "input" => input || %{},
        "idempotencyKey" => key
      }
      |> put_if("fallback", fallback_body(opts[:fallback]))
      |> put_if("output", opts[:output])

    query = Request.build_query([wait: wait_value(opts[:wait])], %{wait: "wait"})

    Request.request(c, :post, "/v1/runs",
      body: body,
      query: query,
      idempotency_key: key
    )
  end

  @doc """
  Runs a job such as `"people.email.find"`; looot picks the provider. Paid.

  Takes the options of `run/4` plus `:prefer`. `:prefer` goes into `fallback.prefer` and
  turns fallback on. Without `:prefer` and `:fallback` a job run does not fall back.
  """
  @spec run_job(Client.t(), String.t(), map() | nil, keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run_job(%Client{} = c, job, input \\ %{}, opts \\ []) do
    {prefer, opts} = Keyword.pop(opts, :prefer)

    fallback =
      case {prefer, fallback_body(opts[:fallback])} do
        {nil, fb} -> fb
        {p, %{} = fb} -> Map.put(fb, "prefer", to_string(p))
        {p, _} -> %{"prefer" => to_string(p)}
      end

    run(c, "job:" <> job, input, Keyword.put(opts, :fallback, fallback))
  end

  @get_run_spec %{fields: "fields", max_items: "max_items"}

  @doc """
  Returns a run. Needs `runs.read`.

  Options: `:fields` (list of dotted paths of `result` to keep) and `:max_items` (caps every
  list, 1 to 10000). A trimmed answer carries `"trimmed"`; the charge does not change.
  """
  @spec get_run(Client.t(), String.t(), keyword() | map()) :: {:ok, map()} | {:error, Error.t()}
  def get_run(%Client{} = c, run_id, params \\ []) do
    get(c, "/v1/runs/" <> Request.seg(run_id), params, @get_run_spec)
  end

  @list_runs_spec %{
    status: "status",
    capability: "capability",
    limit: "limit",
    cursor: "cursor",
    include_result: "includeResult"
  }

  @doc """
  Returns one page of runs, newest first. Needs `runs.read`.

  Options: `:status`, `:capability`, `:limit` (1 to 50), `:cursor`, `:include_result`.
  """
  @spec list_runs(Client.t(), keyword() | map()) :: {:ok, map()} | {:error, Error.t()}
  def list_runs(%Client{} = c, params \\ []) do
    get(c, "/v1/runs", params, @list_runs_spec)
  end

  @doc """
  A lazy stream of every run, following `"nextCursor"` until the last page. Takes the options
  of `list_runs/2`. A failed page raises `Looot.Error`.
  """
  @spec stream_runs(Client.t(), keyword()) :: Enumerable.t()
  def stream_runs(%Client{} = c, params \\ []) do
    Stream.resource(
      fn -> {:more, Keyword.delete(params, :cursor)} end,
      fn
        :done ->
          {:halt, :done}

        {:more, p} ->
          page = list_runs!(c, p)
          runs = page["runs"] || []

          case page["nextCursor"] do
            cursor when is_binary(cursor) and cursor != "" ->
              {runs, {:more, Keyword.put(p, :cursor, cursor)}}

            _ ->
              {runs, :done}
          end
      end,
      fn _ -> :ok end
    )
  end

  @doc "Asks the gateway to stop a run. A settled run comes back unchanged. Needs `runs.execute`."
  @spec cancel_run(Client.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def cancel_run(%Client{} = c, run_id) do
    Request.request(c, :post, "/v1/runs/" <> Request.seg(run_id) <> "/cancel")
  end

  @doc "Lists every provider attempt of a run. Needs `runs.read`."
  @spec run_attempts(Client.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def run_attempts(%Client{} = c, run_id) do
    get(c, "/v1/runs/" <> Request.seg(run_id) <> "/attempts", [], %{})
  end

  @doc """
  Polls `get_run/3` until the run reaches a terminal status. Starts at 1 s and backs off to
  5 s. Options: `:timeout` in milliseconds (default 120000), `:interval`, `:max_interval`.
  Returns `{:error, %Looot.Error{code: "timeout"}}` when the time runs out.
  """
  @spec wait_for_run(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def wait_for_run(%Client{} = c, run_id, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 120_000)
    max_interval = Keyword.get(opts, :max_interval, 5_000)
    poll(c, run_id, deadline, Keyword.get(opts, :interval, 1_000), max_interval)
  end

  defp poll(c, run_id, deadline, interval, max_interval) do
    with {:ok, run} <- get_run(c, run_id) do
      cond do
        Looot.Run.terminal?(run) ->
          {:ok, run}

        System.monotonic_time(:millisecond) + interval > deadline ->
          {:error,
           %Error{
             status: 0,
             code: "timeout",
             message: "run #{run_id} did not finish before the wait timeout",
             method: "GET",
             path: "/v1/runs/" <> Request.seg(run_id)
           }}

        true ->
          c.sleep.(interval)
          poll(c, run_id, deadline, min(interval * 2, max_interval), max_interval)
      end
    end
  end

  # ---------------------------------------------------------------- account

  @doc """
  Returns the workspace balance and the top-up link. Needs `usage.read`. Free.

  Show the user `balance["topUpLink"]["checkoutUrl"]` when it is set, else its
  `"dashboardUrl"`.
  """
  @spec balance(Client.t()) :: {:ok, map()} | {:error, Error.t()}
  def balance(%Client{} = c), do: get(c, "/v1/balance", [], %{})

  @doc "Names the workspace and role behind the token. Needs `organizations.read`."
  @spec whoami(Client.t()) :: {:ok, map()} | {:error, Error.t()}
  def whoami(%Client{} = c), do: get(c, "/v1/whoami", [], %{})

  @doc """
  Lists the workspace's top-ups. Needs `usage.read`. To add credit, show the user the link
  from `balance/1`.
  """
  @spec list_top_ups(Client.t()) :: {:ok, map()} | {:error, Error.t()}
  def list_top_ups(%Client{} = c), do: get(c, "/v1/top-ups", [], %{})

  @doc "Returns one page of ledger entries. Needs `usage.read`. Options: `:limit`, `:cursor`."
  @spec ledger(Client.t(), keyword() | map()) :: {:ok, map()} | {:error, Error.t()}
  def ledger(%Client{} = c, params \\ []) do
    get(c, "/v1/ledger", params, %{limit: "limit", cursor: "cursor"})
  end

  @doc """
  Asks looot to add a missing provider or job.

  Options: `:title`, `:description`, `:desired_inputs`, `:desired_outputs`, `:request_id`,
  `:idempotency_key`. The two ids are generated when missing.
  """
  @spec capability_request(Client.t(), keyword() | map()) ::
          {:ok, map()} | {:error, Error.t()}
  def capability_request(%Client{} = c, params) do
    spec = %{
      request_id: "requestId",
      title: "title",
      description: "description",
      desired_inputs: "desiredInputs",
      desired_outputs: "desiredOutputs",
      idempotency_key: "idempotencyKey"
    }

    # Validate keys, but keep list and map values as they are.
    given = Map.new(params, fn {k, v} -> {to_atom(k), v} end)

    for key <- Map.keys(given), not Map.has_key?(spec, key) do
      raise ArgumentError, "unknown option #{inspect(key)}"
    end

    body =
      for {k, wire} <- spec, given[k] not in [nil, ""], into: %{}, do: {wire, given[k]}

    body =
      body
      |> Map.put_new("requestId", c.new_key.())
      |> Map.put_new("idempotencyKey", c.new_key.())

    Request.request(c, :post, "/v1/capability-requests", body: body)
  end

  @doc """
  Downloads a run's file from `result.media.downloadPath`. Returns
  `{:ok, %{body: binary, content_type: String.t() | nil}}`.

  The path must be a path on the gateway (one leading slash), so the token never goes to
  another host.
  """
  @spec download_media(Client.t(), String.t()) ::
          {:ok, %{body: binary(), content_type: String.t() | nil}} | {:error, Error.t()}
  def download_media(%Client{} = c, "/" <> _ = download_path) do
    if String.starts_with?(download_path, "//") do
      {:error, bad_download_path(download_path)}
    else
      {path, query} =
        case String.split(download_path, "?", parts: 2) do
          [p, q] -> {p, URI.decode_query(q) |> Enum.to_list()}
          [p] -> {p, []}
        end

      Request.request(c, :get, path, query: query, raw: true)
    end
  end

  def download_media(%Client{}, download_path), do: {:error, bad_download_path(download_path)}

  defp bad_download_path(path) do
    %Error{
      status: 0,
      code: "invalid_download_path",
      message: "download path must start with a single \"/\", got #{inspect(path)}"
    }
  end

  # ---------------------------------------------------------------- helpers

  defp get(c, path, params, spec, opts \\ []) do
    Request.request(c, :get, path, [query: Request.build_query(params, spec)] ++ opts)
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, false), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp wait_value(nil), do: nil
  defp wait_value(false), do: nil
  defp wait_value(v), do: v

  @fallback_keys %{
    enabled: "enabled",
    max_attempts: "maxAttempts",
    max_cost_usd: "maxCostUsd",
    prefer: "prefer",
    exclude: "exclude",
    stop_at_first_miss: "stopAtFirstMiss"
  }

  defp fallback_body(nil), do: nil
  defp fallback_body(false), do: nil
  defp fallback_body(true), do: true

  defp fallback_body(fb) when is_list(fb) or is_map(fb) do
    Map.new(fb, fn {k, v} ->
      key = Map.get(@fallback_keys, to_atom(k), to_string(k))
      {key, if(key == "prefer", do: to_string(v), else: v)}
    end)
  end

  defp to_atom(k) when is_atom(k), do: k
  defp to_atom(k) when is_binary(k), do: String.to_atom(k)

  # ---------------------------------------------------------------- bang twins

  @doc false
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, %Error{} = e}), do: raise(e)

  for {name, arities} <- [
        catalog_overview: [1, 2],
        public_catalog: [1, 2],
        public_catalog_item: [2],
        compare_public_catalog: [2],
        search: [1, 2],
        discover: [1, 2],
        catalog_endpoints: [1, 2],
        inspect_endpoint: [2],
        run: [2, 3, 4],
        run_job: [2, 3, 4],
        get_run: [2, 3],
        list_runs: [1, 2],
        cancel_run: [2],
        run_attempts: [2],
        wait_for_run: [2, 3],
        balance: [1],
        whoami: [1],
        list_top_ups: [1],
        ledger: [1, 2],
        capability_request: [2],
        download_media: [2]
      ],
      arity <- arities do
    bang = :"#{name}!"
    args = Macro.generate_arguments(arity, __MODULE__)

    @doc "Same as `#{name}/#{arity}`, but returns the value or raises `Looot.Error`."
    def unquote(bang)(unquote_splicing(args)) do
      unquote(name)(unquote_splicing(args)) |> unwrap!()
    end
  end
end
