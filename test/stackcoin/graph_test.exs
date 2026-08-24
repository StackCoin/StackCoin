defmodule StackCoin.GraphTest do
  use ExUnit.Case, async: true

  alias StackCoin.Graph

  test "leaves histories within the point limit unchanged" do
    history = history([10, 20, 30, 40])

    assert Graph.downsample_balance_history(history, 4) == history
  end

  test "bounds large histories and preserves their endpoints" do
    history = history(Enum.map(0..100, &rem(&1 * 37, 50)))

    sampled = Graph.downsample_balance_history(history, 10)

    assert length(sampled) <= 10
    assert hd(sampled) == hd(history)
    assert List.last(sampled) == List.last(history)
    assert sampled == Enum.sort_by(sampled, &elem(&1, 0), NaiveDateTime)
  end

  test "preserves bucket extrema in chronological order" do
    history = history([10, 5, 12, 1, 20, 8, 7, 11])

    assert Graph.downsample_balance_history(history, 4) ==
             Enum.map([0, 3, 4, 7], &Enum.at(history, &1))
  end

  test "handles histories whose points share a timestamp" do
    timestamp = ~N[2026-08-24 12:00:00]
    history = Enum.map([10, 5, 20, 11, 7], &{timestamp, &1})

    sampled = Graph.downsample_balance_history(history, 4)

    assert sampled == [
             Enum.at(history, 0),
             Enum.at(history, 1),
             Enum.at(history, 2),
             Enum.at(history, 4)
           ]
  end

  test "rejects limits too small to retain endpoints and extrema" do
    assert_raise ArgumentError, fn ->
      Graph.downsample_balance_history(history([1, 2, 3, 4, 5]), 3)
    end
  end

  defp history(balances) do
    balances
    |> Enum.with_index()
    |> Enum.map(fn {balance, seconds} ->
      {NaiveDateTime.add(~N[2026-08-24 12:00:00], seconds), balance}
    end)
  end
end
