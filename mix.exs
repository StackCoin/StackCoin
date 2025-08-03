defmodule StackCoin.MixProject do
  use Mix.Project

  def project do
    [
      app: :stackcoin,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {StackCoin.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.21"},
      {:nostrum, "~> 0.10"},
      {:dotenvy, "~> 1.1.0"},
      {:vega_lite, "~> 0.1.11"},
      {:vega_lite_convert, "~> 1.0"}
    ]
  end
end
