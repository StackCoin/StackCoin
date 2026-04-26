# Graph Command Improvements

## Summary

Two changes to `/graph`:

1. **Time range option** -- An optional `timerange` string parameter (e.g. `10d`, `1hr`, `2w`) that trims the chart to show only recent history.
2. **Step chart with green/red segments** -- Replace the smooth line chart with a step-after trail where each segment is green (balance increased) or red (balance decreased). Balance changes are discrete transactions, not continuous motion, so a step chart is more honest.

## Time Range Parsing

The `/graph` command gets a new optional string option called `timerange`. The value is parsed into a duration and subtracted from `NaiveDateTime.utc_now()` to produce a `since` cutoff.

Supported formats (case-insensitive, optional space between number and unit):
- Minutes: `30m`, `30min`, `30 minutes`
- Hours: `1h`, `1hr`, `1 hour`, `2 hours`
- Days: `10d`, `10 day`, `10 days`
- Weeks: `2w`, `2 week`, `2 weeks`

Invalid input returns an ephemeral error message. No `timerange` means full history (current behavior).

## Data Pipeline

`Bank.get_user_balance_history/1` becomes `Bank.get_user_balance_history/2` with an optional `since` keyword:

```elixir
Bank.get_user_balance_history(user_id, since: ~N[2026-04-15 00:00:00])
```

When `since` is provided, the transaction query adds `WHERE t.time >= ^since_iso`. To anchor the chart correctly, the function prepends a synthetic point at the `since` timestamp using the balance from the last transaction before `since` (or 0 if none).

## Chart Spec

Replace `mark(:line, point: true)` with `mark(:trail, interpolate: "step-after")`.

Add transforms:
1. `window` transform: `lag("balance", 1)` to get previous balance as `prev_balance`.
2. `calculate` transform: `"datum.balance > datum.prev_balance ? 'up' : datum.balance < datum.prev_balance ? 'down' : 'flat'"` stored as `direction`.

Encode color on `direction`:
- `"up"` -> `#26a641` (green)
- `"down"` -> `#da3633` (red)
- `"flat"` -> `#8b949e` (grey)

Trail mark `size` set to a constant (e.g. 3) so segments have uniform thickness.

## Cache

`GraphCache` filename currently: `{user_id}_{last_tx_id}.png`

New filename: `{user_id}_{last_tx_id}_{timerange_or_"all"}.png`

The cleanup glob `{user_id}_*.png` already handles old files.

## Files Changed

- `lib/stackcoin/bot/discord/graph.ex` -- Add `timerange` option, parse it, pass `since` to Bank
- `lib/stackcoin/core/bank.ex` -- Accept optional `since` in `get_user_balance_history/2`
- `lib/stackcoin/graph.ex` -- New VegaLite spec with trail mark, window/calculate transforms, conditional color
- `lib/stackcoin/graph_cache.ex` -- Include timerange in cache key
