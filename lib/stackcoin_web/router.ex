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

    # Balance operations
    get("/balance", StackCoinWeb.BalanceController, :self_balance)
    get("/users/:user_id/balance", StackCoinWeb.BalanceController, :user_balance)

    # Transfer operations
    post("/users/:user_id/send", StackCoinWeb.TransferController, :send_stk)

    # Request operations
    post("/users/:user_id/request", StackCoinWeb.RequestController, :create)
    get("/requests", StackCoinWeb.RequestController, :index)
    post("/requests/:request_id/accept", StackCoinWeb.RequestController, :accept)
    post("/requests/:request_id/deny", StackCoinWeb.RequestController, :deny)

    # Transaction operations
    get("/transactions", StackCoinWeb.TransactionController, :index)

    # User operations
    get("/users", StackCoinWeb.UserController, :index)

    # Discord guild operations
    get("/discord/guilds", StackCoinWeb.DiscordGuildController, :index)
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:stackcoin, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: StackCoinWeb.Telemetry)
    end
  end
end
