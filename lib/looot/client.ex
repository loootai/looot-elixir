defmodule Looot.Client do
  @moduledoc """
  A configured looot client. Build one with `Looot.new/1`.

  The struct holds no state besides its settings, so it is safe to share between processes.
  `inspect/1` hides the token.
  """

  @derive {Inspect, except: [:token]}
  defstruct [
    :base_url,
    :token,
    :agent,
    :user_agent,
    :timeout,
    :max_retries,
    :req_options,
    :sleep,
    :new_key
  ]

  @type t :: %__MODULE__{
          base_url: String.t(),
          token: String.t() | nil,
          agent: String.t() | nil,
          user_agent: String.t(),
          timeout: pos_integer(),
          max_retries: non_neg_integer(),
          req_options: keyword(),
          sleep: (non_neg_integer() -> any()),
          new_key: (-> String.t())
        }
end
