defmodule StackCoin.MixProject do
  use Mix.Project

  def project do
    [
      app: :stackcoin,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["test/support", "lib"]
  defp elixirc_paths(_), do: ["lib"]

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
      {:vega_lite_convert, "~> 1.0"},
      {:mock, "~> 0.3.0", only: :test}
    ]
  end
end
