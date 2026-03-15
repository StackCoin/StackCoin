# Transactions Page + Pagination

## Summary

Add a global `/transactions` page with an "involving user" filter and page-number pagination. Add pagination to the user detail page's transaction list. Show 5 recent transactions on the homepage with a link to `/transactions`.

## Architecture

All changes are LiveView modules using `handle_params` for URL-driven state (`?page=N`, `?user=42`). The existing `Bank.search_transactions/1` already supports `limit`, `offset`, `includes_user_id`, and returns `total_count` for pagination.

New route: `live("/transactions", StackCoinWeb.TransactionsLive, :index)` in the existing `live_session`.

A shared pagination function component renders page numbers with `<.link patch=...>`.

## Pages

### GET /transactions (TransactionsLive)

- 20 transactions per page
- "Involving" filter: `<select>` dropdown of all users, patches URL to `?user=42`
- Page numbers via `?page=N`, patch navigation
- Usernames link to `/user/:id`
- Real-time: PubSub refreshes page 1 when on page 1

### User Detail Pagination (UserLive)

- Existing 20-transaction limit becomes paginated
- Page via `?page=N` on `/user/:id?page=2`
- Patch navigation (no remount)

### Homepage Recent Transactions (HomeLive)

- 5 most recent transactions below the users list
- "View all" link to `/transactions`
- Live-updates via existing PubSub subscription
- No pagination here

## Shared Pagination Component

Renders: `← 1 2 [3] 4 5 →`

- Prev/next arrows, disabled on first/last page
- Current page bolded with `border-b-2 border-black`
- Truncates with `...` for many pages (e.g. `← 1 ... 4 [5] 6 ... 20 →`)
- Props: `current_page`, `total_pages`, `patch_url` (function that takes page number)

## Styling

Same as existing: sharp corners, `border-gray-200`, no rounded edges. Filter dropdown gets `border border-gray-200` with no rounding. Page numbers are plain text links.

## Scope

### In scope
1. Shared pagination function component
2. TransactionsLive with filter + pagination + real-time
3. UserLive pagination for transaction list
4. HomeLive recent transactions section with "View all" link
5. Router update for /transactions route

### Out of scope
- From/to separate filters (just "involving" for now)
- Transaction detail pages
- Homepage pagination (users list stays unpaginated)
