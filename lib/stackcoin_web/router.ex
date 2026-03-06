defmodule StackCoinWeb.Router do
  use StackCoinWeb, :router

  @swagger_ui_config [
    path: "/api/openapi",
    display_operation_id: true
  ]

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {StackCoinWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])

    plug(OpenApiSpex.Plug.PutApiSpec, module: StackCoinWeb.ApiSpec)
  end

  scope "/" do
    pipe_through(:browser)

    get("/", StackCoinWeb.PageController, :home)

    get("/swaggerui", OpenApiSpex.Plug.SwaggerUI, @swagger_ui_config)
  end

  scope "/api" do
    pipe_through(:api)

    get("/openapi", OpenApiSpex.Plug.RenderSpec, :show)
  end

  # API routes
  scope "/api" do
    pipe_through(:api)
    pipe_through(StackCoinWeb.Plugs.BotAuth)

    # Event operations
    get("/events", StackCoinWeb.EventController, :index)

    # Request operations
    get("/requests", StackCoinWeb.RequestController, :index)
    get("/request/:request_id", StackCoinWeb.RequestController, :show)
    post("/requests/:request_id/accept", StackCoinWeb.RequestController, :accept)
    post("/requests/:request_id/deny", StackCoinWeb.RequestController, :deny)

    # Transaction operations
    get("/transactions", StackCoinWeb.TransactionController, :index)
    get("/transaction/:transaction_id", StackCoinWeb.TransactionController, :show)

    # User operations
    get("/users", StackCoinWeb.UserController, :index)
    get("/user/me", StackCoinWeb.UserController, :me)
    get("/user/:user_id", StackCoinWeb.UserController, :show)
    post("/user/:user_id/send", StackCoinWeb.TransferController, :send_stk)
    post("/user/:user_id/request", StackCoinWeb.RequestController, :create)

    # Discord guild operations
    get("/discord/guilds", StackCoinWeb.DiscordGuildController, :index)
    get("/discord/guild/:snowflake", StackCoinWeb.DiscordGuildController, :show)
  end

  # LiveDashboard — available in all environments, protected by basic auth.
  import Phoenix.LiveDashboard.Router

  pipeline :dashboard_auth do
    plug(:dashboard_basic_auth)
  end

  scope "/dev" do
    pipe_through([:browser, :dashboard_auth])

    live_dashboard("/dashboard", metrics: StackCoinWeb.Telemetry)
  end

  defp dashboard_basic_auth(conn, _opts) do
    username = Application.get_env(:stackcoin, :dashboard_username, "admin")
    password = Application.get_env(:stackcoin, :dashboard_password)

    cond do
      password ->
        Plug.BasicAuth.basic_auth(conn, username: username, password: password)

      Application.get_env(:stackcoin, :dev_routes) ->
        # Dev/test: no auth required
        conn

      true ->
        # Prod without password configured: block access
        conn
        |> Plug.Conn.send_resp(403, "Dashboard credentials not configured")
        |> Plug.Conn.halt()
    end
  end
end
