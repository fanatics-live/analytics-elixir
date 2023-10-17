defmodule Segment.HTTP.Stub do
  @moduledoc """
  The `Segment.HTTP.Stub` is used to replace the Tesla adapter with something that logs and returns success. It is used if `send_to_http` has been set to false
  """
  require Logger

  def call(env, _opts) do
    Logger.debug("[Segment] HTTP API called with #{inspect(env)}")
    {:ok, %{env | status: 200, body: ""}}
  end
end
