defmodule StackCoinWeb.GraphController do
  use StackCoinWeb, :controller

  alias StackCoin.GraphCache

  def show(conn, %{"user_id" => user_id}) do
    user_id = String.to_integer(user_id)

    case GraphCache.get_graph_png(user_id) do
      {:ok, png} ->
        conn
        |> put_resp_content_type("image/png")
        |> put_resp_header("cache-control", "public, max-age=300")
        |> send_resp(200, png)

      {:error, :no_transactions} ->
        conn
        |> send_resp(404, "No transactions")

      {:error, _} ->
        conn
        |> send_resp(500, "Error generating graph")
    end
  end
end
