defmodule StackCoinWeb.HealthControllerTest do
  use StackCoinWeb.ConnCase

  @health_path "/health"

  test "returns 200 without authentication", %{conn: conn} do
    conn = get(conn, @health_path)
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
  end
end