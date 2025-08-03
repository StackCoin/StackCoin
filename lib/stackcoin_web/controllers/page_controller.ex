defmodule StackCoinWeb.PageController do
  use StackCoinWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
