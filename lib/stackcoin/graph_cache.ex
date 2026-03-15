defmodule StackCoin.GraphCache do
  @moduledoc """
  Disk-based cache for user balance graphs.
  Cached PNGs are stored in /tmp/stackcoin/graphs/ and keyed by
  {user_id, last_transaction_id} so they stay valid until a new
  transaction involving that user occurs.
  """

  alias StackCoin.Core.{Bank, User}
  alias StackCoin.Graph

  @cache_dir "/tmp/stackcoin/graphs"

  @doc """
  Returns the cached PNG binary for a user's balance graph,
  generating it if the cache is stale or missing.
  """
  def get_graph_png(user_id) do
    with {:ok, last_tx_id} <- get_last_transaction_id(user_id),
         cache_path = cache_path(user_id, last_tx_id),
         {:ok, png} <- read_cached(cache_path) do
      {:ok, png}
    else
      {:miss, cache_path} ->
        generate_and_cache(user_id, cache_path)

      {:error, :no_transactions} ->
        {:error, :no_transactions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_last_transaction_id(user_id) do
    case Bank.search_transactions(includes_user_id: user_id, limit: 1) do
      {:ok, %{transactions: [tx | _]}} -> {:ok, tx.id}
      {:ok, %{transactions: []}} -> {:error, :no_transactions}
      error -> error
    end
  end

  defp cache_path(user_id, tx_id) do
    Path.join(@cache_dir, "#{user_id}_#{tx_id}.png")
  end

  defp read_cached(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:miss, path}
    end
  end

  defp generate_and_cache(user_id, cache_path) do
    with {:ok, user} <- User.get_user_by_id(user_id),
         {:ok, history} <- Bank.get_user_balance_history(user_id),
         png <- Graph.generate_balance_chart(history, user.username) do
      File.mkdir_p!(Path.dirname(cache_path))
      cleanup_old_files(user_id)
      File.write!(cache_path, png)
      {:ok, png}
    end
  end

  defp cleanup_old_files(user_id) do
    glob = Path.join(@cache_dir, "#{user_id}_*.png")

    for path <- Path.wildcard(glob) do
      File.rm(path)
    end
  end
end
