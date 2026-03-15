# LiveView Homepage Redesign

## Summary

Replace the static controller-based homepage with Phoenix LiveView pages. The homepage becomes a users list sorted by last transaction activity, with filter tabs and individual user detail pages. Real-time updates via PubSub show new transactions as they happen.

## Architecture

Two LiveView modules inside a single public `live_session`:

- **`StackCoinWeb.HomeLive`** (`GET /`) -- Users list sorted by last transaction time, filter tabs (All / Users / Bots)
- **`StackCoinWeb.UserLive`** (`GET /user/:id`) -- Individual user detail page with balance, bot info, and transaction history

Navigation: `<.link patch=...>` for filter tab switching within HomeLive. `<.link navigate=...>` for transitions between HomeLive and UserLive.

No authentication required -- these are public read-only views.

### LiveView Setup

The server-side LiveView infrastructure is already in place (PubSub, endpoint socket, signing salt, CSRF token). Changes needed:

1. Uncomment LiveView JS client in `assets/js/app.js`
2. Replace controller routes with `live` routes in the router
3. Create the two LiveView modules

## Data Layer

### Users by Last Activity

New query function `User.list_by_last_activity(filter)`:

```sql
SELECT u.*, MAX(t.time) as last_active
FROM user u
LEFT JOIN transaction t ON (t.from_id = u.id OR t.to_id = u.id)
LEFT JOIN bot_user b ON b.user_id = u.id
WHERE [filter: all | bot (b.id IS NOT NULL) | user (b.id IS NULL)]
GROUP BY u.id
ORDER BY last_active DESC NULLS LAST
```

Returns: user record, last_active timestamp, is_bot flag, balance.

### User Detail

For `GET /user/:id`: user record, bot_user join (if applicable, with owner info), recent transactions (last 20) where user is sender or receiver.

### PubSub

Add a global `"transactions"` topic. Broadcast `{:new_transaction, transaction}` from `StackCoin.Core.Bank` after successful transfers. Both LiveViews subscribe on mount (when connected) and update their state via `handle_info`.

The existing per-user `"user:<id>"` topics remain unchanged for the bot WebSocket gateway.

## UI Design

### Visual Style

Clean minimal aesthetic:
- White background, generous whitespace
- Sharp corners everywhere (no `rounded-*` classes)
- Subtle borders: `border border-gray-200`
- System sans-serif font (Tailwind default)
- Primary text: `text-gray-900`, secondary: `text-gray-500`
- Existing gold link hover color preserved
- Tailwind utility classes only, no custom CSS additions

### Homepage (`GET /`)

```
[StackCoin logo]

All    Users    Bots
───

┌─────────────────────────────────────┐
│ alice          420 STK    2m ago    │
├─────────────────────────────────────┤
│ bob            69 STK     1h ago    │
├─────────────────────────────────────┤
│ LuckyPot [BOT] 1000 STK  3h ago    │
├─────────────────────────────────────┤
│ charlie        5 STK     1d ago     │
└─────────────────────────────────────┘

OpenAPI Docs  ·  Source Code
```

- Filter tabs: plain text links, active tab has `border-b-2 border-black font-bold`
- Each user row links to `/user/:id`
- Shows: username, `[BOT]` tag if applicable, balance, relative time since last activity
- `[BOT]` tag styled: `text-xs uppercase tracking-wide text-gray-500 border border-gray-300 px-1`
- Rows separated by horizontal border lines
- Live-updating: new transactions cause re-sort

### User Detail Page (`GET /user/:id`)

```
[StackCoin logo]

← Back

alice
Balance: 420 STK
[BOT] Owned by: jack       (only if bot)

Recent Transactions
┌─────────────────────────────────────┐
│ 10 STK  alice → bob     2m ago     │
├─────────────────────────────────────┤
│ 5 STK   charlie → alice  1h ago    │
├─────────────────────────────────────┤
│ 1 STK   alice → reserve  3h ago    │
└─────────────────────────────────────┘

OpenAPI Docs  ·  Source Code
```

- Back link navigates to `/`
- Username large, balance below
- Bot metadata (name, owner link) shown if applicable
- Transaction list: most recent first, live-updating
- Usernames in transactions link to respective user pages

## Scope

### In scope
1. Uncomment LiveView JS client in `app.js`
2. Add `live` routes, remove controller homepage route
3. `HomeLive` with users list, filter tabs, live updates
4. `UserLive` with user detail, transaction history, live updates
5. New Ecto query for users sorted by last transaction time
6. New PubSub broadcast on `"transactions"` topic
7. Clean minimal styling per design

### Out of scope (future work)
- Sending STK from the web UI
- Accepting/rejecting requests from the web UI
- User authentication on the web
- Managing bots from the web
- Pagination (show reasonable limits: ~50 users, ~20 transactions)
