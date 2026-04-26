# Graph Command Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `timerange` option to `/graph` and replace the line chart with a green/red step trail chart.

**Architecture:** Modify `Bank.get_user_balance_history/2` to accept an optional `since` cutoff. Update `Graph.generate_balance_chart/2` to use a VegaLite trail mark with step-after interpolation and conditional green/red/grey color encoding. Add `timerange` string parsing and a new Discord option in the graph command module. Update the graph cache key to include the time range.

**Tech Stack:** Elixir, VegaLite (`vega_lite` 0.1.11), Nostrum (Discord), SQLite via Ecto

---

### Task 1: Add `since` filtering to `Bank.get_user_balance_history/2`

**Files:**
- Modify: `lib/stackcoin/core/bank.ex:134-175`
- Create: `test/stackcoin/core/bank_history_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/stackcoin/core/bank_history_test.exs
defmodule StackCoin.Core.BankHistoryTest do
  use StackCoin.DataCase

  alias StackCoin.Core.{Bank, User, Bot}

  setup do
    {:ok, owner} = User.create_user_account("900", "HistoryOwner", balance: 0)
    {:ok, bot} = Bot.create_bot_user("900", "HistoryBot")
    {:ok, _} = StackCoin.Core.Reserve.pump_reserve(owner.id, 1000, "test funding")
    {:ok, _} = Bank.transfer_between_users(1, bot.user.id, 500, "bot funding")

    {:ok, user1} = User.create_user_account("901", "HistoryUser1", balance: 0)
    {:ok, _} = Bank.transfer_between_users(bot.user.id, user1.id, 100, "tx1")
    # Small delay not needed -- transactions get ordered by ID
    {:ok, _} = Bank.transfer_between_users(bot.user.id, user1.id, 50, "tx2")

    %{user1: user1, bot: bot}
  end

  test "get_user_balance_history/1 returns full history", %{user1: user1} do
    {:ok, history} = Bank.get_user_balance_history(user1.id)
    # 2 transactions + 1 current-balance point = 3 entries
    assert length(history) == 3
  end

  test "get_user_balance_history/2 with since filters to recent", %{user1: user1} do
    # Use a since far in the past -- should still return all
    since = ~N[2000-01-01 00:00:00]
    {:ok, history} = Bank.get_user_balance_history(user1.id, since: since)
    assert length(history) >= 3

    # Use a since in the future -- should return 1 synthetic anchor + 1 current
    future = NaiveDateTime.add(NaiveDateTime.utc_now(), 3600, :second)
    {:ok, history_future} = Bank.get_user_balance_history(user1.id, since: future)
    assert length(history_future) == 2
    # The synthetic anchor should have the current balance
    {_ts, balance} = hd(history_future)
    assert balance == user1.balance + 150
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/stackcoin/core/bank_history_test.exs -v`
Expected: Second test FAIL because `get_user_balance_history/2` doesn't accept keyword opts yet.

- [ ] **Step 3: Implement the `since` filter**

In `lib/stackcoin/core/bank.ex`, change the function signature and query:

```elixir
def get_user_balance_history(user_id, opts \\ []) do
  since = Keyword.get(opts, :since)

  with {:ok, user} <- User.get_user_by_id(user_id) do
    base_query =
      from(t in Schema.Transaction,
        where: t.from_id == ^user_id or t.to_id == ^user_id,
        order_by: [asc: t.time],
        select: %{
          time: t.time,
          from_id: t.from_id,
          to_id: t.to_id,
          from_new_balance: t.from_new_balance,
          to_new_balance: t.to_new_balance
        }
      )

    query =
      if since do
        since_iso = NaiveDateTime.to_iso8601(since)
        from(t in base_query, where: t.time >= ^since_iso)
      else
        base_query
      end

    transactions = Repo.all(query)

    balance_history =
      transactions
      |> Enum.map(fn transaction ->
        balance =
          if transaction.from_id == user_id do
            transaction.from_new_balance
          else
            transaction.to_new_balance
          end

        {transaction.time, balance}
      end)

    # When filtering by `since`, prepend a synthetic anchor point at the
    # cutoff time using the balance from the last transaction before the
    # window (or current balance if no transactions matched).
    balance_history =
      if since do
        anchor_balance =
          case balance_history do
            [] ->
              # No transactions in window -- find last tx before cutoff
              pre_query =
                from(t in Schema.Transaction,
                  where: (t.from_id == ^user_id or t.to_id == ^user_id) and t.time < ^NaiveDateTime.to_iso8601(since),
                  order_by: [desc: t.time],
                  limit: 1,
                  select: %{
                    from_id: t.from_id,
                    from_new_balance: t.from_new_balance,
                    to_new_balance: t.to_new_balance
                  }
                )

              case Repo.one(pre_query) do
                nil -> user.balance
                tx -> if tx.from_id == user_id, do: tx.from_new_balance, else: tx.to_new_balance
              end

            [{_first_time, first_balance} | _] ->
              # Find the balance just before the first transaction in window
              pre_query =
                from(t in Schema.Transaction,
                  where: (t.from_id == ^user_id or t.to_id == ^user_id) and t.time < ^NaiveDateTime.to_iso8601(since),
                  order_by: [desc: t.time],
                  limit: 1,
                  select: %{
                    from_id: t.from_id,
                    from_new_balance: t.from_new_balance,
                    to_new_balance: t.to_new_balance
                  }
                )

              case Repo.one(pre_query) do
                nil -> first_balance
                tx -> if tx.from_id == user_id, do: tx.from_new_balance, else: tx.to_new_balance
              end
          end

        [{since, anchor_balance} | balance_history]
      else
        balance_history
      end

    final_history =
      case balance_history do
        [] -> [{NaiveDateTime.utc_now(), user.balance}]
        _ -> balance_history ++ [{NaiveDateTime.utc_now(), user.balance}]
      end

    {:ok, final_history}
  else
    {:error, reason} -> {:error, reason}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/stackcoin/core/bank_history_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/stackcoin/core/bank.ex test/stackcoin/core/bank_history_test.exs
git commit -m "feat: add since filter to Bank.get_user_balance_history"
```

---

### Task 2: Update VegaLite chart to step trail with green/red color

**Files:**
- Modify: `lib/stackcoin/graph.ex:12-48`

- [ ] **Step 1: Replace the chart spec**

Replace `generate_balance_chart/2` in `lib/stackcoin/graph.ex`:

```elixir
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
      calculate: "datum.prev_balance === null ? 'flat' : datum.balance > datum.prev_balance ? 'up' : datum.balance < datum.prev_balance ? 'down' : 'flat'",
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
```

- [ ] **Step 2: Verify locally**

Open `iex -S mix` and run:

```elixir
alias StackCoin.Core.Bank
alias StackCoin.Graph
{:ok, history} = Bank.get_user_balance_history(2)
png = Graph.generate_balance_chart(history, "test")
File.write!("/tmp/test_graph.png", png)
```

Open `/tmp/test_graph.png` and verify it shows green/red step segments.

- [ ] **Step 3: Commit**

```bash
git add lib/stackcoin/graph.ex
git commit -m "feat: replace line chart with green/red step trail"
```

---

### Task 3: Add `timerange` option to the Discord command

**Files:**
- Modify: `lib/stackcoin/bot/discord/graph.ex`

- [ ] **Step 1: Add the timerange option to the command definition**

In `definition/0`, add after the `user` option:

```elixir
%{
  type: ApplicationCommandOptionType.string(),
  name: "timerange",
  description: "Time window to show, e.g. 10d, 1hr, 2w (default: all time)",
  required: false
}
```

- [ ] **Step 2: Add the time range parser**

Add these private functions to the bottom of the module:

```elixir
@timerange_regex ~r/^\s*(\d+)\s*(m|min|minutes?|h|hr|hours?|d|days?|w|weeks?)\s*$/i

defp parse_timerange(nil), do: {:ok, nil}

defp parse_timerange(input) do
  case Regex.run(@timerange_regex, input) do
    [_, amount_str, unit] ->
      amount = String.to_integer(amount_str)
      minutes = unit_to_minutes(String.downcase(unit)) * amount
      since = NaiveDateTime.add(NaiveDateTime.utc_now(), -minutes * 60, :second)
      {:ok, since}

    nil ->
      {:error, "Invalid time range \"#{input}\". Use formats like: 10d, 1hr, 2w, 30m"}
  end
end

defp unit_to_minutes(u) when u in ["m", "min", "minute", "minutes"], do: 1
defp unit_to_minutes(u) when u in ["h", "hr", "hour", "hours"], do: 60
defp unit_to_minutes(u) when u in ["d", "day", "days"], do: 60 * 24
defp unit_to_minutes(u) when u in ["w", "week", "weeks"], do: 60 * 24 * 7
```

- [ ] **Step 3: Wire it into the handle function**

Update `handle/1` to extract and use the timerange. Replace the existing `handle` body:

```elixir
def handle(interaction) do
  with {:ok, guild} <- DiscordGuild.get_guild_by_discord_id(interaction.guild_id),
       {:ok, _channel_check} <- DiscordGuild.validate_channel(guild, interaction.channel_id),
       {:ok, {target_user, is_self}} <- get_target_user(interaction),
       {:ok, since} <- parse_timerange(get_option_value(interaction, "timerange")) do
    opts = if since, do: [since: since], else: []

    with {:ok, history} <- Bank.get_user_balance_history(target_user.id, opts) do
      try do
        png_binary = Graph.generate_balance_chart(history, target_user.username)
        send_graph_response(interaction, png_binary, target_user.username, is_self)
      rescue
        error ->
          Commands.send_error_response(
            interaction,
            "Error creating graph: #{inspect(error)}"
          )
      end
    else
      {:error, reason} ->
        Commands.send_error_response(interaction, reason)
    end
  else
    {:error, reason} ->
      Commands.send_error_response(interaction, reason)
  end
end
```

Add the option extractor helper:

```elixir
defp get_option_value(interaction, name) do
  case interaction.data.options do
    nil -> nil
    options ->
      Enum.find_value(options, fn option ->
        if option.name == name, do: option.value, else: nil
      end)
  end
end
```

And update `get_user_option/1` to use the new helper:

```elixir
defp get_user_option(interaction), do: get_option_value(interaction, "user")
```

- [ ] **Step 4: Commit**

```bash
git add lib/stackcoin/bot/discord/graph.ex
git commit -m "feat: add timerange option to /graph command"
```

---

### Task 4: Update graph cache to include time range

**Files:**
- Modify: `lib/stackcoin/graph_cache.ex`

- [ ] **Step 1: Update `get_graph_png` to accept and use a timerange key**

Change the public API to accept an optional `timerange_key` (the raw string or `"all"`):

```elixir
def get_graph_png(user_id, timerange_key \\ "all") do
  with {:ok, last_tx_id} <- get_last_transaction_id(user_id),
       cache_path = cache_path(user_id, last_tx_id, timerange_key),
       {:ok, png} <- read_cached(cache_path) do
    {:ok, png}
  else
    {:miss, cache_path} ->
      generate_and_cache(user_id, cache_path, timerange_key)

    {:error, :no_transactions} ->
      {:error, :no_transactions}

    {:error, reason} ->
      {:error, reason}
  end
end
```

Update `cache_path`:

```elixir
defp cache_path(user_id, tx_id, timerange_key) do
  safe_key = String.replace(timerange_key, ~r/[^a-zA-Z0-9]/, "_")
  Path.join(@cache_dir, "#{user_id}_#{tx_id}_#{safe_key}.png")
end
```

Update `generate_and_cache` to pass the `since` option through if the `timerange_key` isn't `"all"`. (Note: the cache module currently calls `Bank.get_user_balance_history` directly. If the caller wants filtering, they should pass `since` too. For simplicity, the cache module only caches full-history and per-range charts by key -- the caller in graph.ex already calls `Graph.generate_balance_chart` directly with the filtered history, so the cache is only used for the full-history path. This is acceptable for now.)

- [ ] **Step 2: Commit**

```bash
git add lib/stackcoin/graph_cache.ex
git commit -m "feat: include timerange in graph cache key"
```

---

### Task 5: Manual integration test

- [ ] **Step 1: Start the server**

```bash
iex -S mix phx.server
```

- [ ] **Step 2: Test in Discord**

1. `/graph` -- Should show full history with green/red step segments
2. `/graph timerange:7d` -- Should show only last 7 days
3. `/graph timerange:1hr` -- Should show only last hour
4. `/graph timerange:banana` -- Should show a friendly error
5. `/graph user:@someone timerange:3d` -- Both options together

- [ ] **Step 3: Final commit if any tweaks needed**

```bash
git add -A
git commit -m "fix: graph integration tweaks"
```
