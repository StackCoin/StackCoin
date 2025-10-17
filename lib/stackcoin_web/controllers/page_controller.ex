defmodule StackCoinWeb.PageController do
  use StackCoinWeb, :controller

  alias StackCoin.Core.Bank

  def home(conn, _params) do
    {:ok, %{transactions: transactions}} = Bank.search_transactions()

    render(conn, :home, transactions: transactions)
  end
end
