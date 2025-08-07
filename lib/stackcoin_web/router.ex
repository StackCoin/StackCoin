defmodule StackCoinWeb.Router do
  use StackCoinWeb, :router

  @swagger_ui_config [
    path: "/api/openapi"
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

  # Bot API routes
  scope "/api" do
    pipe_through(:api)

    scope "/bot" do
      pipe_through(StackCoinWeb.Plugs.BotAuth)

      get("/self/balance", StackCoinWeb.BotApiController, :balance)
      get("/user/:user_id/balance", StackCoinWeb.BotApiController, :user_balance)
      post("/user/:user_id/send", StackCoinWeb.BotApiController, :send_stk)

      post("/user/:user_id/request", StackCoinWeb.BotApiController, :create_request)
      get("/requests", StackCoinWeb.BotApiController, :get_requests)
      post("/requests/:request_id/accept", StackCoinWeb.BotApiController, :accept_request)
      post("/requests/:request_id/deny", StackCoinWeb.BotApiController, :deny_request)

      get("/transactions", StackCoinWeb.BotApiController, :get_transactions)
      get("/users", StackCoinWeb.BotApiController, :get_users)
    end

    get("/openapi", OpenApiSpex.Plug.RenderSpec, :show)
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
