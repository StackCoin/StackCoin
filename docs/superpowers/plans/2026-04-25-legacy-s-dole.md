# Legacy `s!dole` Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring back `s!dole` as a text-message command alongside the existing `/dole` slash command.

**Architecture:** Add `:guild_messages` and `:message_content` gateway intents so the bot receives message events. Add a `:MESSAGE_CREATE` handler in the consumer that matches `s!dole`. Add a `handle_legacy/1` function in the Dole module that reuses the core dole logic but replies with `Nostrum.Api.Message.create` instead of interaction responses.

**Tech Stack:** Elixir, Nostrum (Discord)

**Prerequisites:** The "Message Content Intent" must be enabled in the Discord Developer Portal (Bot settings) for the bot application. Without it, `msg.content` will always be empty string.

---

### Task 1: Add gateway intents and MESSAGE_CREATE consumer handler

**Files:**
- Modify: `lib/stackcoin/application.ex:30`
- Modify: `lib/stackcoin/bot/discord.ex`

- [ ] **Step 1: Add gateway intents**

In `lib/stackcoin/application.ex`, change the intents list at line 30 from:

```elixir
intents: [:guilds],
```

to:

```elixir
intents: [:guilds, :guild_messages, :message_content],
```

- [ ] **Step 2: Add MESSAGE_CREATE handler to consumer**

In `lib/stackcoin/bot/discord.ex`, add a new `handle_event` clause **before** the catch-all `def handle_event(_), do: :ok`. Add this between the READY handler and the catch-all:

```elixir
def handle_event({:MESSAGE_CREATE, msg, _ws_state}) do
  # Ignore bot messages to prevent loops
  unless msg.author.bot do
    handle_legacy_command(msg)
  end
end
```

Add the private function at the bottom of the module (before the final `end`):

```elixir
defp handle_legacy_command(%{content: content} = msg) do
  case String.trim(content) |> String.downcase() do
    "s!dole" ->
      Dole.handle_legacy(msg)

    _ ->
      :ignore
  end
end
```

- [ ] **Step 3: Verify compilation**

```bash
mix compile
```

Expected: Compiles with a warning about `Dole.handle_legacy/1` being undefined (that's Task 2).

- [ ] **Step 4: Commit**

```bash
git add lib/stackcoin/application.ex lib/stackcoin/bot/discord.ex
git commit -m "feat: add gateway intents and MESSAGE_CREATE routing for s!dole"
```

---

### Task 2: Implement `Dole.handle_legacy/1`

**Files:**
- Modify: `lib/stackcoin/bot/discord/dole.ex`

- [ ] **Step 1: Add `handle_legacy/1`**

In `lib/stackcoin/bot/discord/dole.ex`, add this function after the existing `handle/1`:

```elixir
@doc """
Handles the legacy `s!dole` text command.
Reuses the same core logic as the slash command but replies with a regular message.
"""
def handle_legacy(msg) do
  guild_id = msg.guild_id
  channel_id = msg.channel_id

  with {:ok, guild} <- DiscordGuild.get_guild_by_discord_id(guild_id),
       {:ok, _channel_check} <- DiscordGuild.validate_channel(guild, channel_id),
       {:ok, user} <- get_or_create_user(msg.author),
       {:ok, _banned_check} <- User.check_user_banned(user),
       {:ok, _dole_banned_check} <- User.check_user_dole_banned(user),
       {:ok, transaction} <- Reserve.transfer_dole_to_user(user.id) do
    Nostrum.Api.Message.create(channel_id,
      embeds: [
        %{
          title: "#{Commands.stackcoin_emoji()} Received **#{transaction.amount} STK**",
          description: "New Balance: **#{transaction.to_new_balance} STK**",
          color: Commands.stackcoin_color()
        }
      ]
    )
  else
    {:error, reason} ->
      Nostrum.Api.Message.create(channel_id, Commands.format_error(reason))
  end
end
```

Note: `msg.author` is a `Nostrum.Struct.User` with the same `id` and `username` fields that `interaction.user` has, so `get_or_create_user/1` works unchanged.

- [ ] **Step 2: Verify compilation**

```bash
mix compile
```

Expected: Clean compilation, no warnings.

- [ ] **Step 3: Run full test suite**

```bash
mix test
```

Expected: 321 tests, 0 failures (no existing tests break).

- [ ] **Step 4: Commit**

```bash
git add lib/stackcoin/bot/discord/dole.ex
git commit -m "feat: add s!dole legacy text command handler"
```

---

### Task 3: Manual test

- [ ] **Step 1:** Ensure "Message Content Intent" is enabled in Discord Developer Portal for the bot
- [ ] **Step 2:** Deploy or run locally with `iex -S mix phx.server`
- [ ] **Step 3:** In a registered StackCoin channel, type `s!dole`
- [ ] **Step 4:** Verify the bot responds with the dole embed (same content as `/dole`)
- [ ] **Step 5:** Verify `S!DOLE` and `s!dole ` (with trailing space) also work (case-insensitive, trimmed)
- [ ] **Step 6:** Verify the bot does not respond to `s!dole` from other bots
- [ ] **Step 7:** Verify `/dole` still works as before
