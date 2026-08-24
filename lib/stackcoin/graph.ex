defmodule StackCoin.Graph do
  @moduledoc """
  Graph generation utilities using VegaLite.
  """

  alias VegaLite, as: Vl

  @max_chart_points 900

  @doc """
  Generates a balance over time chart for a user.
  Takes a list of {timestamp, balance} tuples and returns a PNG binary.

  The chart uses a step style: horizontal holds at each balance level
  with vertical jumps at transaction times. Segments are colored
  green (balance went up), red (balance went down), or grey (unchanged).
  """
  def generate_balance_chart(balance_history, username, opts \\ []) do
    max_points = Keyword.get(opts, :max_points, @max_chart_points)
    balance_history = downsample_balance_history(balance_history, max_points)
    segments = build_segments(balance_history)
    zoomed = Keyword.get(opts, :zoomed, false)

    y_opts =
      if zoomed do
        balances = Enum.map(segments, & &1["balance"])
        min_bal = Enum.min(balances, fn -> 0 end)
        max_bal = Enum.max(balances, fn -> 0 end)
        range = max(max_bal - min_bal, 1)
        pad = round(range * 0.1)

        [
          type: :quantitative,
          title: "Balance (STK)",
          axis: [grid: true],
          scale: [domain: [max(min_bal - pad, 0), max_bal + pad]]
        ]
      else
        [type: :quantitative, title: "Balance (STK)", axis: [grid: true]]
      end

    vl =
      Vl.new(
        width: 900,
        height: 400,
        title: "#{username}'s Balance Over Time",
        config: [view: [stroke: nil]]
      )
      |> Vl.data_from_values(segments)
      |> Vl.mark(:line, stroke_width: 2)
      |> Vl.encode_field(:x, "time",
        type: :temporal,
        title: "Time",
        axis: [grid: false]
      )
      |> Vl.encode_field(:y, "balance", y_opts)
      |> Vl.encode_field(:color, "direction",
        type: :nominal,
        scale: [
          domain: ["up", "down", "flat"],
          range: ["#26a641", "#da3633", "#8b949e"]
        ],
        legend: nil
      )
      |> Vl.encode_field(:detail, "segment_id", type: :nominal)
      |> Vl.encode(:tooltip, [
        [field: "balance", type: :quantitative, title: "Balance"],
        [field: "label", type: :nominal, title: "Time"]
      ])

    VegaLite.Convert.to_png(vl)
  end

  @doc """
  Reduces a chronological balance history to at most `max_points` while
  preserving its endpoints and the minimum and maximum balance in each time
  bucket.

  Charts are 900 pixels wide, so retaining more than the default of 900 points
  adds renderer work without adding visible detail.
  """
  def downsample_balance_history(balance_history, max_points \\ @max_chart_points)

  def downsample_balance_history(balance_history, max_points)
      when is_list(balance_history) and is_integer(max_points) and max_points >= 4 do
    if length(balance_history) <= max_points do
      balance_history
    else
      do_downsample_balance_history(balance_history, max_points)
    end
  end

  def downsample_balance_history(_balance_history, max_points) do
    raise ArgumentError,
          "max_points must be an integer greater than or equal to 4, got: #{inspect(max_points)}"
  end

  defp do_downsample_balance_history(balance_history, max_points) do
    first = hd(balance_history)
    last = List.last(balance_history)
    middle = balance_history |> tl() |> Enum.drop(-1)
    bucket_count = div(max_points - 2, 2)
    {first_time, _balance} = first
    {last_time, _balance} = last
    duration = max(NaiveDateTime.diff(last_time, first_time, :microsecond), 1)

    selected =
      middle
      |> Enum.with_index()
      |> Enum.group_by(fn {{time, _balance}, _index} ->
        elapsed = max(NaiveDateTime.diff(time, first_time, :microsecond), 0)
        min(div(elapsed * bucket_count, duration + 1), bucket_count - 1)
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {_bucket, points} ->
        min_point = Enum.min_by(points, fn {{_time, balance}, index} -> {balance, index} end)
        max_point = Enum.max_by(points, fn {{_time, balance}, index} -> {balance, index} end)

        [min_point, max_point]
        |> Enum.uniq()
        |> Enum.sort_by(&elem(&1, 1))
        |> Enum.map(&elem(&1, 0))
      end)

    [first | selected] ++ [last]
  end

  # Expands a list of {timestamp, balance} tuples into segments suitable
  # for a step chart with per-segment color.
  #
  # Each pair of consecutive data points produces up to two segments:
  #   1. A horizontal "hold" from the previous time to the current time
  #      at the previous balance (colored by the previous direction).
  #   2. A vertical "jump" at the current time from the previous balance
  #      to the new balance (colored by the direction of this change).
  #
  # Each segment is a pair of points sharing a segment_id so VegaLite
  # draws them as connected line segments.
  defp build_segments(balance_history) do
    balance_history
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index()
    |> Enum.flat_map(fn {[{prev_time, prev_balance}, {curr_time, curr_balance}], idx} ->
      direction =
        cond do
          curr_balance > prev_balance -> "up"
          curr_balance < prev_balance -> "down"
          true -> "flat"
        end

      hold_id = "hold_#{idx}"
      jump_id = "jump_#{idx}"

      # Horizontal hold: stay at prev_balance from prev_time to curr_time
      hold_points = [
        point(prev_time, prev_balance, "flat", hold_id),
        point(curr_time, prev_balance, "flat", hold_id)
      ]

      # Vertical jump: at curr_time, go from prev_balance to curr_balance
      jump_points =
        if prev_balance != curr_balance do
          [
            point(curr_time, prev_balance, direction, jump_id),
            point(curr_time, curr_balance, direction, jump_id)
          ]
        else
          []
        end

      hold_points ++ jump_points
    end)
  end

  defp point(timestamp, balance, direction, segment_id) do
    %{
      "time" => NaiveDateTime.to_iso8601(timestamp),
      "balance" => balance,
      "direction" => direction,
      "segment_id" => segment_id,
      "label" => NaiveDateTime.to_string(timestamp)
    }
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
