defmodule StackCoinWeb.GraphController do
  use StackCoinWeb, :controller

  alias StackCoin.GraphCache

  @valid_ranges %{
    "1w" => 7,
    "1m" => 30,
    "3m" => 90,
    "1y" => 365
  }

  def show(conn, params) do
    user_id = String.to_integer(params["user_id"])
    range = params["range"]
    timerange_key = if range in Map.keys(@valid_ranges), do: range, else: "all"

    since =
      case Map.get(@valid_ranges, range) do
        nil -> nil
        days -> NaiveDateTime.add(NaiveDateTime.utc_now(), -days * 86400, :second)
      end

    case GraphCache.get_graph_png(user_id, timerange_key, since) do
      {:ok, png} ->
        conn
        |> put_resp_content_type("image/png")
        |> put_resp_header("cache-control", "public, immutable, max-age=31536000")
        |> send_resp(200, png)

      {:error, :no_transactions} ->
        conn |> send_resp(404, "No transactions")

      {:error, _} ->
        conn |> send_resp(500, "Error generating graph")
    end
  end
end
