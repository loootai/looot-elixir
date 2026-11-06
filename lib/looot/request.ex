defmodule Looot.Request do
  @moduledoc false
  # HTTP, retries and query building. Not part of the public API.

  alias Looot.{Client, Error}

  @max_retry_wait_ms 30_000

  @doc false
  def request(%Client{} = c, method, path, opts \\ []) do
    auth? = Keyword.get(opts, :auth, true)
    verb = method |> Atom.to_string() |> String.upcase()

    if auth? and is_nil(c.token) do
      {:error, Error.missing_token(verb, path)}
    else
      query = Keyword.get(opts, :query, [])
      body = Keyword.get(opts, :body)
      idem = Keyword.get(opts, :idempotency_key)

      req_opts =
        [
          method: method,
          url: c.base_url <> path <> query_string(query),
          headers: headers(c, auth?, body != nil, idem),
          decode_body: false,
          compressed: false,
          retry: false,
          redirect: false,
          receive_timeout: c.timeout
        ]
        |> put_body(body)
        |> Keyword.merge(c.req_options)

      ctx = %{verb: verb, path: path, raw?: Keyword.get(opts, :raw, false)}
      attempt(c, req_opts, ctx, 0)
    end
  end

  defp put_body(opts, nil), do: opts
  defp put_body(opts, body), do: Keyword.put(opts, :body, Jason.encode!(body))

  defp headers(c, auth?, has_body?, idem) do
    [{"accept", "application/json"}, {"user-agent", c.user_agent}]
    |> add(has_body?, {"content-type", "application/json"})
    |> add(auth?, {"authorization", "Bearer " <> to_string(c.token)})
    |> add(c.agent != nil, {"x-looot-agent", c.agent})
    |> add(idem != nil, {"idempotency-key", idem})
  end

  defp add(list, true, header), do: list ++ [header]
  defp add(list, false, _header), do: list

  defp attempt(c, req_opts, ctx, n) do
    result =
      case Req.request(req_opts) do
        {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
          handle_ok(resp, ctx)

        {:ok, %Req.Response{} = resp} ->
          {:error,
           Error.from_response(
             ctx.verb,
             ctx.path,
             resp.status,
             body_text(resp.body),
             resp.headers
           )}

        {:error, %{reason: reason}} ->
          {:error, Error.transport(ctx.verb, ctx.path, reason)}

        {:error, other} ->
          {:error, Error.transport(ctx.verb, ctx.path, other)}
      end

    case result do
      {:error, %Error{} = e} when n < c.max_retries ->
        if Error.auto_retry?(e) do
          c.sleep.(retry_delay(e, n))
          attempt(c, req_opts, ctx, n + 1)
        else
          result
        end

      _ ->
        result
    end
  end

  defp handle_ok(resp, %{raw?: true}) do
    content_type =
      case resp.headers["content-type"] do
        [v | _] -> v
        _ -> nil
      end

    {:ok, %{body: body_text(resp.body), content_type: content_type}}
  end

  defp handle_ok(resp, ctx) do
    text = body_text(resp.body)

    cond do
      String.trim(text) == "" ->
        {:ok, %{}}

      true ->
        case Jason.decode(text) do
          {:ok, decoded} ->
            {:ok, decoded}

          {:error, _} ->
            request_id =
              case resp.headers["x-request-id"] do
                [v | _] -> v
                _ -> nil
              end

            {:error, Error.invalid_response(ctx.verb, ctx.path, resp.status, text, request_id)}
        end
    end
  end

  defp body_text(body) when is_binary(body), do: body
  defp body_text(nil), do: ""
  defp body_text(%{} = body), do: Jason.encode!(body)
  defp body_text(body) when is_list(body), do: IO.iodata_to_binary(body)

  # Retry-After when the gateway sends it, else 0.5 s, 1 s, 2 s with jitter. Capped at 30 s.
  defp retry_delay(%Error{retry_after_seconds: secs}, _n) when is_number(secs) and secs > 0 do
    min(round(secs * 1000), @max_retry_wait_ms)
  end

  defp retry_delay(_error, n) do
    min(500 * Integer.pow(2, n) + :rand.uniform(250), @max_retry_wait_ms)
  end

  @doc false
  # One path segment: "a/b" and "job:x" cannot change the route.
  def seg(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

  @doc false
  def new_idempotency_key do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    "sdk-" <>
      (:io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
       |> IO.iodata_to_binary())
  end

  @doc false
  # Builds an ordered query list from a keyword list or map. `spec` maps each allowed atom to
  # its wire name. nil and "" are dropped, booleans become "true" / "false", lists are joined
  # with commas.
  def build_query(params, spec) do
    params
    |> normalize_params()
    |> Enum.flat_map(fn {key, value} ->
      case Map.fetch(spec, key) do
        {:ok, wire} ->
          case format_value(value) do
            nil -> []
            text -> [{wire, text}]
          end

        :error ->
          raise ArgumentError,
                "unknown option #{inspect(key)}, expected one of: " <>
                  Enum.map_join(Map.keys(spec), ", ", &inspect/1)
      end
    end)
  end

  defp normalize_params(params) when is_list(params) or is_map(params) do
    Enum.map(params, fn {k, v} -> {to_atom_key(k), v} end)
  end

  defp to_atom_key(k) when is_atom(k), do: k
  defp to_atom_key(k) when is_binary(k), do: String.to_existing_atom(k)

  defp format_value(nil), do: nil
  defp format_value(""), do: nil
  defp format_value(true), do: "true"
  defp format_value(false), do: "false"
  defp format_value(v) when is_list(v), do: v |> Enum.map(&to_string/1) |> Enum.join(",")
  defp format_value(v), do: to_string(v)

  defp query_string([]), do: ""
  defp query_string(query), do: "?" <> URI.encode_query(query)
end
