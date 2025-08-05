defmodule StackCoinWeb.Router do
  use StackCoinWeb, :router

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
  end

  scope "/", StackCoinWeb do
    pipe_through(:browser)

    get("/", PageController, :home)
  end

  # Bot API routes
  scope "/api/bot", StackCoinWeb do
    pipe_through([:api, StackCoinWeb.Plugs.BotAuth])

    get("/self/balance", BotApiController, :balance)
    get("/user/:user_id/balance", BotApiController, :user_balance)
    post("/user/:user_id/send", BotApiController, :send_tokens)

    post("/user/:user_id/request", BotApiController, :create_request)
    get("/requests", BotApiController, :get_requests)
    post("/requests/:request_id/accept", BotApiController, :accept_request)
    post("/requests/:request_id/deny", BotApiController, :deny_request)

    get("/transactions", BotApiController, :get_transactions)
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
