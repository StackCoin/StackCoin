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
      |> Vl.transform(window: [[op: "lag", field: "balance", param: 1, as: "prev_balance"]])
      |> Vl.transform(
        calculate:
          "datum.prev_balance === null ? 'flat' : datum.balance > datum.prev_balance ? 'up' : datum.balance < datum.prev_balance ? 'down' : 'flat'",
        as: "direction"
      )
      |> Vl.mark(:trail, interpolate: "step-after")
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
      |> Vl.encode_field(:color, "direction",
        type: :nominal,
        scale: %{
          domain: ["up", "down", "flat"],
          range: ["#26a641", "#da3633", "#8b949e"]
        },
        legend: nil
      )
      |> Vl.encode(:size, value: 3)
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
