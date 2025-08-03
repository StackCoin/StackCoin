defmodule StackCoin.Graph do
  @moduledoc """
  Graph generation utilities using VegaLite.
  """

  alias VegaLite, as: Vl

  @doc """
  Generates a balance over time chart for a user.
  Takes a list of {timestamp, balance} tuples and returns a PNG binary.
  """
  def generate_balance_chart(balance_history, username) do
    # Convert data to the format VegaLite expects
    chart_data =
      balance_history
      |> Enum.map(fn {timestamp, balance} ->
        %{
          "time" => NaiveDateTime.to_iso8601(timestamp),
          "balance" => balance,
          "timestamp" => NaiveDateTime.to_string(timestamp)
        }
      end)

    vl =
      Vl.new(
        width: 900,
        height: 400,
        title: "#{username}'s Balance Over Time"
      )
      |> Vl.data_from_values(chart_data)
      |> Vl.mark(:line, point: true)
      |> Vl.encode_field(:x, "time",
        type: :temporal,
        title: "Time",
        axis: %{grid: false}
      )
      |> Vl.encode_field(:y, "balance",
        type: :quantitative,
        title: "Balance (STK)",
        axis: %{grid: true}
      )
      |> Vl.encode(:tooltip, [
        [field: "balance", type: :quantitative, title: "Balance"],
        [field: "timestamp", type: :nominal, title: "Time"]
      ])

    VegaLite.Convert.to_png(vl)
  end

  @doc """
  Generates a sample chart (for testing).
  """
  def generate_sample_chart do
    vl =
      Vl.new(width: 400, height: 400)
      |> Vl.data_from_values(iteration: 1..100, score: 1..100)
      |> Vl.mark(:line)
      |> Vl.encode_field(:x, "iteration", type: :quantitative)
      |> Vl.encode_field(:y, "score", type: :quantitative)

    VegaLite.Convert.to_png(vl)
  end
end
