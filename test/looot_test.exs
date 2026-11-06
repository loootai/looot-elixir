defmodule LoootTest do
  use ExUnit.Case, async: true

  @token "test-token-not-real"
  @stub __MODULE__

  # The plug runs in the calling process, so a stub can send the request to the test.
  defp client(opts \\ []) do
    test = self()

    Looot.new(
      Keyword.merge(
        [
          token: @token,
          base_url: "https://gateway.test",
          req_options: [plug: {Req.Test, @stub}],
          sleep: fn ms -> send(test, {:slept, ms}) end
        ],
        opts
      )
    )
  end

  defp reply(body, status \\ 200, headers \\ []) do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, raw})

      conn =
        Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp sequence(responses) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> responses end)

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, raw})
      {status, body, headers} = Agent.get_and_update(agent, fn [h | t] -> {h, t ++ [h]} end)

      conn =
        Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp header(conn, name), do: Plug.Conn.get_req_header(conn, name)

  describe "client setup" do
    test "strips trailing slashes from the base URL" do
      assert Looot.new(base_url: "https://x.test///", token: "t").base_url == "https://x.test"
    end

    test "defaults to the production URL" do
      assert Looot.new(token: "t").base_url == "https://api.looot.ai"
      assert Looot.default_base_url() == "https://api.looot.ai"
    end

    test "inspect hides the token" do
      refute inspect(client()) =~ @token
    end

    test "user agent names the SDK and the runtime" do
      assert client().user_agent == "looot-elixir/#{Looot.version()} elixir/#{System.version()}"
    end
  end

  describe "headers" do
    test "token route sends bearer, accept and user agent, and no content type on a GET" do
      reply(%{"ok" => true})
      assert {:ok, %{"ok" => true}} = Looot.balance(client())
      assert_receive {:request, conn, ""}
      assert header(conn, "authorization") == ["Bearer " <> @token]
      assert header(conn, "accept") == ["application/json"]
      assert header(conn, "user-agent") == [client().user_agent]
      assert header(conn, "content-type") == []
      assert header(conn, "x-looot-agent") == []
      assert conn.method == "GET"
      assert conn.request_path == "/v1/balance"
    end

    test "agent option sends X-Looot-Agent cut to 64 characters" do
      reply(%{})
      {:ok, _} = Looot.balance(client(agent: String.duplicate("a", 100)))
      assert_receive {:request, conn, _}
      assert header(conn, "x-looot-agent") == [String.duplicate("a", 64)]
    end

    test "POST sends a JSON content type" do
      reply(%{"runId" => "run_1"})
      {:ok, _} = Looot.run(client(), "ep", %{})
      assert_receive {:request, conn, _}
      assert header(conn, "content-type") == ["application/json"]
    end
  end

  describe "free routes" do
    test "overview sends the topic and no Authorization" do
      reply(%{"jobs" => []})
      assert {:ok, _} = Looot.catalog_overview(client(), topic: "email")
      assert_receive {:request, conn, _}
      assert conn.request_path == "/v1/catalog/overview"
      assert conn.query_string == "topic=email"
      assert header(conn, "authorization") == []
    end

    test "public catalog and item send no Authorization" do
      reply(%{"items" => []})

      {:ok, _} =
        Looot.public_catalog(client(),
          capability: "people_email_verify",
          limit: 1,
          operation_id: "op"
        )

      assert_receive {:request, conn, _}
      assert conn.request_path == "/v1/public-catalog"

      assert URI.decode_query(conn.query_string) == %{
               "capability" => "people_email_verify",
               "limit" => "1",
               "operationId" => "op"
             }

      assert header(conn, "authorization") == []

      {:ok, _} = Looot.public_catalog_item(client(), "icypeas-email-verify")
      assert_receive {:request, conn, _}
      assert conn.request_path == "/v1/public-catalog/icypeas-email-verify"
      assert header(conn, "authorization") == []
    end

    test "compare posts catalogItemIds without Authorization" do
      reply(%{"items" => []})
      {:ok, _} = Looot.compare_public_catalog(client(), ["a", "b"])
      assert_receive {:request, conn, raw}
      assert conn.method == "POST"
      assert conn.request_path == "/v1/public-catalog/compare"
      assert Jason.decode!(raw) == %{"catalogItemIds" => ["a", "b"]}
      assert header(conn, "authorization") == []
    end

    test "free routes work with no token" do
      reply(%{})
      assert {:ok, _} = Looot.catalog_overview(client(token: ""))
      assert_receive {:request, _, _}
    end
  end

  describe "missing token" do
    test "raises missing_token and sends nothing" do
      reply(%{})
      assert {:error, %Looot.Error{} = e} = Looot.balance(client(token: ""))
      assert e.status == 401
      assert e.code == "missing_token"
      assert e.message == "GET /v1/balance needs a token: set LOOOT_TOKEN or pass token:"
      refute_received {:request, _, _}
    end

    test "every token route refuses locally" do
      c = client(token: "")
      reply(%{})

      for result <- [
            Looot.search(c, q: "x"),
            Looot.inspect_endpoint(c, "e"),
            Looot.run(c, "e", %{}),
            Looot.run_job(c, "people.email.find", %{}),
            Looot.get_run(c, "r"),
            Looot.list_runs(c),
            Looot.cancel_run(c, "r"),
            Looot.run_attempts(c, "r"),
            Looot.balance(c),
            Looot.discover(c),
            Looot.whoami(c),
            Looot.ledger(c),
            Looot.list_top_ups(c),
            Looot.catalog_endpoints(c),
            Looot.capability_request(c, title: "t"),
            Looot.download_media(c, "/v1/media/x")
          ] do
        assert {:error, %Looot.Error{code: "missing_token", status: 401}} = result
      end

      refute_received {:request, _, _}
    end

    test "reads LOOOT_TOKEN, trimmed, when no token option is given" do
      old = System.get_env("LOOOT_TOKEN")
      System.put_env("LOOOT_TOKEN", "  env-token-not-real \n")

      on_exit(fn ->
        if old, do: System.put_env("LOOOT_TOKEN", old), else: System.delete_env("LOOOT_TOKEN")
      end)

      assert Looot.new().token == "env-token-not-real"
      assert Looot.new(token: nil).token == "env-token-not-real"
      assert Looot.new(token: "").token == nil
      assert Looot.new(token: "  ").token == nil
      assert Looot.new(token: "mine").token == "mine"
    end
  end

  describe "search and query building" do
    test "maps prefer, max_price_micros and keyless, and drops unset params" do
      reply(%{"endpoints" => []})

      {:ok, _} =
        Looot.search(client(),
          q: "verify an email",
          prefer: :cheapest,
          max_price_micros: 5000,
          keyless: true,
          verified: false,
          limit: nil,
          category: ""
        )

      assert_receive {:request, conn, _}
      assert conn.request_path == "/v1/catalog/search"
      assert header(conn, "authorization") == ["Bearer " <> @token]

      assert URI.decode_query(conn.query_string) == %{
               "q" => "verify an email",
               "prefer" => "cheapest",
               "maxPriceMicros" => "5000",
               "keyless" => "true",
               "verified" => "false"
             }
    end

    test "an unknown option raises" do
      assert_raise ArgumentError, fn -> Looot.search(client(), nope: 1) end
    end

    test "discover, endpoints, runs and ledger use the right routes and names" do
      reply(%{})

      {:ok, _} =
        Looot.discover(client(),
          query: "x",
          result_limit: 3,
          max_price: 0.5,
          include_unavailable: true
        )

      assert_receive {:request, conn, _}
      assert conn.request_path == "/v1/discover"

      assert URI.decode_query(conn.query_string) == %{
               "query" => "x",
               "resultLimit" => "3",
               "maxPrice" => "0.5",
               "includeUnavailable" => "true"
             }

      {:ok, _} = Looot.catalog_endpoints(client(), facets: true, limit: 10, cursor: "c")
      assert_receive {:request, conn, _}
      assert conn.request_path == "/v1/catalog/endpoints"

      assert URI.decode_query(conn.query_string) == %{
               "facets" => "true",
               "limit" => "10",
               "cursor" => "c"
             }

      {:ok, _} = Looot.list_runs(client(), status: "completed", include_result: true)
      assert_receive {:request, conn, _}
      assert conn.request_path == "/v1/runs"

      assert URI.decode_query(conn.query_string) == %{
               "status" => "completed",
               "includeResult" => "true"
             }

      {:ok, _} = Looot.ledger(client(), limit: 5)
      assert_receive {:request, conn, _}
      assert conn.request_path == "/v1/ledger"
      assert conn.query_string == "limit=5"
    end

    test "get_run sends fields joined and max_items" do
      reply(%{})
      {:ok, _} = Looot.get_run(client(), "run_1", fields: ["result.a", "result.b"], max_items: 10)
      assert_receive {:request, conn, _}

      assert URI.decode_query(conn.query_string) == %{
               "fields" => "result.a,result.b",
               "max_items" => "10"
             }
    end
  end

  describe "routes" do
    test "simple GET routes" do
      reply(%{})

      for {fun, path} <- [
            {&Looot.balance/1, "/v1/balance"},
            {&Looot.whoami/1, "/v1/whoami"},
            {&Looot.list_top_ups/1, "/v1/top-ups"}
          ] do
        assert {:ok, _} = fun.(client())
        assert_receive {:request, conn, _}
        assert conn.method == "GET"
        assert conn.request_path == path
      end
    end

    test "inspect, get_run, attempts and cancel" do
      reply(%{})
      {:ok, _} = Looot.inspect_endpoint(client(), "icypeas-email-verify")
      assert_receive {:request, conn, _}
      assert {conn.method, conn.request_path} == {"GET", "/v1/operations/icypeas-email-verify"}

      {:ok, _} = Looot.get_run(client(), "run_1")
      assert_receive {:request, conn, _}
      assert {conn.method, conn.request_path} == {"GET", "/v1/runs/run_1"}

      {:ok, _} = Looot.run_attempts(client(), "run_1")
      assert_receive {:request, conn, _}
      assert {conn.method, conn.request_path} == {"GET", "/v1/runs/run_1/attempts"}

      {:ok, _} = Looot.cancel_run(client(), "run_1")
      assert_receive {:request, conn, raw}
      assert {conn.method, conn.request_path} == {"POST", "/v1/runs/run_1/cancel"}
      assert raw == ""
      assert header(conn, "content-type") == []
    end

    test "path segments are encoded as one segment" do
      reply(%{})
      {:ok, _} = Looot.get_run(client(), "a/b")
      assert_receive {:request, conn, _}
      assert conn.request_path == "/v1/runs/a%2Fb"

      {:ok, _} = Looot.inspect_endpoint(client(), "job:people.email.find")
      assert_receive {:request, conn, _}
      assert conn.request_path == "/v1/operations/job%3Apeople.email.find"

      {:ok, _} = Looot.public_catalog_item(client(), "../x y")
      assert_receive {:request, conn, _}
      assert conn.request_path == "/v1/public-catalog/..%2Fx%20y"
    end

    test "capability_request posts the body with generated ids" do
      reply(%{"ok" => true})
      {:ok, _} = Looot.capability_request(client(), title: "Add X", desired_inputs: ["domain"])
      assert_receive {:request, conn, raw}
      assert {conn.method, conn.request_path} == {"POST", "/v1/capability-requests"}
      body = Jason.decode!(raw)
      assert body["title"] == "Add X"
      assert body["desiredInputs"] == ["domain"]
      assert "sdk-" <> _ = body["requestId"]
      assert "sdk-" <> _ = body["idempotencyKey"]
    end

    test "download_media fetches a gateway path and refuses other hosts" do
      Req.Test.stub(@stub, fn conn ->
        send(self(), {:request, conn})
        Plug.Conn.send_resp(conn, 200, <<1, 2, 3>>)
      end)

      assert {:ok, %{body: <<1, 2, 3>>}} = Looot.download_media(client(), "/v1/media/m1?sig=abc")
      assert_receive {:request, conn}
      assert conn.request_path == "/v1/media/m1"
      assert conn.query_string == "sig=abc"
      assert header(conn, "authorization") == ["Bearer " <> @token]

      assert {:error, %Looot.Error{code: "invalid_download_path"}} =
               Looot.download_media(client(), "https://evil.test/x")

      assert {:error, %Looot.Error{code: "invalid_download_path"}} =
               Looot.download_media(client(), "//evil.test/x")
    end
  end

  describe "run and run_job" do
    test "run keeps an explicit fallback map and generates an sdk- key" do
      reply(%{"runId" => "run_1", "status" => "queued"})

      {:ok, _} =
        Looot.run(client(), "icypeas-email-verify", %{"email" => "jane@example.com"},
          fallback: %{max_attempts: 2, max_cost_usd: 0.05},
          wait: 20
        )

      assert_receive {:request, conn, raw}
      assert {conn.method, conn.request_path} == {"POST", "/v1/runs"}
      assert conn.query_string == "wait=20"
      body = Jason.decode!(raw)
      assert body["endpointId"] == "icypeas-email-verify"
      assert body["input"] == %{"email" => "jane@example.com"}
      assert body["fallback"] == %{"maxAttempts" => 2, "maxCostUsd" => 0.05}

      assert body["idempotencyKey"] =~
               ~r/^sdk-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

      assert header(conn, "idempotency-key") == [body["idempotencyKey"]]
      refute Map.has_key?(body, "wait")
    end

    test "run uses the caller's idempotency key and sends no wait when unset" do
      reply(%{})
      {:ok, _} = Looot.run(client(), "e", %{}, idempotency_key: "lead-1-email")
      assert_receive {:request, conn, raw}
      assert conn.query_string == ""
      assert Jason.decode!(raw)["idempotencyKey"] == "lead-1-email"
      assert header(conn, "idempotency-key") == ["lead-1-email"]
    end

    test "run with wait: true" do
      reply(%{})
      {:ok, _} = Looot.run(client(), "e", %{}, wait: true)
      assert_receive {:request, conn, _}
      assert conn.query_string == "wait=true"
    end

    test "run_job posts job:<id>, wait in the query, prefer merged into fallback" do
      reply(%{"runId" => "run_1"})

      {:ok, _} =
        Looot.run_job(client(), "people.email.verify", %{"email" => "jane@example.com"},
          prefer: :cheapest,
          wait: 20
        )

      assert_receive {:request, conn, raw}
      assert conn.query_string == "wait=20"
      body = Jason.decode!(raw)
      assert body["endpointId"] == "job:people.email.verify"
      assert body["fallback"] == %{"prefer" => "cheapest"}
      refute Map.has_key?(body, "prefer")

      {:ok, _} =
        Looot.run_job(client(), "people.email.verify", %{},
          prefer: "fastest",
          fallback: %{max_attempts: 2}
        )

      assert_receive {:request, _, raw}
      assert Jason.decode!(raw)["fallback"] == %{"maxAttempts" => 2, "prefer" => "fastest"}

      {:ok, _} =
        Looot.run_job(client(), "people.email.verify", %{}, prefer: :cheapest, fallback: true)

      assert_receive {:request, _, raw}
      assert Jason.decode!(raw)["fallback"] == %{"prefer" => "cheapest"}
    end

    test "run_job without prefer or fallback sends no fallback key" do
      reply(%{})

      {:ok, _} =
        Looot.run_job(client(), "people.email.find", %{"domain" => "example.com"},
          output: %{"x" => 1}
        )

      assert_receive {:request, _, raw}
      body = Jason.decode!(raw)
      refute Map.has_key?(body, "fallback")
      assert body["output"] == %{"x" => 1}
    end

    test "a 201 failed run comes back as a run, not an error" do
      failed = %{
        "runId" => "run_1",
        "status" => "failed",
        "error" => %{"code" => "validation_error", "message" => "bad", "retryable" => false}
      }

      reply(failed, 201)
      assert {:ok, run} = Looot.run(client(), "e", %{})
      assert run["status"] == "failed"
      refute Looot.Run.succeeded?(run)
      assert Looot.Run.terminal?(run)
      assert {:error, %Looot.Error{code: "validation_error"}} = Looot.Run.raise_for_status(run)
    end

    test "unknown response keys are kept" do
      reply(%{"runId" => "run_1", "status" => "new_status", "brandNewField" => %{"a" => 1}})
      assert {:ok, %{"brandNewField" => %{"a" => 1}} = run} = Looot.get_run(client(), "run_1")
      refute Looot.Run.terminal?(run)
    end
  end

  describe "errors" do
    test "a 402 becomes a LoootError with status, code, request id and top-up link" do
      body = %{
        "error" => %{
          "code" => "insufficient_balance",
          "message" => "Add credit.",
          "requestId" => "req_1"
        },
        "topUp" => %{"checkoutUrl" => nil, "dashboardUrl" => "https://looot.ai/usage?top_up=1"}
      }

      reply(body, 402)
      assert {:error, %Looot.Error{} = e} = Looot.run(client(), "e", %{})
      assert e.status == 402
      assert e.code == "insufficient_balance"
      assert e.message == "Add credit."
      assert e.request_id == "req_1"
      assert e.retryable == false
      assert e.body == body
      assert Looot.Error.top_up_url(e) == "https://looot.ai/usage?top_up=1"

      assert Exception.message(e) ==
               "looot: Add credit. (insufficient_balance, HTTP 402, request req_1)"

      refute Exception.message(e) =~ @token
      assert_received {:request, _, _}
      refute_received {:request, _, _}
    end

    test "falls back to http_<status> and the x-request-id header for a non-JSON body" do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-request-id", "req_h")
        |> Plug.Conn.send_resp(502, "<html>bad gateway</html>")
      end)

      assert {:error, %Looot.Error{} = e} = Looot.balance(client(max_retries: 0))
      assert e.status == 502
      assert e.code == "http_502"
      assert e.message == "GET /v1/balance failed with HTTP 502"
      assert e.request_id == "req_h"
      assert e.body == "<html>bad gateway</html>"
      assert e.retryable == false
    end

    test "retryable comes from the table and from error.retryable when present" do
      for {status, code, expected} <- [
            {429, "run_rate_limited", true},
            {500, "internal_error", true},
            {503, "storage_busy", true},
            {503, "billing_unavailable", false},
            {400, "validation_error", false},
            {404, "not_found", false},
            {409, "idempotency_conflict", false}
          ] do
        reply(%{"error" => %{"code" => code, "message" => "m"}}, status)
        {:error, e} = Looot.balance(client(max_retries: 0))
        assert e.retryable == expected, "#{status} #{code}"
      end

      reply(
        %{"error" => %{"code" => "validation_error", "message" => "m", "retryable" => true}},
        400
      )

      {:error, e} = Looot.balance(client(max_retries: 0))
      assert e.retryable == true
    end

    test "reads retry-after from the body, then the header" do
      reply(
        %{
          "error" => %{"code" => "run_rate_limited", "message" => "slow"},
          "retryAfterSeconds" => 7
        },
        429,
        [{"retry-after", "3"}]
      )

      {:error, e} = Looot.balance(client(max_retries: 0))
      assert e.retry_after_seconds == 7

      reply(%{"error" => %{"code" => "run_rate_limited", "message" => "slow"}}, 429, [
        {"retry-after", "3"}
      ])

      {:error, e} = Looot.balance(client(max_retries: 0))
      assert e.retry_after_seconds == 3.0
    end

    test "a 2xx body that is not JSON is invalid_response" do
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 200, "not json") end)

      assert {:error, %Looot.Error{code: "invalid_response", status: 200}} =
               Looot.balance(client())
    end

    test "transport failures become status 0 errors" do
      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %Looot.Error{status: 0, code: "timeout", retryable: true}} =
               Looot.balance(client(max_retries: 0))

      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Looot.Error{status: 0, code: "network_error", retryable: true}} =
               Looot.balance(client(max_retries: 0))
    end

    test "bang variants return the value or raise" do
      reply(%{"available" => 1.5})
      assert Looot.balance!(client()) == %{"available" => 1.5}

      reply(%{"error" => %{"code" => "forbidden", "message" => "no scope"}}, 403)
      assert_raise Looot.Error, ~r/no scope/, fn -> Looot.balance!(client()) end
    end
  end

  describe "retries" do
    test "retries a 429 with the same idempotency key and waits retry-after" do
      sequence([
        {429, %{"error" => %{"code" => "run_rate_limited", "message" => "slow"}},
         [{"retry-after", "2"}]},
        {200, %{"runId" => "run_1", "status" => "queued"}, []}
      ])

      assert {:ok, %{"runId" => "run_1"}} = Looot.run(client(), "e", %{"a" => 1})
      assert_receive {:request, c1, raw1}
      assert_receive {:request, c2, raw2}
      refute_received {:request, _, _}
      assert raw1 == raw2
      assert header(c1, "idempotency-key") == header(c2, "idempotency-key")
      assert Jason.decode!(raw1)["idempotencyKey"] == Jason.decode!(raw2)["idempotencyKey"]
      assert_receive {:slept, 2000}
    end

    test "retries a retryable 503 and a transport error, at most 2 times" do
      sequence([{503, %{"error" => %{"code" => "storage_busy", "message" => "busy"}}, []}])
      assert {:error, %Looot.Error{status: 503}} = Looot.balance(client())
      assert_received {:request, _, _}
      assert_received {:request, _, _}
      assert_received {:request, _, _}
      refute_received {:request, _, _}
      assert_received {:slept, _}
      assert_received {:slept, _}
      refute_received {:slept, _}

      n = :counters.new(1, [])

      Req.Test.stub(@stub, fn conn ->
        :counters.add(n, 1, 1)

        if :counters.get(n, 1) == 1 do
          Req.Test.transport_error(conn, :econnrefused)
        else
          Req.Test.json(conn, %{"available" => 2})
        end
      end)

      assert {:ok, %{"available" => 2}} = Looot.balance(client())
    end

    test "max_retries: 0 turns retries off" do
      sequence([{429, %{"error" => %{"code" => "run_rate_limited", "message" => "slow"}}, []}])
      assert {:error, %Looot.Error{status: 429}} = Looot.balance(client(max_retries: 0))
      assert_received {:request, _, _}
      refute_received {:request, _, _}
      refute_received {:slept, _}
    end

    test "does not retry non-retryable errors" do
      for {status, code} <- [
            {400, "validation_error"},
            {401, "unauthorized"},
            {402, "insufficient_balance"},
            {403, "forbidden"},
            {404, "not_found"},
            {409, "idempotency_conflict"},
            {422, "rows_mode_unsupported"},
            {503, "billing_unavailable"}
          ] do
        sequence([{status, %{"error" => %{"code" => code, "message" => "m"}}, []}])
        assert {:error, %Looot.Error{status: ^status}} = Looot.run(client(), "e", %{})
        assert_received {:request, _, _}
        refute_received {:request, _, _}, "#{status} #{code} was retried"
        refute_received {:slept, _}
      end
    end

    test "does not retry a 500" do
      sequence([{500, %{"error" => %{"code" => "internal_error", "message" => "boom"}}, []}])
      assert {:error, %Looot.Error{status: 500, retryable: true}} = Looot.balance(client())
      assert_received {:request, _, _}
      refute_received {:request, _, _}
    end

    test "caps the retry wait at 30 seconds" do
      sequence([
        {429,
         %{
           "error" => %{"code" => "run_rate_limited", "message" => "slow"},
           "retryAfterSeconds" => 120
         }, []},
        {200, %{}, []}
      ])

      assert {:ok, _} = Looot.balance(client())
      assert_receive {:slept, 30_000}
    end
  end

  describe "helpers" do
    test "wait_for_run polls until a terminal status" do
      sequence([
        {200, %{"runId" => "r", "status" => "queued"}, []},
        {200, %{"runId" => "r", "status" => "running"}, []},
        {200, %{"runId" => "r", "status" => "completed"}, []}
      ])

      assert {:ok, %{"status" => "completed"}} = Looot.wait_for_run(client(), "r")
      assert_received {:slept, 1000}
      assert_received {:slept, 2000}
    end

    test "wait_for_run times out" do
      sequence([{200, %{"runId" => "r", "status" => "running"}, []}])

      assert {:error, %Looot.Error{code: "timeout"}} =
               Looot.wait_for_run(client(), "r", timeout: 0)
    end

    test "stream_runs follows nextCursor until null" do
      test = self()
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(@stub, fn conn ->
        send(test, {:query, conn.query_string})

        case Agent.get_and_update(agent, &{&1, &1 + 1}) do
          0 ->
            Req.Test.json(conn, %{
              "runs" => [%{"runId" => "a"}, %{"runId" => "b"}],
              "nextCursor" => "c1"
            })

          _ ->
            Req.Test.json(conn, %{"runs" => [%{"runId" => "c"}], "nextCursor" => nil})
        end
      end)

      ids = client() |> Looot.stream_runs(limit: 2) |> Enum.map(& &1["runId"])
      assert ids == ["a", "b", "c"]
      assert_received {:query, "limit=2"}
      assert_received {:query, q}
      assert URI.decode_query(q) == %{"limit" => "2", "cursor" => "c1"}
    end
  end
end
