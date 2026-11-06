# Changelog

## 0.1.0 (2026-11-06)

First release.

- `Looot.new/1` builds a client. `Looot.Client` holds the settings and hides the token from
  `inspect/1`. HTTP goes through Req, and `req_options` lets tests inject a `Req.Test` plug.
- Core functions: `catalog_overview`, `public_catalog`, `public_catalog_item`, `search`,
  `inspect_endpoint`, `run`, `run_job`, `get_run`, `list_runs`, `cancel_run`, `run_attempts`,
  `balance`.
- Extended functions: `discover`, `catalog_endpoints`, `compare_public_catalog`, `whoami`,
  `list_top_ups`, `ledger`, `capability_request`, `download_media`.
- Helpers: `wait_for_run` (polls 1 s to 5 s), `stream_runs` (lazy, follows the cursor) and
  `Looot.Run` (`succeeded?`, `terminal?`, `raise_for_status`).
- Every function returns `{:ok, map}` or `{:error, %Looot.Error{}}` and has a bang twin.
- `Looot.Error` covers every non-2xx answer, a missing token, network errors and timeouts, with
  `code`, `retryable`, `retry_hint`, `retry_after_seconds` and the 402 `top_up` link.
- Retries 429, retryable 503s, network errors and timeouts twice by default with the same
  idempotency key. `max_retries: 0` turns them off.
- Sends `User-Agent: looot-elixir/0.1.0 elixir/<version>` and, with `agent:`, `X-Looot-Agent`.
