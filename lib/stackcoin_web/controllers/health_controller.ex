defmodule StackCoinWeb.HealthController do
  @moduledoc """
  Unauthenticated liveness/readiness probe.

  Returns 200 as soon as the Phoenix endpoint is accepting requests. Used by
  Docker's ``HEALTHCHECK`` and ``depends_on: condition: service_healthy`` so
  downstream services (e.g. luckypot) don't attempt to talk to StackCoin before
  its HTTP server is ready.
  """

  use StackCoinWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
