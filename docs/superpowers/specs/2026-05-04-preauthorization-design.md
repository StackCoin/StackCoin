# Preauthorization Design

## Problem

LuckyPot's auto-enter feature creates StackCoin payment requests that require users to manually accept via Discord DM. This friction defeats the purpose of auto-enter -- users opt in to automatic pot entry but still have to babysit their DMs.

## Solution

A preauthorization system that lets bots withdraw STK from users automatically, within agreed-upon limits. A bot requests a preauth specifying a maximum amount and rolling time window. The user approves once via Discord DM. After that, the bot can create requests that resolve instantly without user interaction, up to the approved budget.

## Data Model

### New `preauthorizations` table

| Column | Type | Notes |
|---|---|---|
| `id` | integer PK | Auto-increment |
| `bot_user_id` | references users | The bot that can pull funds |
| `user_id` | references users | The human granting permission |
| `max_amount` | integer | Max STK within the rolling window |
| `window_hours` | integer | Rolling window size (e.g. 24) |
| `status` | string | `"pending"` / `"active"` / `"revoked"` |
| `requested_at` | naive_datetime | When the bot requested it |
| `approved_at` | naive_datetime | When the user approved (nullable) |
| `revoked_at` | naive_datetime | When the user revoked (nullable) |

**Constraints:**
- Unique partial index on `{bot_user_id, user_id}` where `status IN ("pending", "active")`. Only one non-revoked preauth per bot+user pair.
- Revoked preauths remain in the table for audit. A new preauth can be created after the old one is revoked.
- `max_amount` must be a positive integer (> 0).
- `window_hours` must be a positive integer (> 0).
- `bot_user_id` must reference a bot user (has an associated `BotUser` record). `user_id` must reference a non-bot user.

### Change to `requests` table

Add one nullable column: `preauthorization_id` (references preauthorizations). Set when a request is created via preauth. Null for normal requests.

Preauth requests are created with status `"accepted"` immediately -- they never pass through `"pending"`.

### Rolling window budget check

To determine remaining budget:

```sql
SELECT COALESCE(SUM(r.amount), 0)
FROM requests r
WHERE r.preauthorization_id = :preauth_id
  AND r.status = 'accepted'
  AND r.requested_at > datetime('now', '-' || :window_hours || ' hours')
```

Transfer succeeds if `used + new_amount <= max_amount`. Boundary: hitting exactly `max_amount` is allowed, exceeding it is not.

## API

### New endpoints

| Method | Path | Caller | Purpose |
|---|---|---|---|
| `POST` | `/api/user/:user_id/preauth` | Bot | Request a preauth. Body: `{max_amount, window_hours}` |
| `GET` | `/api/preauths` | Bot | List bot's preauths (all statuses). Optional query param `user_id` to filter by target user. |
| `GET` | `/api/preauth/:id` | Bot | Single preauth with remaining budget |

### Modified endpoint

**`POST /api/user/:user_id/request`** -- new optional field: `use_preauth: true`

When `use_preauth` is present:

1. Look up an active preauth where `bot_user_id = caller AND user_id = target AND status = "active"`.
2. **No active preauth:** fall back to normal pending request (ignore the flag).
3. **Active preauth found:** check rolling window budget.
4. **Budget sufficient + user has balance:** atomic Ecto transaction -- create request with status `"accepted"`, `preauthorization_id` set, transfer funds, create transaction record. Return the completed request + transaction.
5. **Budget exceeded:** return `{error: "preauth_limit_exceeded"}`.
6. **Insufficient balance:** return `{error: "insufficient_balance"}`.
7. **On success:** send informational DM with revoke button, fire `request.accepted` event as normal.

Idempotency keys work the same way with preauth requests.

## Preauth Lifecycle

### Creation

1. Bot calls `POST /api/user/:id/preauth` with `{max_amount: 10, window_hours: 24}`.
2. StackCoin validates bot is a bot user, target is a non-bot user, no existing active/pending preauth for this pair.
3. Creates a `"pending"` preauth record.
4. DMs the user with preauth details and Accept/Deny buttons.
5. Returns the preauth record to the bot.
6. Fires `"preauth.created"` event.

### Approval

1. User clicks Accept in the DM.
2. Status changes to `"active"`, `approved_at` set.
3. DM updates to green confirmation.
4. Fires `"preauth.approved"` event.

### Denial (of pending preauth)

1. User clicks Deny in the DM.
2. Preauth is hard-deleted (no point keeping a never-approved record).
3. DM updates to show it was declined.

### Revocation (of active preauth)

1. User clicks Revoke on a transfer DM, or uses the `/preauths` slash command.
2. Status changes to `"revoked"`, `revoked_at` set.
3. Fires `"preauth.revoked"` event.
4. Future `use_preauth` requests for this bot+user pair fall back to normal pending requests.

### Persistence

Preauths persist until explicitly revoked. No expiration.

## Discord UX

### Preauth approval DM

Components v2 message sent when a bot requests a preauth:

- Container with StackCoin brand color
- Text: bot name (with owner mention), requested limit, window
- Explanation: "This means the bot can take STK from your account without asking each time, up to the limit shown above. You can revoke this at any time."
- Action row: Accept and Deny buttons (`custom_id: "preauth_accept_{id}"` / `"preauth_deny_{id}"`)

After acceptance: updates to green container confirming the preauth is active.

### Preauth transfer DM

Sent each time a bot uses the preauth to withdraw:

- Container with StackCoin brand color
- Text: bot name, amount withdrawn, label, new balance, remaining budget in the window (e.g. "5/10 STK remaining (24hr)")
- Action row: Revoke Preauth button (`custom_id: "preauth_revoke_{id}"`)

### `/preauths` slash command

Lists the calling user's active preauths. Each entry shows:
- Bot name
- Limit and window (e.g. "10 STK / 24hr")
- Remaining budget
- Revoke button

## Events

Three new event types:

- `"preauth.created"` -- `{preauth_id, bot_user_id, user_id, max_amount, window_hours}`
- `"preauth.approved"` -- `{preauth_id, bot_user_id, user_id}`
- `"preauth.revoked"` -- `{preauth_id, bot_user_id, user_id}`

Preauth transfers still fire the normal `"request.accepted"` and `"transfer.completed"` events. Existing WebSocket listeners (including LuckyPot's) continue to work without changes for the non-preauth path.

## LuckyPot Integration

### `enter_pot` changes

`enter_pot` always passes `use_preauth: true` when creating a StackCoin request. This is unconditionally safe:

- **User has active preauth + budget + balance:** instant transfer. `enter_pot` confirms the pot entry immediately from the API response. No WebSocket wait.
- **User has no preauth / revoked / pending:** falls back to normal pending request. Existing flow (DM accept -> WebSocket event -> confirm entry) continues.
- **Preauth limit exceeded:** `enter_pot` skips the entry silently. No ban.
- **Insufficient balance:** `enter_pot` skips the entry silently. No ban.

The silent skip (no ban) only applies to the preauth path. A user who manually clicks Deny on a normal pending request still gets the 48-hour ban.

### `stk.py` changes

`create_request` gains an optional `use_preauth` parameter. New function `create_preauth(user_id, max_amount, window_hours)`. New function `get_preauths()` to list the bot's preauths.

### `/auto-enter` changes

When a user runs `/auto-enter enabled:true`:

1. Enable auto-enter in LuckyPot's local DB (unchanged).
2. Check if an active preauth exists for this user (call `GET /api/preauths` or check locally).
3. **No preauth:** call `POST /api/user/:id/preauth` with `{max_amount: 10, window_hours: 24}`. Respond: "Auto-enter enabled! Check your DMs from StackCoin to approve automatic payments."
4. **Preauth pending:** respond: "Auto-enter enabled! You still need to approve the preauth in your StackCoin DMs."
5. **Preauth active:** respond: "Auto-enter enabled with automatic payments!"

`/auto-enter enabled:false` disables auto-enter locally. Does NOT revoke the preauth.

### `_auto_enter_users` changes

No structural changes. The loop still calls `enter_pot` for each opted-in user. Users with preauths get instant entries; users without get pending requests. The distinction is handled entirely by StackCoin.

## Testing

### StackCoin unit tests (Elixir)

**Core preauth logic:**
- Create preauth -> pending state, correct bot+user pair
- Approve preauth -> active, approved_at set
- Revoke preauth -> revoked, revoked_at set
- Deny pending preauth -> hard deleted
- Duplicate preauth rejected (unique constraint)
- New preauth allowed after revoking old one

**Rolling window budget:**
- Fresh preauth has full budget
- Budget decreases after preauth transfers
- Budget recovers as old transfers age out of window
- Transfer rejected when budget exceeded
- Boundary: exactly max_amount succeeds, max_amount + 1 fails

**Request endpoint with `use_preauth`:**
- Active preauth + budget + balance -> accepted request with transaction
- Active preauth, budget exceeded -> `preauth_limit_exceeded` error
- Active preauth, insufficient balance -> `insufficient_balance` error
- No preauth -> falls back to normal pending request
- Revoked preauth -> falls back to normal pending request
- Pending preauth -> falls back to normal pending request
- Preauth request has `preauthorization_id` set
- Idempotency key works with preauth requests

**Discord interactions (mock-based):**
- Preauth approval DM sent on creation
- Accept button activates preauth
- Deny button deletes pending preauth
- Transfer DM with revoke button sent on preauth use
- Revoke button sets revoked_at
- `/preauths` command lists active preauths with revoke buttons

### LuckyPot e2e tests (Python)

- `enter_pot` with active preauth -> entry confirmed immediately
- `enter_pot` without preauth -> falls back to pending request
- `enter_pot` with preauth, insufficient balance -> entry skipped, no ban
- `enter_pot` with preauth, budget exceeded -> entry skipped, no ban
- Auto-enter with preauths -> instant entries for opted-in users
- Auto-enter mixed -> preauth users instant, non-preauth users pending
- `/auto-enter` requests preauth if none exists
- `/auto-enter` skips preauth request if already active
- Preauth revoked mid-session -> next entry falls back to normal request
