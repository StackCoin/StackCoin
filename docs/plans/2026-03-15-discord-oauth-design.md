# Discord OAuth Login

## Summary

Add Discord OAuth2 login to the StackCoin web frontend. Users authenticate via Discord, and if they have an existing StackCoin account (created via /dole in Discord), they're logged in. Users without an account are shown an error. Logged-in users see a "You" indicator on the homepage and user pages.

## OAuth Flow

```
GET /auth/discord
  → Redirect to Discord authorize URL (scope: identify, state: random CSRF token)
  → User authorizes on Discord
  → Discord redirects to GET /auth/discord/callback?code=...&state=...
  → Exchange code for access_token (POST discord.com/api/oauth2/token)
  → Fetch user info (GET discord.com/api/users/@me with Bearer token)
  → Look up discord_user by snowflake
  → Found: store user_id in session, redirect to /
  → Not found: redirect to / with flash error
GET /auth/logout
  → Clear session, redirect to /
```

State parameter stored in session before redirect, validated on callback.

## Dependencies

Add `{:req, "~> 0.5"}` to mix.exs for HTTP calls to Discord's API.

## New Files

### `lib/stackcoin_web/controllers/auth_controller.ex`
Three actions:
- `discord/2` -- Generate random state, store in session, redirect to Discord authorize URL
- `callback/2` -- Validate state, exchange code for token, fetch Discord user, look up StackCoin user, store in session or show error
- `logout/2` -- Clear session, redirect to /

### `lib/stackcoin_web/plugs/user_auth.ex`
Plug for the browser pipeline:
- Reads `user_id` from session
- Loads user via `User.get_user_by_id/1`
- Assigns `current_user` to conn (or nil)

## Config Changes

### runtime.exs
```elixir
config :stackcoin,
  discord_client_secret: env!("STACKCOIN_DISCORD_CLIENT_SECRET", :string, nil)
```

### .env / .env.dist
Add `STACKCOIN_DISCORD_CLIENT_SECRET`

### compose.yaml
The secret is already in the `.env` file loaded via `env_file`.

## Router Changes

```elixir
scope "/auth" do
  pipe_through(:browser)

  get("/discord", StackCoinWeb.AuthController, :discord)
  get("/discord/callback", StackCoinWeb.AuthController, :callback)
  get("/logout", StackCoinWeb.AuthController, :logout)
end
```

Browser pipeline gets `StackCoinWeb.Plugs.UserAuth` plug added.

`live_session` updated to pass `current_user` via `on_mount` hook.

## LiveView Changes

All LiveViews receive `@current_user` (the user map or nil).

### App Layout
- Logged out: "Login with Discord" link
- Logged in: "Logged in as {username} · Logout"

### Homepage
- Current user's row gets a `[YOU]` badge (same style as `[BOT]` but `border-black`)

### User Detail Page
- If viewing own page, show `[YOU]` badge next to username

## Discord Developer Portal Setup

1. Applications → StackCoin → OAuth2
2. Copy Client Secret
3. Add Redirects:
   - `http://localhost:4000/auth/discord/callback`
   - `https://stackcoin.world/auth/discord/callback`

## Scope

### In scope
- Discord OAuth2 login/logout
- Session-based auth with cookie storage
- `current_user` available in all LiveViews
- "You" indicator on homepage and user pages
- Block login for users without StackCoin accounts

### Out of scope
- Auto-creating accounts on OAuth
- Any write operations behind auth (sending, accepting, etc.)
- Token refresh (we only use the Discord token once to get user info)
- Avatar display
