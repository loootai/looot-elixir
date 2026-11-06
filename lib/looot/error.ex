defmodule Looot.Error do
  @moduledoc """
  The one error type for the looot client.

  Every non-2xx answer becomes a `%Looot.Error{}`. So do a missing token, a network failure
  and a timeout (`status: 0`). A run that failed is not an error: `Looot.run/4` and
  `Looot.run_job/3` return the run, and the caller reads `"status"`, `"outcome"` and `"error"`
  on it.

  Fields:

    * `:status` - HTTP status, or `0` for a network failure or timeout.
    * `:code` - `error.code` from the body, else `"http_<status>"`. Local codes are
      `"missing_token"`, `"network_error"`, `"timeout"` and `"invalid_response"`.
    * `:message` - `error.message`, else `"<METHOD> <path> failed with HTTP <status>"`.
    * `:request_id` - `error.requestId`, else the `x-request-id` header.
    * `:retryable` - true when the same request may succeed later, with the same idempotency key.
    * `:retry_hint` - the gateway's one-sentence advice, when it sends one.
    * `:retry_after_seconds` - the body's `retryAfterSeconds`, else the `Retry-After` header.
    * `:top_up` - on a 402 `insufficient_balance`, a map with `"checkoutUrl"` and
      `"dashboardUrl"`. See `top_up_url/1`.
    * `:body` - the decoded body, or the raw text when it is not JSON.
    * `:method` and `:path` - the request that failed.

  The token never appears in an error.
  """

  defexception status: 0,
               code: "unknown",
               message: "",
               request_id: nil,
               retryable: false,
               retry_hint: nil,
               retry_after_seconds: nil,
               top_up: nil,
               body: nil,
               method: nil,
               path: nil

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          code: String.t(),
          message: String.t(),
          request_id: String.t() | nil,
          retryable: boolean(),
          retry_hint: String.t() | nil,
          retry_after_seconds: number() | nil,
          top_up: map() | nil,
          body: term(),
          method: String.t() | nil,
          path: String.t() | nil
        }

  @impl true
  def message(%__MODULE__{} = e) do
    parts =
      [e.code]
      |> maybe_add(e.status != 0, "HTTP #{e.status}")
      |> maybe_add(e.request_id not in [nil, ""], "request #{e.request_id}")

    "looot: #{e.message} (#{Enum.join(parts, ", ")})"
  end

  defp maybe_add(list, true, item), do: list ++ [item]
  defp maybe_add(list, false, _item), do: list

  @doc """
  Where the user can add credit: the open checkout link if there is one, else the dashboard
  link. Returns nil when the error carries no top-up object.
  """
  @spec top_up_url(t()) :: String.t() | nil
  def top_up_url(%__MODULE__{top_up: %{} = t}) do
    case {t["checkoutUrl"], t["dashboardUrl"]} do
      {url, _} when is_binary(url) and url != "" -> url
      {_, url} when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  def top_up_url(%__MODULE__{}), do: nil

  @doc false
  def missing_token(method, path) do
    %__MODULE__{
      status: 401,
      code: "missing_token",
      message: "#{method} #{path} needs a token: set LOOOT_TOKEN or pass token:",
      method: method,
      path: path
    }
  end

  @doc false
  def transport(method, path, reason) do
    {code, text} =
      case reason do
        :timeout -> {"timeout", "#{method} #{path} timed out"}
        other -> {"network_error", "#{method} #{path} could not reach looot: #{inspect(other)}"}
      end

    %__MODULE__{
      status: 0,
      code: code,
      message: text,
      retryable: true,
      method: method,
      path: path
    }
  end

  @doc false
  def invalid_response(method, path, status, body, request_id) do
    %__MODULE__{
      status: status,
      code: "invalid_response",
      message: "#{method} #{path} returned a body that is not the expected JSON",
      request_id: request_id,
      body: body,
      method: method,
      path: path
    }
  end

  @doc false
  def from_response(method, path, status, body_text, headers) do
    request_id = header(headers, "x-request-id")

    base = %__MODULE__{
      status: status,
      code: "http_#{status}",
      message: "#{method} #{path} failed with HTTP #{status}",
      request_id: request_id,
      method: method,
      path: path
    }

    {error, retryable_set?} =
      case Jason.decode(body_text) do
        {:ok, %{} = body} ->
          {apply_body(base, body), is_boolean(get_in(body, ["error", "retryable"]))}

        _ ->
          {%{base | body: if(body_text == "", do: nil, else: body_text)}, false}
      end

    error =
      if error.retry_after_seconds in [nil, 0],
        do: %{error | retry_after_seconds: parse_retry_after(header(headers, "retry-after"))},
        else: error

    if retryable_set?,
      do: error,
      else: %{error | retryable: retryable_by_status(error.status, error.code)}
  end

  defp apply_body(e, body) do
    e = %{e | body: body}

    e =
      case body do
        %{"error" => %{} = env} ->
          e
          |> put_str(:code, env["code"])
          |> put_str(:message, env["message"])
          |> put_str(:request_id, env["requestId"])
          |> put_str(:retry_hint, env["retryHint"])
          |> put_retryable(env["retryable"])
          |> put_num(:retry_after_seconds, env["retryAfterSeconds"])

        _ ->
          e
      end

    e
    |> put_num(:retry_after_seconds, body["retryAfterSeconds"])
    |> then(fn e -> if e.retry_hint, do: e, else: put_str(e, :retry_hint, body["retryHint"]) end)
    |> then(fn e ->
      case body["topUp"] do
        %{} = t -> %{e | top_up: t}
        _ -> e
      end
    end)
  end

  defp put_str(e, key, v) when is_binary(v) and v != "", do: Map.put(e, key, v)
  defp put_str(e, _key, _v), do: e

  defp put_num(e, key, v) when is_number(v) and v > 0, do: Map.put(e, key, v)
  defp put_num(e, _key, _v), do: e

  defp put_retryable(e, v) when is_boolean(v), do: %{e | retryable: v}
  defp put_retryable(e, _v), do: e

  defp retryable_by_status(429, _code), do: true
  defp retryable_by_status(500, _code), do: true
  defp retryable_by_status(503, code), do: code != "billing_unavailable"
  defp retryable_by_status(_status, _code), do: false

  @doc false
  # Automatic retries cover 429, retryable 503s and transport failures only.
  def auto_retry?(%__MODULE__{retryable: true, status: status}) when status in [429, 503],
    do: true

  def auto_retry?(%__MODULE__{retryable: true, status: 0, code: code})
      when code in ["network_error", "timeout"],
      do: true

  def auto_retry?(%__MODULE__{}), do: false

  defp header(headers, name) do
    case Map.get(headers, name) do
      [v | _] when is_binary(v) -> v
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp parse_retry_after(nil), do: nil

  # Seconds only. An HTTP-date Retry-After is ignored and the backoff applies.
  defp parse_retry_after(value) do
    case Float.parse(String.trim(value)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end
end
