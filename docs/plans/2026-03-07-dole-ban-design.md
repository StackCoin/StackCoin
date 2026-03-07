# Dole Ban Feature Design

## Problem

The existing ban system is all-or-nothing: a banned user cannot do anything in StackCoin. We need a lighter restriction that only prevents a user from collecting dole while leaving all other functionality (send, balance, leaderboard, graph, requests) intact.

## Approach

Add a `dole_banned` boolean column to the `user` table, mirroring the existing `banned` pattern.

## Data Model

New migration adds a single column:

```elixir
alter table(:users) do
  add :dole_banned, :boolean, default: false, null: false
end
```

Update `Schema.User` to include `:dole_banned` in the schema and changeset.

## Core Logic (Core.User)

New functions mirroring the existing ban pattern:

- `check_user_dole_banned(user)` -- returns `{:error, :user_dole_banned}` if `user.dole_banned == true`, else `{:ok, :not_dole_banned}`
- `dole_ban_user(user)` -- sets `dole_banned: true`
- `dole_unban_user(user)` -- sets `dole_banned: false`
- `admin_dole_ban_user(admin_snowflake, target_snowflake)` -- permission-checked, supports pre-ban (creates account with `dole_banned: true` if user doesn't exist)
- `admin_dole_unban_user(admin_snowflake, target_snowflake)` -- permission-checked unban

## Enforcement

Add `check_user_dole_banned` call in `Core.Reserve.transfer_dole_to_user/1`, alongside the existing full ban check. A fully-banned user is still blocked by the existing check; a dole-banned user is blocked by the new check. All other operations are unaffected.

## Discord Commands (Bot.Discord.Admin)

Two new subcommands under `/admin`:

- `/admin dole-ban <user>` -- Dole-bans the target user
- `/admin dole-unban <user>` -- Removes dole ban from target user

Both take a single `user` option (Discord user mention), same as existing `ban`/`unban`.

## Error Handling

- `Bot.Discord.Commands`: `:user_dole_banned` -> "You have been banned from collecting dole."
- `ApiHelpers`: `:user_dole_banned` -> HTTP 403

## Scope

Only dole collection is affected. Send, balance, leaderboard, graph, and request commands remain unchanged for dole-banned users.

Pre-ban is supported: an admin can dole-ban a Discord user who has not yet created a StackCoin account. The account will be created with `dole_banned: true`.
