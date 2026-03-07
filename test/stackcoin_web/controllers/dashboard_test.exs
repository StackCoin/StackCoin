defmodule StackCoinWeb.DashboardTest do
  use StackCoinWeb.ConnCase

  @dashboard_path "/dev/dashboard"

  describe "dashboard basic auth" do
    test "returns 403 when no credentials are configured", %{conn: conn} do
      # Test env: no dashboard_password, no dev_routes — should block
      Application.delete_env(:stackcoin, :dashboard_password)
      Application.delete_env(:stackcoin, :dev_routes)

      conn = get(conn, @dashboard_path)

      assert conn.status == 403
      assert conn.resp_body == "Dashboard credentials not configured"
    end

    test "returns 401 when credentials are configured but not provided", %{conn: conn} do
      Application.put_env(:stackcoin, :dashboard_username, "admin")
      Application.put_env(:stackcoin, :dashboard_password, "secret123")

      conn = get(conn, @dashboard_path)

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") != []
    after
      Application.delete_env(:stackcoin, :dashboard_password)
      Application.delete_env(:stackcoin, :dashboard_username)
    end

    test "returns 401 when wrong credentials are provided", %{conn: conn} do
      Application.put_env(:stackcoin, :dashboard_username, "admin")
      Application.put_env(:stackcoin, :dashboard_password, "secret123")

      conn =
        conn
        |> put_req_header("authorization", basic_auth("admin", "wrongpassword"))
        |> get(@dashboard_path)

      assert conn.status == 401
    after
      Application.delete_env(:stackcoin, :dashboard_password)
      Application.delete_env(:stackcoin, :dashboard_username)
    end

    test "allows access with correct credentials", %{conn: conn} do
      Application.put_env(:stackcoin, :dashboard_username, "admin")
      Application.put_env(:stackcoin, :dashboard_password, "secret123")

      conn =
        conn
        |> put_req_header("authorization", basic_auth("admin", "secret123"))
        |> get(@dashboard_path)

      # LiveDashboard redirects to /dev/dashboard/home on success
      assert conn.status in [200, 302]

      if conn.status == 302 do
        assert get_resp_header(conn, "location") |> hd() =~ "/dev/dashboard"
      end
    after
      Application.delete_env(:stackcoin, :dashboard_password)
      Application.delete_env(:stackcoin, :dashboard_username)
    end

    test "allows access without credentials when dev_routes is true", %{conn: conn} do
      Application.delete_env(:stackcoin, :dashboard_password)
      Application.put_env(:stackcoin, :dev_routes, true)

      conn = get(conn, @dashboard_path)

      # Should not be blocked — either serves dashboard or redirects to it
      assert conn.status in [200, 302]
      refute conn.status == 401
      refute conn.status == 403
    after
      Application.delete_env(:stackcoin, :dev_routes)
    end

    test "uses custom username from config", %{conn: conn} do
      Application.put_env(:stackcoin, :dashboard_username, "operator")
      Application.put_env(:stackcoin, :dashboard_password, "letmein")

      # Wrong username, right password
      conn_bad =
        conn
        |> put_req_header("authorization", basic_auth("admin", "letmein"))
        |> get(@dashboard_path)

      assert conn_bad.status == 401

      # Right username, right password
      conn_good =
        build_conn()
        |> put_req_header("authorization", basic_auth("operator", "letmein"))
        |> get(@dashboard_path)

      assert conn_good.status in [200, 302]
    after
      Application.delete_env(:stackcoin, :dashboard_password)
      Application.delete_env(:stackcoin, :dashboard_username)
    end
  end

  defp basic_auth(username, password) do
    "Basic " <> Base.encode64("#{username}:#{password}")
  end
end
