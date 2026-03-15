defmodule StackCoin.NetworkCache do
  @moduledoc """
  Disk-based cache for the transaction network graph data.
  Keyed on the latest transaction ID so it stays valid until a new transaction occurs.
  """

  alias StackCoin.Core.Bank
  alias StackCoin.Repo
  alias StackCoin.Schema
  import Ecto.Query

  @cache_dir "/tmp/stackcoin/network"

  def get_network_json do
    with {:ok, last_tx_id} <- get_last_transaction_id(),
         cache_path = cache_path(last_tx_id),
         {:ok, json} <- read_cached(cache_path) do
      {:ok, json}
    else
      {:miss, cache_path} ->
        generate_and_cache(cache_path)

      {:error, :no_transactions} ->
        {:ok, Jason.encode!(%{nodes: [], links: []})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_last_transaction_id do
    case Repo.one(from(t in Schema.Transaction, select: max(t.id))) do
      nil -> {:error, :no_transactions}
      id -> {:ok, id}
    end
  end

  defp cache_path(tx_id) do
    Path.join(@cache_dir, "network_#{tx_id}.json")
  end

  defp read_cached(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:miss, path}
    end
  end

  defp generate_and_cache(cache_path) do
    with {:ok, %{nodes: nodes, links: links}} <- Bank.get_transaction_network() do
      json = Jason.encode!(%{nodes: nodes, links: links})
      File.mkdir_p!(Path.dirname(cache_path))
      cleanup_old_files()
      File.write!(cache_path, json)
      {:ok, json}
    end
  end

  defp cleanup_old_files do
    glob = Path.join(@cache_dir, "network_*.json")

    for path <- Path.wildcard(glob) do
      File.rm(path)
    end
  end
end
