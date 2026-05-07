# LiveView Feature Parity Design

Bring the web UI to feature parity with the Discord bot. Adds bot management, preauthorization management, admin tools, balance graph time range filtering, and directional transaction filtering.

## Scope

### In scope
1. **Navigation bar** — conditional links for Bots, Preauths, Admin
2. **Bot management page** (`/bots`) — create, list, token reveal, reset token, delete
3. **Preauthorizations page** (`/preauths`) — list active preauths with budgets, revoke
4. **Admin panel** (`/admin`) — pump reserve, ban/unban, dole-ban/dole-unban
5. **Balance graph time range** — tab-based filter on user profile
6. **Transaction direction filter** — from/to/involving on `/transactions`

### Out of scope
- Dole claiming (stay Discord-only)
- Guild channel registration (admin Discord command only)
- Standalone leaderboard page
- Bot approval queue on web (non-admin bot requests still go through Discord DM)

## Design Decisions

- **Admin auth**: same Discord OAuth, checked via `User.is_user_admin?/1` (which checks both the `admin` DB column and the `admin_user_id` config env var). Non-admins redirected to `/` with error flash.
- **Bot tokens**: shown inline with click-to-reveal (`••••••••` → actual token on click). Also DMs the token via Discord, matching the Discord bot behavior. Tokens are revokable so visible display is fine.
- **Bot creation (non-admin)**: web form submits the request, triggers the existing Discord DM approval flow to the admin. No web-based approval queue.
- **Graph time range**: the graph controller gets a `?range=` query param. The GraphCache already accepts `timerange_key` but `generate_and_cache` needs to pass `since` through. Fix both.
- **PubSub**: new `"preauths"` topic for preauth page. Broadcast on create/approve/revoke.
- **All pages follow existing patterns**: `max-w-2xl mx-auto px-4 py-6 w-full`, border-only buttons, card-based list rows, filter tabs with `patch`, flash messages for action feedback.

## 1. Navigation Bar

Add to `app.html.heex` between the header and main content. A `<nav>` centered under the logo with `text-sm text-gray-500` links separated by a gap.

Links (all conditional):
- **Bots** → `/bots` (shown when `@current_user` is set)
- **Preauths** → `/preauths` (shown when `@current_user` is set)
- **Admin** → `/admin` (shown when `@current_user` is set AND `@current_user.admin == true`)

The admin check in the nav bar uses `@current_user.admin == true`. This column is set by `ensure_admin_user_exists/1` which runs during `check_admin_permissions/1`. If the admin user has never triggered that path (e.g. fresh DB), the column may be `false`. The `UserAuthHook` should also set an `@is_admin` assign by checking both the DB column and the `admin_user_id` config. The nav bar uses `@is_admin` instead of `@current_user.admin` directly.

## 2. Bot Management Page (`/bots`)

**Route**: `live("/bots", StackCoinWeb.BotsLive, :index)` inside the existing `live_session :default`.

**Auth**: requires login. Redirect to `/` with error flash if `@current_user` is nil.

**Page title**: `"Bots — StackCoin"`

### Create Bot section

A form at the top of the page:
```
[text input: Bot name] [Create Bot]
```

Input: `border border-gray-200 px-3 py-2 text-sm`, text type, required, placeholder "Bot name".
Button: `border border-black px-4 py-2 text-sm font-bold`.

**On submit (`phx-submit="create_bot"`)**:
- Call `Bot.admin_create_bot_user(current_user.discord_snowflake, name)`.
- If `{:ok, {bot_user, token}}`: assign the token to `@revealed_tokens` in socket state, show in list with click-to-reveal. Also DM the token via `StackCoin.Bot.Discord.Bot.send_bot_token_dm/2` (same OTP app, direct call).
- If `{:error, :not_admin}`: call `StackCoin.Bot.Discord.Bot.send_bot_creation_request_dm/2` to send the admin a Discord DM with Accept/Reject buttons. Show flash "Bot creation request sent to admin for approval."
- If `{:error, reason}`: show flash with `format_error(reason)`.

**Non-admin bot creation**: extract a public `send_bot_creation_request_dm(requester_snowflake, bot_name)` function from the existing `send_bot_creation_request/2` in `StackCoin.Bot.Discord.Bot`. This function only sends the admin DM with Accept/Reject buttons (no channel reply). The existing Discord handler calls it and also sends the channel reply. The web handler calls it and shows a flash instead. The button `custom_id` already encodes the requester snowflake and bot name, so the approval flow works regardless of origin.

### Your Bots list

Section header: `"Your Bots"` (no "View all" link — this is the full list).

Each row in the list:
```
Left:  [bot_name]  [BOT badge]  [ID: bot_user.user_id]  [linked balance]
Right: [Reset Token button]  [Delete button]
```

- Bot name links to `/user/:bot_user.user_id`.
- Balance shown as `X STK` in `font-mono text-sm`, linked to the user profile.
- Reset Token: primary button (`border border-black px-3 py-1 text-xs font-bold`). On click (`phx-click="reset_token" phx-value-bot-id={id}`), calls `Bot.reset_bot_token/2`, assigns the new token to `@revealed_tokens`, DMs it via `StackCoin.Bot.Discord.Bot.send_bot_token_dm/2`.
- Delete: secondary button (`border border-gray-300 px-3 py-1 text-xs text-gray-500`). On click, calls `Bot.delete_bot_user/2`, shows flash.

### Token reveal

When a token is available (after create or reset), the row shows it:
```
Token: [•••••••••••••] [Show] [Copy]
```

Clicking "Show" swaps the dots for the actual token text (client-side JS hook or simple LiveView toggle with an assign). "Copy" copies to clipboard via a JS hook.

The token is stored in `@revealed_tokens` (a map of `bot_id => token` in socket assigns). Cleared on next page load.

### Empty state

`"You don't have any bots yet."` in `px-4 py-8 text-center text-gray-500`.

### Real-time

Subscribe to `"transactions"` (for balance updates on bot rows).

## 3. Preauthorizations Page (`/preauths`)

**Route**: `live("/preauths", StackCoinWeb.PreauthsLive, :index)`.

**Auth**: requires login.

**Page title**: `"Preauthorizations — StackCoin"`

### List

Each row:
```
Left:  [bot_name (linked)]  "owned by"  [owner_name (linked)]
       [max_amount STK / window_hours hrs]  [remaining_budget STK remaining]
Right: [Revoke button]
```

- Bot name links to `/user/:bot_user_id`.
- Owner name links to `/user/:owner_id`. Obtained via `Bot.get_bot_owner_info/1`.
- Budget info in `text-sm text-gray-500`.
- Remaining budget via `Preauthorization.get_remaining_budget/1`.
- Revoke: secondary button. On click (`phx-click="revoke" phx-value-id={preauth.id}`), calls `Preauthorization.revoke_preauth/1`, shows flash, broadcasts on `"preauths"` topic.

### Empty state

`"No active preauthorizations."`.

### Real-time

Subscribe to `"preauths"` topic. Refresh list on `:preauth_approved`, `:preauth_revoked` events.

Need to add PubSub broadcasts to the preauth core module (or the places that call it — the API controller and the Discord bot preauth handler). Broadcast `{:preauth_approved, preauth}` and `{:preauth_revoked, preauth}` on the `"preauths"` topic.

## 4. Admin Panel (`/admin`)

**Route**: `live("/admin", StackCoinWeb.AdminLive, :index)`.

**Auth**: requires login AND admin. Check in `handle_params` — if not logged in or not admin, redirect to `/` with error flash. Admin check: `User.is_user_admin?(current_user.discord_snowflake)`.

**Page title**: `"Admin — StackCoin"`

### Reserve section

Header: `"Reserve"`.

Display current reserve balance: `"Reserve Balance: X STK"` in `text-lg font-mono`.

**Pump form**:
```
[number input: Amount] [text input: Label] [Pump]
```

Amount: `border border-gray-200 px-3 py-2 text-sm w-32 font-mono`, number type, min 1, required, placeholder "Amount".
Label: `border border-gray-200 px-3 py-2 text-sm`, text type, required, placeholder "Label".
Submit: `border border-black px-4 py-2 text-sm font-bold`, text "Pump".

On submit (`phx-submit="pump"`): call `Reserve.admin_pump_reserve(current_user.discord_snowflake, amount, label)`. Flash success with new balance or error.

### User Management section

Header: `"User Management"`.

A user select dropdown (same pattern as transactions page filter):
```
<select> with all users, sorted by last activity </select>
```

Once a user is selected, show their status below the dropdown:
```
[username]  [BANNED badge if banned]  [DOLE BANNED badge if dole_banned]

[Ban / Unban button]  [Dole Ban / Dole Unban button]
```

- If user is banned: show red BANNED badge, "Unban" button.
- If user is not banned: show "Ban" button.
- If user is dole_banned: show orange DOLE BANNED badge, "Dole Unban" button.
- If user is not dole_banned: show "Dole Ban" button.

Ban/Unban: call `User.admin_ban_user/2` or `User.admin_unban_user/2`.
Dole Ban/Unban: call `User.admin_dole_ban_user/2` or `User.admin_dole_unban_user/2`.

Flash on each action. Re-fetch user status after action.

Badge styles:
- BANNED: `text-xs uppercase tracking-wide px-1 border text-red-700 border-red-300` (same as "denied" status badge).
- DOLE BANNED: `text-xs uppercase tracking-wide px-1 border text-orange-700 border-orange-300`.

### Real-time

Subscribe to `"transactions"` for reserve balance updates.

## 5. Balance Graph Time Range

### Graph controller change

Accept an optional `range` query param in `GraphController.show/2`:
```
GET /graph/:user_id?range=1w
```

Valid values: `1w`, `1m`, `3m`, `1y`, `all` (default).

Map each to a `since` NaiveDateTime:
- `1w` → 7 days ago
- `1m` → 30 days ago
- `3m` → 90 days ago
- `1y` → 365 days ago
- `all` → nil

Pass `timerange_key` to `GraphCache.get_graph_png/2` and fix `generate_and_cache` to accept and forward the `since` option to `Bank.get_user_balance_history/2`. When `since` is set, also pass `zoomed: true` to `Graph.generate_balance_chart/3` (matching Discord bot behavior).

### User profile change

Add time range tabs above the balance graph on `UserLive`:
```
<nav class="flex gap-6 mb-6 border-b border-gray-200">
  All | 1w | 1m | 3m | 1y
</nav>
```

Same tab pattern as existing filter tabs. Active tab gets `border-b-2 border-black font-bold`.

The `<img>` tag's `src` includes the range param: `/graph/:id?range=1w&v=:cache_buster`.

URL: `?range=1w` patches via `handle_params`. Default is `all` (no param).

## 6. Transaction Direction Filter

### Change to `/transactions`

Replace the single "Involving" label with a direction select + user select:

```
[Direction: Involving ▾]  [User: All users ▾]
```

Direction options: `Involving` (default), `From`, `To`.

URL params: `?user=:id&dir=from|to|involving`. No `dir` param defaults to "involving" (backward compatible).

### Query changes

The existing `Bank.search_transactions/1` already supports `from_user_id`, `to_user_id`, and `includes_user_id` options. Map:
- `involving` + user → `includes_user_id: user_id`
- `from` + user → `from_user_id: user_id`
- `to` + user → `to_user_id: user_id`

The direction select is hidden when "All users" is selected (direction is meaningless without a user filter). It appears when a user is selected.

## PubSub Changes

Add broadcasts to the preauth lifecycle:
- `Preauthorization.approve_preauth/1` → broadcast `{:preauth_approved, preauth}` on `"preauths"`
- `Preauthorization.revoke_preauth/1` → broadcast `{:preauth_revoked, preauth}` on `"preauths"`
- `PreauthController.create/2` → broadcast `{:preauth_created, preauth}` on `"preauths"` (for future use)

## New Files

- `lib/stackcoin_web/live/bots_live.ex`
- `lib/stackcoin_web/live/preauths_live.ex`
- `lib/stackcoin_web/live/admin_live.ex`
- `assets/js/hooks/token_reveal.js` (JS hook for copy-to-clipboard)

## Modified Files

- `lib/stackcoin_web/components/layouts/app.html.heex` — add nav bar
- `lib/stackcoin_web/router.ex` — add 3 new routes
- `lib/stackcoin_web/live/user_live.ex` — add time range tabs
- `lib/stackcoin_web/live/transactions_live.ex` — add direction filter
- `lib/stackcoin_web/controllers/graph_controller.ex` — accept `range` param
- `lib/stackcoin/graph_cache.ex` — pass `since` through to generation
- `lib/stackcoin/core/preauthorization.ex` — add PubSub broadcasts
- `lib/stackcoin/bot/discord/bot.ex` — extract DM-to-admin logic into callable function
- `lib/stackcoin_web/live/user_auth_hook.ex` — set `is_admin` assign for nav bar conditional

## Testing

Each new LiveView gets a test file:
- `test/stackcoin_web/live/bots_live_test.exs`
- `test/stackcoin_web/live/preauths_live_test.exs`
- `test/stackcoin_web/live/admin_live_test.exs`

Existing test files updated:
- `test/stackcoin_web/live/user_live_test.exs` — time range tabs
- `test/stackcoin_web/live/transactions_live_test.exs` — direction filter

Test coverage:
- Auth guards (redirect when not logged in, redirect when not admin for admin page)
- CRUD operations (create bot, reset token, delete bot, revoke preauth, pump reserve, ban/unban)
- Token reveal behavior
- Non-admin bot creation request flow
- Filter tabs and URL param handling
- Real-time PubSub updates
