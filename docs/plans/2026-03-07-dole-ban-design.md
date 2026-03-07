# Dole Ban Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a "dole ban" restriction that prevents specific users from collecting dole while leaving all other StackCoin functionality intact.

**Architecture:** New `dole_banned` boolean column on the `user` table, mirroring the existing `banned` pattern. Core logic in `Core.User`, enforcement in `Core.Reserve`, admin commands under `/admin dole-ban` and `/admin dole-unban`.

**Tech Stack:** Elixir, Phoenix, Ecto (SQLite3), Nostrum (Discord bot), Mock (testing)

---

### Task 1: Database Migration

**Files:**
- Create: `priv/repo/migrations/20260307000001_add_dole_banned_to_users.exs`

**Step 1: Create the migration file**

```elixir
defmodule StackCoin.Repo.Migrations.AddDoleBannedToUsers do
  use Ecto.Migration

  def change do
    alter table(:user) do
      add :dole_banned, :boolean, default: false, null: false
    end
  end
end
```

Note: table name is `:user` (not `:users`) -- see `lib/stackcoin/schema/user.ex:5` which uses `schema "user"`.

**Step 2: Run the migration**

Run: `mix ecto.migrate`
Expected: Migration runs successfully

**Step 3: Commit**

```bash
git add priv/repo/migrations/20260307000001_add_dole_banned_to_users.exs
git commit -m "Add dole_banned column to user table"
```

---

### Task 2: Update Schema.User

**Files:**
- Modify: `lib/stackcoin/schema/user.ex:5-28`

**Step 1: Add `dole_banned` field to schema and changeset**

Add `field(:dole_banned, :boolean, default: false)` after line 10 (the `banned` field).

Update the `cast/3` call on line 25 to include `:dole_banned`:
```elixir
|> cast(attrs, [:username, :balance, :last_given_dole, :admin, :banned, :dole_banned])
```

Update the `validate_required/2` call on line 26 to include `:dole_banned`:
```elixir
|> validate_required([:username, :balance, :admin, :banned, :dole_banned])
```

**Step 2: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: Compiles without errors

**Step 3: Commit**

```bash
git add lib/stackcoin/schema/user.ex
git commit -m "Add dole_banned field to User schema"
```

---

### Task 3: Core.User -- dole ban/unban functions

**Files:**
- Modify: `lib/stackcoin/core/user.ex`

**Step 1: Write tests for dole ban core functions**

**Files:**
- Create: `test/stackcoin/core/user_dole_ban_test.exs`

```elixir
defmodule StackCoinTest.Core.UserDoleBanTest do
  use ExUnit.Case
  import Mock
  alias StackCoin.Core.User

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(StackCoin.Repo)
    :ok
  end

  describe "dole_ban_user/1" do
    test "sets dole_banned to true" do
      {:ok, user} = User.create_user_account(111_111_111, "TestUser")
      assert user.dole_banned == false

      {:ok, updated} = User.dole_ban_user(user)
      assert updated.dole_banned == true
    end
  end

  describe "dole_unban_user/1" do
    test "sets dole_banned to false" do
      {:ok, user} = User.create_user_account(111_111_111, "TestUser")
      {:ok, banned} = User.dole_ban_user(user)
      assert banned.dole_banned == true

      {:ok, unbanned} = User.dole_unban_user(banned)
      assert unbanned.dole_banned == false
    end
  end

  describe "check_user_dole_banned/1" do
    test "returns ok for non-dole-banned user" do
      {:ok, user} = User.create_user_account(111_111_111, "TestUser")
      assert {:ok, :not_dole_banned} = User.check_user_dole_banned(user)
    end

    test "returns error for dole-banned user" do
      {:ok, user} = User.create_user_account(111_111_111, "TestUser")
      {:ok, banned} = User.dole_ban_user(user)
      assert {:error, :user_dole_banned} = User.check_user_dole_banned(banned)
    end
  end

  describe "admin_dole_ban_user/2" do
    test "admin can dole-ban an existing user" do
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      Application.put_env(:stackcoin, :admin_user_id, to_string(admin_user_id))

      with_mocks([
        {Nostrum.Api.User, [],
         [
           get: fn user_id ->
             cond do
               user_id == admin_user_id or user_id == to_string(admin_user_id) ->
                 {:ok, %{id: admin_user_id, username: "TestAdmin"}}
               user_id == target_user_id or user_id == to_string(target_user_id) ->
                 {:ok, %{id: target_user_id, username: "TargetUser"}}
               true ->
                 {:error, :not_found}
             end
           end
         ]}
      ]) do
        {:ok, _admin} = User.create_user_account(admin_user_id, "TestAdmin", admin: true)
        {:ok, _target} = User.create_user_account(target_user_id, "TargetUser")

        {:ok, result} = User.admin_dole_ban_user(admin_user_id, target_user_id)
        assert result.dole_banned == true
      end
    end

    test "admin can dole-ban a user who does not have an account (pre-ban)" do
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      Application.put_env(:stackcoin, :admin_user_id, to_string(admin_user_id))

      with_mocks([
        {Nostrum.Api.User, [],
         [
           get: fn user_id ->
             cond do
               user_id == admin_user_id or user_id == to_string(admin_user_id) ->
                 {:ok, %{id: admin_user_id, username: "TestAdmin"}}
               user_id == target_user_id or user_id == to_string(target_user_id) ->
                 {:ok, %{id: target_user_id, username: "PreBannedUser"}}
               true ->
                 {:error, :not_found}
             end
           end
         ]}
      ]) do
        {:ok, _admin} = User.create_user_account(admin_user_id, "TestAdmin", admin: true)

        {:ok, result} = User.admin_dole_ban_user(admin_user_id, target_user_id)
        assert result.dole_banned == true

        # Verify account was created
        {:ok, user} = User.get_user_by_discord_id(target_user_id)
        assert user.dole_banned == true
        assert user.banned == false
      end
    end

    test "non-admin cannot dole-ban a user" do
      regular_user_id = 777_777_777
      target_user_id = 888_888_888

      Application.put_env(:stackcoin, :admin_user_id, "999999999")
      {:ok, _regular} = User.create_user_account(regular_user_id, "RegularUser")
      {:ok, _target} = User.create_user_account(target_user_id, "TargetUser")

      assert {:error, :not_admin} = User.admin_dole_ban_user(regular_user_id, target_user_id)
    end
  end

  describe "admin_dole_unban_user/2" do
    test "admin can dole-unban a dole-banned user" do
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      Application.put_env(:stackcoin, :admin_user_id, to_string(admin_user_id))

      with_mocks([
        {Nostrum.Api.User, [],
         [
           get: fn user_id ->
             cond do
               user_id == admin_user_id or user_id == to_string(admin_user_id) ->
                 {:ok, %{id: admin_user_id, username: "TestAdmin"}}
               user_id == target_user_id or user_id == to_string(target_user_id) ->
                 {:ok, %{id: target_user_id, username: "TargetUser"}}
               true ->
                 {:error, :not_found}
             end
           end
         ]}
      ]) do
        {:ok, _admin} = User.create_user_account(admin_user_id, "TestAdmin", admin: true)
        {:ok, target} = User.create_user_account(target_user_id, "TargetUser")
        {:ok, _banned} = User.dole_ban_user(target)

        {:ok, result} = User.admin_dole_unban_user(admin_user_id, target_user_id)
        assert result.dole_banned == false
      end
    end

    test "dole-unban fails when target has no account" do
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      Application.put_env(:stackcoin, :admin_user_id, to_string(admin_user_id))

      with_mocks([
        {Nostrum.Api.User, [],
         [
           get: fn user_id ->
             cond do
               user_id == admin_user_id or user_id == to_string(admin_user_id) ->
                 {:ok, %{id: admin_user_id, username: "TestAdmin"}}
               true ->
                 {:error, :not_found}
             end
           end
         ]}
      ]) do
        {:ok, _admin} = User.create_user_account(admin_user_id, "TestAdmin", admin: true)

        assert {:error, :other_user_not_found} = User.admin_dole_unban_user(admin_user_id, target_user_id)
      end
    end

    test "non-admin cannot dole-unban a user" do
      regular_user_id = 777_777_777
      target_user_id = 888_888_888

      Application.put_env(:stackcoin, :admin_user_id, "999999999")
      {:ok, _regular} = User.create_user_account(regular_user_id, "RegularUser")
      {:ok, target} = User.create_user_account(target_user_id, "TargetUser")
      {:ok, _banned} = User.dole_ban_user(target)

      assert {:error, :not_admin} = User.admin_dole_unban_user(regular_user_id, target_user_id)
    end
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `mix test test/stackcoin/core/user_dole_ban_test.exs`
Expected: FAIL -- functions don't exist yet

**Step 3: Implement Core.User functions**

Add the following to `lib/stackcoin/core/user.ex` after the existing `unban_user/1` function (after line 117):

```elixir
@doc """
Dole-bans a user (prevents dole collection only).
"""
def dole_ban_user(user) do
  user
  |> Schema.User.changeset(%{dole_banned: true})
  |> Repo.update()
end

@doc """
Removes dole ban from a user.
"""
def dole_unban_user(user) do
  user
  |> Schema.User.changeset(%{dole_banned: false})
  |> Repo.update()
end

@doc """
Checks if a user is dole-banned.
"""
def check_user_dole_banned(user) do
  if user.dole_banned do
    {:error, :user_dole_banned}
  else
    {:ok, :not_dole_banned}
  end
end
```

Add admin functions after the existing `admin_unban_user/2` function (after line 166):

```elixir
@doc """
Admin-only dole ban with permission check. Supports pre-ban.
"""
def admin_dole_ban_user(admin_discord_snowflake, target_discord_snowflake) do
  with {:ok, _admin_check} <- check_admin_permissions(admin_discord_snowflake),
       {:ok, target_user} <- get_or_create_user_for_dole_ban(target_discord_snowflake) do
    dole_ban_user(target_user)
  else
    {:error, :not_admin} -> {:error, :not_admin}
    {:error, reason} -> {:error, reason}
  end
end

@doc """
Admin-only dole unban with permission check.
"""
def admin_dole_unban_user(admin_discord_snowflake, target_discord_snowflake) do
  with {:ok, _admin_check} <- check_admin_permissions(admin_discord_snowflake),
       {:ok, target_user} <- get_user_by_discord_id(target_discord_snowflake) do
    dole_unban_user(target_user)
  else
    {:error, :not_admin} -> {:error, :not_admin}
    {:error, :user_not_found} -> {:error, :other_user_not_found}
    {:error, reason} -> {:error, reason}
  end
end
```

Add the private helper before `ensure_admin_user_exists/1` (before line 272):

```elixir
defp get_or_create_user_for_dole_ban(discord_snowflake) do
  case get_user_by_discord_id(discord_snowflake) do
    {:ok, user} ->
      {:ok, user}

    {:error, :user_not_found} ->
      {:ok, discord_user} = Nostrum.Api.User.get(discord_snowflake)
      create_user_account(discord_snowflake, discord_user.username, dole_banned: true)
  end
end
```

Also update `create_user_account/3` to support the `:dole_banned` option. In `lib/stackcoin/core/user.ex:41-67`, add `dole_banned` to the opts and attrs:

```elixir
def create_user_account(discord_snowflake, username, opts \\ []) do
  admin = Keyword.get(opts, :admin, false)
  balance = Keyword.get(opts, :balance, 0)
  banned = Keyword.get(opts, :banned, false)
  dole_banned = Keyword.get(opts, :dole_banned, false)

  Repo.transaction(fn ->
    user_attrs = %{
      username: username,
      balance: balance,
      admin: admin,
      banned: banned,
      dole_banned: dole_banned
    }
    # ... rest unchanged
```

**Step 4: Run tests to verify they pass**

Run: `mix test test/stackcoin/core/user_dole_ban_test.exs`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add lib/stackcoin/core/user.ex test/stackcoin/core/user_dole_ban_test.exs
git commit -m "Add dole ban/unban core functions with tests"
```

---

### Task 4: Enforce dole ban in Core.Reserve

**Files:**
- Modify: `lib/stackcoin/core/reserve.ex:17-39`

**Step 1: Write a test for dole ban enforcement**

**Files:**
- Create: `test/stackcoin/core/reserve_dole_ban_test.exs`

```elixir
defmodule StackCoinTest.Core.ReserveDoleBanTest do
  use ExUnit.Case
  import StackCoinTest.Support.DiscordUtils
  alias StackCoin.Core.{User, Reserve}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(StackCoin.Repo)
    create_reserve_user(1000)
    :ok
  end

  test "dole-banned user cannot collect dole" do
    {:ok, user} = User.create_user_account(111_111_111, "TestUser")
    {:ok, banned_user} = User.dole_ban_user(user)

    assert {:error, :user_dole_banned} = Reserve.transfer_dole_to_user(banned_user.id)
  end

  test "non-dole-banned user can collect dole" do
    {:ok, user} = User.create_user_account(111_111_111, "TestUser")

    assert {:ok, _transaction} = Reserve.transfer_dole_to_user(user.id)
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/stackcoin/core/reserve_dole_ban_test.exs`
Expected: First test FAILS (dole ban not enforced yet)

**Step 3: Add dole ban check to `transfer_dole_to_user/1`**

In `lib/stackcoin/core/reserve.ex:17-39`, add the dole ban check after the user fetch:

```elixir
def transfer_dole_to_user(user_id) do
  with {:ok, user} <- User.get_user_by_id(user_id),
       {:ok, _dole_ban_check} <- User.check_user_dole_banned(user),
       {:ok, _dole_check} <- check_daily_dole_eligibility(user),
       {:ok, reserve_balance} <- get_reserve_balance(),
       {:ok, _balance_check} <- check_reserve_balance(reserve_balance),
       {:ok, transaction} <-
         Bank.transfer_between_users(@reserve_user_id, user_id, @dole_amount, "Daily dole"),
       {:ok, _updated_user} <- update_last_given_dole(user_id) do
    {:ok, transaction}
  else
    {:error, :user_not_found} ->
      {:error, :user_not_found}

    {:error, :user_dole_banned} ->
      {:error, :user_dole_banned}

    {:error, :insufficient_balance} ->
      {:error, :insufficient_reserve_balance}

    {:error, {:dole_already_given_today, timestamp}} ->
      {:error, {:dole_already_given_today, timestamp}}

    {:error, reason} ->
      {:error, reason}
  end
end
```

**Step 4: Run tests to verify they pass**

Run: `mix test test/stackcoin/core/reserve_dole_ban_test.exs`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add lib/stackcoin/core/reserve.ex test/stackcoin/core/reserve_dole_ban_test.exs
git commit -m "Enforce dole ban check in Reserve.transfer_dole_to_user"
```

---

### Task 5: Add dole ban check to Dole Discord command

**Files:**
- Modify: `lib/stackcoin/bot/discord/dole.ex:24-35`

**Step 1: Add `check_user_dole_banned` to the `with` chain**

In `lib/stackcoin/bot/discord/dole.ex:24-35`, add the dole ban check after the regular ban check:

```elixir
def handle(interaction) do
  with {:ok, guild} <- DiscordGuild.get_guild_by_discord_id(interaction.guild_id),
       {:ok, _channel_check} <- DiscordGuild.validate_channel(guild, interaction.channel_id),
       {:ok, user} <- get_or_create_user(interaction.user),
       {:ok, _banned_check} <- User.check_user_banned(user),
       {:ok, _dole_banned_check} <- User.check_user_dole_banned(user),
       {:ok, transaction} <- Reserve.transfer_dole_to_user(user.id) do
    send_success_response(interaction, user, transaction)
  else
    {:error, reason} ->
      Commands.send_error_response(interaction, reason)
  end
end
```

**Step 2: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: Compiles without errors

**Step 3: Commit**

```bash
git add lib/stackcoin/bot/discord/dole.ex
git commit -m "Add dole ban check to Dole Discord command handler"
```

---

### Task 6: Error handling -- Commands and ApiHelpers

**Files:**
- Modify: `lib/stackcoin/bot/discord/commands.ex:163-232`
- Modify: `lib/stackcoin_web/controllers/api_helpers.ex:12-68`

**Step 1: Add `:user_dole_banned` to `Commands.send_error_response/2`**

In `lib/stackcoin/bot/discord/commands.ex`, add after the `:user_banned` case (after line 204):

```elixir
:user_dole_banned ->
  "❌ You have been banned from collecting dole."
```

**Step 2: Add `:user_dole_banned` to `ApiHelpers.error_to_status_and_message/1`**

In `lib/stackcoin_web/controllers/api_helpers.ex`, add after the `:recipient_banned` case (after line 31):

```elixir
:user_dole_banned ->
  {:forbidden, "user_dole_banned"}
```

**Step 3: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: Compiles without errors

**Step 4: Commit**

```bash
git add lib/stackcoin/bot/discord/commands.ex lib/stackcoin_web/controllers/api_helpers.ex
git commit -m "Add dole ban error handling to Commands and ApiHelpers"
```

---

### Task 7: Admin Discord commands -- dole-ban and dole-unban subcommands

**Files:**
- Modify: `lib/stackcoin/bot/discord/admin.ex`

**Step 1: Write tests for dole-ban admin commands**

**Files:**
- Create: `test/stackcoin/bot/discord/admin_dole_ban_test.exs`

```elixir
defmodule StackCoinTest.Bot.Discord.AdminDoleBan do
  use ExUnit.Case
  import Mock
  import StackCoinTest.Support.DiscordUtils

  alias StackCoin.Bot.Discord.Admin
  alias StackCoin.Core.User

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(StackCoin.Repo)
    :ok
  end

  defp create_dole_ban_interaction(admin_user_id, guild_id, channel_id, target_user_id) do
    create_mock_interaction(admin_user_id, guild_id, channel_id, %{
      options: [
        %{
          name: "dole-ban",
          options: [
            %{name: "user", value: target_user_id}
          ]
        }
      ]
    })
  end

  defp create_dole_unban_interaction(admin_user_id, guild_id, channel_id, target_user_id) do
    create_mock_interaction(admin_user_id, guild_id, channel_id, %{
      options: [
        %{
          name: "dole-unban",
          options: [
            %{name: "user", value: target_user_id}
          ]
        }
      ]
    })
  end

  describe "dole-ban command" do
    test "admin can dole-ban an existing user" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, _target} = User.create_user_account(target_user_id, "TargetUser")

      interaction = create_dole_ban_interaction(admin_user_id, guild_id, channel_id, target_user_id)

      with_mocks([
        {Nostrum.Api.User, [],
         [
           get: fn user_id ->
             cond do
               user_id == admin_user_id or user_id == to_string(admin_user_id) ->
                 {:ok, %{id: admin_user_id, username: "TestAdmin"}}
               user_id == target_user_id or user_id == to_string(target_user_id) ->
                 {:ok, %{id: target_user_id, username: "TargetUser"}}
               true ->
                 {:error, :not_found}
             end
           end
         ]},
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.embeds != nil
             embed = hd(response.data.embeds)
             assert String.contains?(embed.title, "Dole Banned")
             assert String.contains?(embed.description, "TargetUser")
             {:ok}
           end
         ]}
      ]) do
        Admin.handle(interaction)
      end

      {:ok, user} = User.get_user_by_discord_id(target_user_id)
      assert user.dole_banned == true
      assert user.banned == false
    end

    test "admin can dole-ban a user who does not have an account (pre-ban)" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)

      interaction = create_dole_ban_interaction(admin_user_id, guild_id, channel_id, target_user_id)

      with_mocks([
        {Nostrum.Api.User, [],
         [
           get: fn user_id ->
             cond do
               user_id == admin_user_id or user_id == to_string(admin_user_id) ->
                 {:ok, %{id: admin_user_id, username: "TestAdmin"}}
               user_id == target_user_id or user_id == to_string(target_user_id) ->
                 {:ok, %{id: target_user_id, username: "PreDoleBannedUser"}}
               true ->
                 {:error, :not_found}
             end
           end
         ]},
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.embeds != nil
             embed = hd(response.data.embeds)
             assert String.contains?(embed.title, "Dole Banned")
             {:ok}
           end
         ]}
      ]) do
        Admin.handle(interaction)
      end

      {:ok, user} = User.get_user_by_discord_id(target_user_id)
      assert user.dole_banned == true
      assert user.banned == false
    end

    test "non-admin cannot dole-ban a user" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      regular_user_id = 777_777_777
      target_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, _regular} = User.create_user_account(regular_user_id, "RegularUser")
      {:ok, _target} = User.create_user_account(target_user_id, "TargetUser")

      interaction = create_dole_ban_interaction(regular_user_id, guild_id, channel_id, target_user_id)

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.content != nil
             assert String.contains?(response.data.content, "don't have permission")
             {:ok}
           end
         ]}
      ]) do
        Admin.handle(interaction)
      end

      {:ok, user} = User.get_user_by_discord_id(target_user_id)
      assert user.dole_banned == false
    end
  end

  describe "dole-unban command" do
    test "admin can dole-unban a dole-banned user" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, target} = User.create_user_account(target_user_id, "TargetUser")
      {:ok, _banned} = User.dole_ban_user(target)

      interaction = create_dole_unban_interaction(admin_user_id, guild_id, channel_id, target_user_id)

      with_mocks([
        {Nostrum.Api.User, [],
         [
           get: fn user_id ->
             cond do
               user_id == admin_user_id or user_id == to_string(admin_user_id) ->
                 {:ok, %{id: admin_user_id, username: "TestAdmin"}}
               true ->
                 {:error, :not_found}
             end
           end
         ]},
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.embeds != nil
             embed = hd(response.data.embeds)
             assert String.contains?(embed.title, "Dole Unbanned")
             assert String.contains?(embed.description, "TargetUser")
             {:ok}
           end
         ]}
      ]) do
        Admin.handle(interaction)
      end

      {:ok, user} = User.get_user_by_discord_id(target_user_id)
      assert user.dole_banned == false
    end

    test "dole-unban fails when target has no account" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)

      interaction = create_dole_unban_interaction(admin_user_id, guild_id, channel_id, target_user_id)

      with_mocks([
        {Nostrum.Api.User, [],
         [
           get: fn user_id ->
             cond do
               user_id == admin_user_id or user_id == to_string(admin_user_id) ->
                 {:ok, %{id: admin_user_id, username: "TestAdmin"}}
               true ->
                 {:error, :not_found}
             end
           end
         ]},
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.content != nil
             assert String.contains?(response.data.content, "That user")
             {:ok}
           end
         ]}
      ]) do
        Admin.handle(interaction)
      end
    end
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `mix test test/stackcoin/bot/discord/admin_dole_ban_test.exs`
Expected: FAIL -- subcommands not implemented yet

**Step 3: Add subcommand definitions to Admin.definition/0**

In `lib/stackcoin/bot/discord/admin.ex:15-73`, add two new subcommand entries to the `options` list, after the `unban` subcommand (after line 69):

```elixir
%{
  type: ApplicationCommandOptionType.sub_command(),
  name: "dole-ban",
  description: "Ban a user from collecting dole",
  options: [
    %{
      type: ApplicationCommandOptionType.user(),
      name: "user",
      description: "User to dole-ban",
      required: true
    }
  ]
},
%{
  type: ApplicationCommandOptionType.sub_command(),
  name: "dole-unban",
  description: "Remove dole ban from a user",
  options: [
    %{
      type: ApplicationCommandOptionType.user(),
      name: "user",
      description: "User to dole-unban",
      required: true
    }
  ]
}
```

**Step 4: Add subcommand handlers**

Add after the existing `handle_subcommand("unban", ...)` clause (after line 131):

```elixir
defp handle_subcommand("dole-ban", interaction) do
  with {:ok, target_user_id} <- get_user_option_from_subcommand_result(interaction) do
    dole_ban_user(target_user_id, interaction)
  else
    {:error, reason} ->
      Commands.send_error_response(interaction, reason)
  end
end

defp handle_subcommand("dole-unban", interaction) do
  with {:ok, target_user_id} <- get_user_option_from_subcommand_result(interaction) do
    dole_unban_user(target_user_id, interaction)
  else
    {:error, reason} ->
      Commands.send_error_response(interaction, reason)
  end
end
```

Note: `get_ban_user` and `get_unban_user` are identical private functions. For dole-ban/dole-unban, reuse the existing `get_user_option_from_subcommand/1` helper. Add a small wrapper:

```elixir
defp get_user_option_from_subcommand_result(interaction) do
  case get_user_option_from_subcommand(interaction) do
    nil -> {:error, :missing_user}
    user_id when is_integer(user_id) -> {:ok, user_id}
    _ -> {:error, :invalid_user}
  end
end
```

**Step 5: Add action functions and response helpers**

Add after the existing `send_unban_success_response/2` (after line 327):

```elixir
defp dole_ban_user(target_user_id, interaction) do
  case User.admin_dole_ban_user(interaction.user.id, target_user_id) do
    {:ok, user} ->
      send_dole_ban_success_response(interaction, user)

    {:error, :not_admin} ->
      Commands.send_error_response(interaction, :not_admin)

    {:error, reason} ->
      Commands.send_error_response(interaction, reason)
  end
end

defp send_dole_ban_success_response(interaction, user) do
  Api.create_interaction_response(interaction, %{
    type: InteractionCallbackType.channel_message_with_source(),
    data: %{
      embeds: [
        %{
          title: "#{Commands.stackcoin_emoji()} User Dole Banned",
          description: "**#{user.username}** has been banned from collecting dole.",
          color: Commands.stackcoin_color()
        }
      ]
    }
  })
end

defp dole_unban_user(target_user_id, interaction) do
  case User.admin_dole_unban_user(interaction.user.id, target_user_id) do
    {:ok, user} ->
      send_dole_unban_success_response(interaction, user)

    {:error, :not_admin} ->
      Commands.send_error_response(interaction, :not_admin)

    {:error, reason} ->
      Commands.send_error_response(interaction, reason)
  end
end

defp send_dole_unban_success_response(interaction, user) do
  Api.create_interaction_response(interaction, %{
    type: InteractionCallbackType.channel_message_with_source(),
    data: %{
      embeds: [
        %{
          title: "#{Commands.stackcoin_emoji()} User Dole Unbanned",
          description: "**#{user.username}** has been unbanned from collecting dole.",
          color: Commands.stackcoin_color()
        }
      ]
    }
  })
end
```

**Step 6: Run tests to verify they pass**

Run: `mix test test/stackcoin/bot/discord/admin_dole_ban_test.exs`
Expected: All tests PASS

**Step 7: Commit**

```bash
git add lib/stackcoin/bot/discord/admin.ex test/stackcoin/bot/discord/admin_dole_ban_test.exs
git commit -m "Add /admin dole-ban and /admin dole-unban commands"
```

---

### Task 8: Run full test suite

**Step 1: Run all tests**

Run: `mix test`
Expected: All tests PASS

**Step 2: Fix any failures**

If existing tests fail due to the new `dole_banned` field, check `test/support/discord_utils.ex:85-92` -- the manual Reserve user insert may need `dole_banned: false` added.

**Step 3: Commit any fixes**

```bash
git add -A
git commit -m "Fix any test compatibility issues with dole_banned field"
```

---

### Task 9: Re-register Discord commands

After deploying, run:
```bash
mix commands.create.global
```
or for guild-specific:
```bash
mix commands.create.guild <guild_id>
```

This pushes the updated `/admin` command definition (with the new `dole-ban` and `dole-unban` subcommands) to Discord.
