defmodule Looot.Run do
  @moduledoc """
  Helpers for run maps.

  Runs are plain maps with string keys, exactly as the gateway sends them, so fields this
  library does not know about stay reachable. A failed run is not an error: read `"status"`,
  `"outcome"` and `"error"`.
  """

  @terminal ~w(completed failed blocked stopped reconciliation_pending)

  @doc "True when polling can stop. An unknown status counts as not terminal."
  @spec terminal?(map()) :: boolean()
  def terminal?(%{"status" => status}), do: status in @terminal
  def terminal?(_), do: false

  @doc "True when the run completed and carries no error. A completed run can still be a miss."
  @spec succeeded?(map()) :: boolean()
  def succeeded?(%{"status" => "completed"} = run), do: is_nil(run["error"])
  def succeeded?(_), do: false

  @doc """
  Turns a failed run into `{:error, %Looot.Error{}}` built from its `"error"` object.
  Any other run comes back as `{:ok, run}`.
  """
  @spec raise_for_status(map()) :: {:ok, map()} | {:error, Looot.Error.t()}
  def raise_for_status(%{"status" => status, "error" => %{} = err} = run)
      when status in ["failed", "blocked"] do
    {:error,
     %Looot.Error{
       status: 200,
       code: to_string(err["code"] || "run_failed"),
       message: to_string(err["message"] || "The run failed."),
       request_id: err["requestId"],
       retryable: err["retryable"] == true,
       retry_hint: err["retryHint"],
       body: run
     }}
  end

  def raise_for_status(run), do: {:ok, run}
end
