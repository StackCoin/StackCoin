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

    get("/balance", BotApiController, :balance)
    get("/balance/:user_id", BotApiController, :user_balance)
    post("/send", BotApiController, :send_tokens)
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
