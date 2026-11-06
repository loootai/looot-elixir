# looot for Elixir

[![Hex.pm](https://img.shields.io/hexpm/v/looot.svg)](https://hex.pm/packages/looot) [![Docs](https://img.shields.io/badge/hexdocs-looot-12A06A)](https://hexdocs.pm/looot) [![License](https://img.shields.io/github/license/loootai/looot-elixir)](LICENSE)

The Elixir client for the [looot](https://looot.ai) API. looot is one gateway to 300+
providers (email find and verify, company enrichment, SERP data, social profiles, web
scraping) with one token and one prepaid balance.

Built on [Req](https://hex.pm/packages/req). Elixir 1.15 or newer.

## Install

```elixir
def deps do
  [{:looot, "~> 0.1.0"}]
end
```

Create an API key at [looot.ai](https://looot.ai) (Settings, API keys) and export it:

```bash
export LOOOT_TOKEN=...
```

## Quickstart

Search for a job, inspect the endpoint to see its inputs and price, then run it. `fallback: true`
lets looot try the next provider on a miss. A run is paid.

```elixir
client = Looot.new()                     # reads LOOOT_TOKEN

# Free: find endpoints for a task in plain words.
{:ok, found} = Looot.search(client, q: "find a work email", limit: 3)
[%{"endpointId" => endpoint_id} | _] = found["endpoints"]

# Free: inputs, price and the most a call can cost.
{:ok, spec} = Looot.inspect_endpoint(client, endpoint_id)
IO.inspect(spec["inputSchema"])

# Paid: run a job, looot picks the provider.
{:ok, bal} = Looot.balance(client)

if bal["available"] < 0.05 do
  IO.puts("Add credit: " <> (bal["topUpLink"]["checkoutUrl"] || bal["topUpLink"]["dashboardUrl"]))
else
  {:ok, run} =
    Looot.run_job(
      client,
      "people.email.find",
      %{"first_name" => "Jane", "last_name" => "Doe", "domain" => "example.com"},
      fallback: true,
      wait: 30
    )

  IO.inspect({run["status"], run["outcome"], run["result"]})
end
```

Browsing the catalog is free and needs no token: `Looot.catalog_overview(client, topic: "email")`.

Every call returns `{:ok, map}` or `{:error, %Looot.Error{}}`. Each has a bang twin
(`Looot.balance!/1`) that returns the map or raises. Responses are the decoded JSON with
string keys, so fields this library does not know about stay reachable.

## Read the run, not the HTTP status

A run that failed is not an error. `run/4` and `run_job/4` return it with `"status" => "failed"`
and `"error"` set, even when the gateway answered HTTP 201. A `completed` run can still be a
`miss`.

```elixir
case run do
  %{"error" => %{"code" => code, "retryHint" => hint}} -> IO.puts("#{code}: #{hint}")
  %{"outcome" => outcome} -> IO.puts("outcome: #{outcome}")
end

Looot.Run.succeeded?(run)       # completed and no error
Looot.Run.terminal?(run)        # polling can stop
Looot.Run.raise_for_status(run) # {:ok, run} or {:error, %Looot.Error{}} for a failed run
```

## Errors

Every non-2xx answer is a `%Looot.Error{}`. So are a missing token, a network failure and a
timeout (`status: 0`).

```elixir
case Looot.run_job(client, "people.email.find", input) do
  {:ok, run} -> run
  {:error, %Looot.Error{code: "insufficient_balance"} = e} ->
    IO.puts("Add credit: " <> Looot.Error.top_up_url(e)) # then run again with a new key
  {:error, %Looot.Error{retryable: true} = e} ->
    IO.puts("Try later, same key: #{e.retry_after_seconds}")
  {:error, %Looot.Error{} = e} ->
    IO.puts("#{e.status} #{e.code} #{e.message} #{e.request_id}")
end
```

Fields: `status`, `code`, `message`, `request_id`, `retryable`, `retry_hint`,
`retry_after_seconds`, `top_up` and the decoded `body`. The token never appears in an error or
in `inspect(client)`.

## Idempotency and retries

Every `run` and `run_job` sends an idempotency key. Pass your own, built from your record
(`idempotency_key: "lead-4821-email"`), so a crashed worker replays the first run instead of
paying twice. With no key the library sends `sdk-<uuid v4>`.

The client retries 429, the retryable 503 codes, network errors and timeouts up to 2 times with
the same key. It waits `Retry-After` when the gateway sends it (capped at 30 s), else a short
backoff. It never retries other 4xx answers. `max_retries: 0` turns retries off.

After a failed run, or a 402, run again with a new key. The same key only replays the first
answer.

## Options

```elixir
client =
  Looot.new(
    token: System.fetch_env!("MY_LOOOT_TOKEN"), # default: LOOOT_TOKEN
    base_url: "http://localhost:8787",          # default: https://api.looot.ai
    timeout: 90_000,                            # per request in ms, default 75 s
    max_retries: 0,                             # default 2
    agent: "my-app",                            # sent as X-Looot-Agent, analytics only
    req_options: [connect_options: [timeout: 5_000]] # merged into every Req request
  )
```

`token: ""` means no token, even when `LOOOT_TOKEN` is set. Free routes never send the token.

## Functions

Each takes the client first. Options are keyword lists with snake_case keys. They go out as
camelCase where the API expects it (`max_price_micros` becomes `maxPriceMicros`).

| Function | Route | Token scope | Cost |
| --- | --- | --- | --- |
| `catalog_overview(client, opts)` | `GET /v1/catalog/overview` | none | free |
| `public_catalog(client, opts)` | `GET /v1/public-catalog` | none | free |
| `public_catalog_item(client, id)` | `GET /v1/public-catalog/{id}` | none | free |
| `compare_public_catalog(client, ids)` | `POST /v1/public-catalog/compare` | none | free |
| `search(client, opts)` | `GET /v1/catalog/search` | `catalog.read` | free |
| `discover(client, opts)` | `GET /v1/discover` | `catalog.read` | free |
| `catalog_endpoints(client, opts)` | `GET /v1/catalog/endpoints` | `catalog.read` | free |
| `inspect_endpoint(client, endpoint_id)` | `GET /v1/operations/{id}` | `catalog.read` | free |
| `run(client, endpoint_id, input, opts)` | `POST /v1/runs` | `runs.execute` | paid |
| `run_job(client, job, input, opts)` | `POST /v1/runs` with `job:<id>` | `runs.execute` | paid |
| `get_run(client, run_id, opts)` | `GET /v1/runs/{id}` | `runs.read` | free |
| `list_runs(client, opts)` | `GET /v1/runs` | `runs.read` | free |
| `stream_runs(client, opts)` | `GET /v1/runs`, all pages, lazy | `runs.read` | free |
| `cancel_run(client, run_id)` | `POST /v1/runs/{id}/cancel` | `runs.execute` | free |
| `run_attempts(client, run_id)` | `GET /v1/runs/{id}/attempts` | `runs.read` | free |
| `wait_for_run(client, run_id, opts)` | polls `GET /v1/runs/{id}` | `runs.read` | free |
| `balance(client)` | `GET /v1/balance` | `usage.read` | free |
| `whoami(client)` | `GET /v1/whoami` | `organizations.read` | free |
| `list_top_ups(client)` | `GET /v1/top-ups` | `usage.read` | free |
| `ledger(client, opts)` | `GET /v1/ledger` | `usage.read` | free |
| `capability_request(client, opts)` | `POST /v1/capability-requests` | any token | free |
| `download_media(client, download_path)` | `GET <downloadPath>` | any token | free |

`inspect_endpoint` takes an endpoint id, not `job:<id>`. It is not called `inspect` because
that name belongs to `Kernel`.

Jobs worth knowing: `people.email.find`, `people.email.verify`, `people.phone.find`,
`company.enrich`, `company.search`, `people.search`, `company.technographics`,
`google.serp.organic`, `web.scrape.markdown`, `web.search`, `news.search`,
`linkedin.person.profile`, `video.transcript.get`, `maps.local.search`. Take other ids from
`catalog_overview` or a search row's `"capability"`.

## Develop

```bash
mix deps.get
mix test
mix format --check-formatted
bash scripts/leak-scan.sh .
git config core.hooksPath .githooks   # runs the leak scan before each commit
```

Tests mock HTTP with `Req.Test` plug stubs. No test calls the live API.

## Links

- Docs: https://docs.looot.ai
- API reference: https://docs.looot.ai/reference
- Run errors: https://docs.looot.ai/errors/run-errors
- Agent guide: https://looot.ai/skill.md
- Other SDKs: [looot-js](https://github.com/loootai/looot-js), [looot-python](https://github.com/loootai/looot-python), [looot-go](https://github.com/loootai/looot-go)

## License

MIT. See [LICENSE](LICENSE).
