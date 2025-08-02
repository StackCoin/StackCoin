defmodule StackCoin.Repo do
  use Ecto.Repo,
    otp_app: :stackcoin,
    adapter: Ecto.Adapters.SQLite3
end
