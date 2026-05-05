# Preauthorization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow bots to withdraw STK from users automatically after a one-time approval, with rolling-window rate limits.

**Architecture:** New `preauthorizations` table in StackCoin tracks approvals. The existing `POST /api/user/:id/request` endpoint gains an optional `use_preauth` flag that does an atomic transfer instead of creating a pending request. Discord DMs handle approval/revocation. The stackcoin-python SDK and LuckyPot are updated to use preauths.

**Tech Stack:** Elixir/Phoenix (StackCoin), Python (stackcoin-python SDK, LuckyPot), SQLite, Ecto, Nostrum (Discord), pytest (e2e)

**Spec:** `docs/superpowers/specs/2026-05-04-preauthorization-design.md`

---

### Task 1: Database Migration

**Files:**
- Create: `priv/repo/migrations/YYYYMMDDHHMMSS_create_preauthorizations.exs`

- [ ] **Step 1: Create the migration file**

Run `mix ecto.gen.migration create_preauthorizations` to generate the file, then replace its contents with:

```elixir
defmodule StackCoin.Repo.Migrations.CreatePreauthorizations do
  use Ecto.Migration

  def change do
    create table(:preauthorization) do
      add(:bot_user_id, references(:user, on_delete: :delete_all), null: false)
      add(:user_id, references(:user, on_delete: :delete_all), null: false)
      add(:max_amount, :integer, null: false,
        check: %{name: "preauth_max_amount_positive", expr: "max_amount > 0"})
      add(:window_hours, :integer, null: false,
        check: %{name: "preauth_window_hours_positive", expr: "window_hours > 0"})
      add(:status, :string, null: false)
      add(:requested_at, :naive_datetime, null: false)
      add(:approved_at, :naive_datetime)
      add(:revoked_at, :naive_datetime)

      timestamps(type: :utc_datetime)
    end

    create(index(:preauthorization, [:bot_user_id]))
    create(index(:preauthorization, [:user_id]))
    create(index(:preauthorization, [:status]))

    # Only one active or pending preauth per bot+user pair
    create(
      unique_index(:preauthorization, [:bot_user_id, :user_id],
        where: "status IN ('pending', 'active')",
        name: :preauthorization_bot_user_active_unique
      )
    )

    # Add preauthorization_id to existing request table
    alter table(:request) do
      add(:preauthorization_id, references(:preauthorization, on_delete: :nilify_all))
    end

    create(index(:request, [:preauthorization_id]))
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `mix ecto.migrate`
Expected: Migration succeeds, no errors.

- [ ] **Step 3: Commit**

```
git add priv/repo/migrations/*_create_preauthorizations.exs
git commit -m "feat: add preauthorizations migration"
```

---

### Task 2: Preauthorization Schema

**Files:**
- Create: `lib/stackcoin/schema/preauthorization.ex`
- Modify: `lib/stackcoin/schema/request.ex`

- [ ] **Step 1: Create the Preauthorization schema**

```elixir
defmodule StackCoin.Schema.Preauthorization do
  use Ecto.Schema
  import Ecto.Changeset

  schema "preauthorization" do
    field(:max_amount, :integer)
    field(:window_hours, :integer)
    field(:status, :string)
    field(:requested_at, :naive_datetime)
    field(:approved_at, :naive_datetime)
    field(:revoked_at, :naive_datetime)

    belongs_to(:bot_user, StackCoin.Schema.User, foreign_key: :bot_user_id)
    belongs_to(:user, StackCoin.Schema.User, foreign_key: :user_id)

    timestamps(type: :utc_datetime)
  end

  def changeset(preauth, attrs) do
    preauth
    |> cast(attrs, [
      :bot_user_id,
      :user_id,
      :max_amount,
      :window_hours,
      :status,
      :requested_at,
      :approved_at,
      :revoked_at
    ])
    |> validate_required([:bot_user_id, :user_id, :max_amount, :window_hours, :status, :requested_at])
    |> validate_inclusion(:status, ["pending", "active", "revoked"])
    |> validate_number(:max_amount, greater_than: 0)
    |> validate_number(:window_hours, greater_than: 0)
    |> validate_different_users()
  end

  defp validate_different_users(changeset) do
    bot_user_id = get_field(changeset, :bot_user_id)
    user_id = get_field(changeset, :user_id)

    if bot_user_id && user_id && bot_user_id == user_id do
      add_error(changeset, :user_id, "cannot be the same as bot_user_id")
    else
      changeset
    end
  end
end
```

- [ ] **Step 2: Add `preauthorization_id` to the Request schema**

In `lib/stackcoin/schema/request.ex`, add after the `belongs_to(:transaction, ...)` line:

```elixir
belongs_to(:preauthorization, StackCoin.Schema.Preauthorization, foreign_key: :preauthorization_id)
```

And add `:preauthorization_id` to the cast fields list in `changeset/2`.

- [ ] **Step 3: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: Compiles with no errors.

- [ ] **Step 4: Commit**

```
git add lib/stackcoin/schema/preauthorization.ex lib/stackcoin/schema/request.ex
git commit -m "feat: add Preauthorization schema and link to Request"
```

---

### Task 3: Core Preauthorization Logic — Tests First

**Files:**
- Create: `test/stackcoin/core/preauthorization_test.exs`
- Create: `lib/stackcoin/core/preauthorization.ex`

- [ ] **Step 1: Write the core preauth tests**

Create `test/stackcoin/core/preauthorization_test.exs`:

```elixir
defmodule StackCoin.Core.PreauthorizationTest do
  use StackCoin.DataCase

  alias StackCoin.Core.{Preauthorization, User, Bot, Reserve, Bank}

  setup do
    # Create reserve and fund it
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 0)
    {:ok, owner} = User.create_user_account("100", "Owner", balance: 0)
    {:ok, _pump} = Reserve.pump_reserve(owner.id, 5000, "Test funding")

    # Create a bot user
    {:ok, bot} = Bot.create_bot_user("100", "TestBot")
    {:ok, _txn} = Bank.transfer_between_users(1, bot.user.id, 500, "Bot funding")

    # Create a regular user
    {:ok, user} = User.create_user_account("200", "TestUser", balance: 0)
    {:ok, _txn} = Bank.transfer_between_users(1, user.id, 500, "User funding")

    %{bot: bot, user: user, owner: owner}
  end

  describe "create_preauth/4" do
    test "creates a pending preauth", %{bot: bot, user: user} do
      assert {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 24)
      assert preauth.status == "pending"
      assert preauth.max_amount == 10
      assert preauth.window_hours == 24
      assert preauth.bot_user_id == bot.user.id
      assert preauth.user_id == user.id
      assert preauth.requested_at != nil
      assert preauth.approved_at == nil
    end

    test "rejects duplicate active/pending preauth", %{bot: bot, user: user} do
      {:ok, _preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 24)
      assert {:error, :preauth_already_exists} = Preauthorization.create_preauth(bot.user.id, user.id, 20, 48)
    end

    test "allows new preauth after revoking old one", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 24)
      {:ok, _approved} = Preauthorization.approve_preauth(preauth.id)
      {:ok, _revoked} = Preauthorization.revoke_preauth(preauth.id)
      assert {:ok, new_preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 20, 48)
      assert new_preauth.max_amount == 20
    end

    test "rejects non-bot user as bot_user_id", %{user: user} do
      {:ok, other_user} = User.create_user_account("300", "Other", balance: 0)
      assert {:error, :not_bot_user} = Preauthorization.create_preauth(other_user.id, user.id, 10, 24)
    end

    test "rejects invalid max_amount", %{bot: bot, user: user} do
      assert {:error, _} = Preauthorization.create_preauth(bot.user.id, user.id, 0, 24)
      assert {:error, _} = Preauthorization.create_preauth(bot.user.id, user.id, -5, 24)
    end

    test "rejects invalid window_hours", %{bot: bot, user: user} do
      assert {:error, _} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 0)
    end
  end

  describe "approve_preauth/1" do
    test "approves a pending preauth", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 24)
      assert {:ok, approved} = Preauthorization.approve_preauth(preauth.id)
      assert approved.status == "active"
      assert approved.approved_at != nil
    end

    test "rejects approving non-pending preauth", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 24)
      {:ok, _approved} = Preauthorization.approve_preauth(preauth.id)
      assert {:error, :preauth_not_pending} = Preauthorization.approve_preauth(preauth.id)
    end
  end

  describe "revoke_preauth/1" do
    test "revokes an active preauth", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 24)
      {:ok, _approved} = Preauthorization.approve_preauth(preauth.id)
      assert {:ok, revoked} = Preauthorization.revoke_preauth(preauth.id)
      assert revoked.status == "revoked"
      assert revoked.revoked_at != nil
    end

    test "rejects revoking a pending preauth", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 24)
      assert {:error, :preauth_not_active} = Preauthorization.revoke_preauth(preauth.id)
    end
  end

  describe "delete_preauth/1" do
    test "hard-deletes a pending preauth", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 24)
      assert {:ok, _} = Preauthorization.delete_preauth(preauth.id)
      assert {:error, :preauth_not_found} = Preauthorization.get_preauth(preauth.id)
    end

    test "rejects deleting an active preauth", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 24)
      {:ok, _} = Preauthorization.approve_preauth(preauth.id)
      assert {:error, :preauth_not_pending} = Preauthorization.delete_preauth(preauth.id)
    end
  end

  describe "get_remaining_budget/1" do
    test "fresh preauth has full budget", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 24)
      {:ok, _} = Preauthorization.approve_preauth(preauth.id)
      assert {:ok, 10} = Preauthorization.get_remaining_budget(preauth.id)
    end
  end

  describe "get_active_preauth/2" do
    test "returns active preauth for bot+user", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 24)
      {:ok, _} = Preauthorization.approve_preauth(preauth.id)
      assert {:ok, found} = Preauthorization.get_active_preauth(bot.user.id, user.id)
      assert found.id == preauth.id
    end

    test "returns error when no active preauth", %{bot: bot, user: user} do
      assert {:error, :no_active_preauth} = Preauthorization.get_active_preauth(bot.user.id, user.id)
    end

    test "returns error for revoked preauth", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 24)
      {:ok, _} = Preauthorization.approve_preauth(preauth.id)
      {:ok, _} = Preauthorization.revoke_preauth(preauth.id)
      assert {:error, :no_active_preauth} = Preauthorization.get_active_preauth(bot.user.id, user.id)
    end
  end

  describe "list_preauths/1" do
    test "lists all preauths for a bot", %{bot: bot, user: user} do
      {:ok, _} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 24)
      {:ok, preauths} = Preauthorization.list_preauths(bot.user.id)
      assert length(preauths) == 1
    end

    test "filters by user_id", %{bot: bot, user: user} do
      {:ok, other_user} = User.create_user_account("400", "Other", balance: 0)
      {:ok, _} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 24)
      {:ok, preauths} = Preauthorization.list_preauths(bot.user.id, user_id: other_user.id)
      assert length(preauths) == 0
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/stackcoin/core/preauthorization_test.exs`
Expected: All tests fail (module not found).

- [ ] **Step 3: Implement `Preauthorization` core module**

Create `lib/stackcoin/core/preauthorization.ex`:

```elixir
defmodule StackCoin.Core.Preauthorization do
  @moduledoc """
  Preauthorization management — create, approve, revoke, and budget-check.
  """

  alias StackCoin.Repo
  alias StackCoin.Schema
  alias StackCoin.Core.{Bot, Event}
  import Ecto.Query

  def create_preauth(bot_user_id, user_id, max_amount, window_hours) do
    with {:ok, _bot} <- validate_is_bot(bot_user_id),
         :ok <- check_no_existing_preauth(bot_user_id, user_id) do
      attrs = %{
        bot_user_id: bot_user_id,
        user_id: user_id,
        max_amount: max_amount,
        window_hours: window_hours,
        status: "pending",
        requested_at: NaiveDateTime.utc_now()
      }

      case Repo.insert(Schema.Preauthorization.changeset(%Schema.Preauthorization{}, attrs)) do
        {:ok, preauth} ->
          preauth = Repo.preload(preauth, [:bot_user, :user])

          for uid <- [bot_user_id, user_id] do
            Event.create_event("preauth.created", uid, %{
              preauth_id: preauth.id,
              bot_user_id: bot_user_id,
              user_id: user_id,
              max_amount: max_amount,
              window_hours: window_hours
            })
          end

          {:ok, preauth}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def get_preauth(preauth_id) do
    case Repo.get(Schema.Preauthorization, preauth_id) do
      nil -> {:error, :preauth_not_found}
      preauth -> {:ok, Repo.preload(preauth, [:bot_user, :user])}
    end
  end

  def approve_preauth(preauth_id) do
    with {:ok, preauth} <- get_preauth(preauth_id),
         :ok <- validate_status(preauth, "pending") do
      attrs = %{status: "active", approved_at: NaiveDateTime.utc_now()}

      case preauth |> Schema.Preauthorization.changeset(attrs) |> Repo.update() do
        {:ok, updated} ->
          for uid <- [preauth.bot_user_id, preauth.user_id] do
            Event.create_event("preauth.approved", uid, %{
              preauth_id: preauth.id,
              bot_user_id: preauth.bot_user_id,
              user_id: preauth.user_id
            })
          end

          {:ok, Repo.preload(updated, [:bot_user, :user], force: true)}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def revoke_preauth(preauth_id) do
    with {:ok, preauth} <- get_preauth(preauth_id),
         :ok <- validate_active(preauth) do
      attrs = %{status: "revoked", revoked_at: NaiveDateTime.utc_now()}

      case preauth |> Schema.Preauthorization.changeset(attrs) |> Repo.update() do
        {:ok, updated} ->
          for uid <- [preauth.bot_user_id, preauth.user_id] do
            Event.create_event("preauth.revoked", uid, %{
              preauth_id: preauth.id,
              bot_user_id: preauth.bot_user_id,
              user_id: preauth.user_id
            })
          end

          {:ok, Repo.preload(updated, [:bot_user, :user], force: true)}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def delete_preauth(preauth_id) do
    with {:ok, preauth} <- get_preauth(preauth_id),
         :ok <- validate_status(preauth, "pending") do
      Repo.delete(preauth)
    end
  end

  def get_active_preauth(bot_user_id, user_id) do
    query =
      from(p in Schema.Preauthorization,
        where: p.bot_user_id == ^bot_user_id and p.user_id == ^user_id and p.status == "active",
        preload: [:bot_user, :user]
      )

    case Repo.one(query) do
      nil -> {:error, :no_active_preauth}
      preauth -> {:ok, preauth}
    end
  end

  def list_preauths(bot_user_id, opts \\ []) do
    user_id = Keyword.get(opts, :user_id)

    query =
      from(p in Schema.Preauthorization,
        where: p.bot_user_id == ^bot_user_id,
        order_by: [desc: p.requested_at],
        preload: [:bot_user, :user]
      )

    query =
      if user_id do
        from(p in query, where: p.user_id == ^user_id)
      else
        query
      end

    {:ok, Repo.all(query)}
  end

  def get_remaining_budget(preauth_id) do
    with {:ok, preauth} <- get_preauth(preauth_id) do
      used = get_used_amount(preauth)
      {:ok, max(preauth.max_amount - used, 0)}
    end
  end

  @doc """
  Check budget and return remaining for a preauth, given a proposed amount.
  Returns {:ok, remaining_after} or {:error, :preauth_limit_exceeded}.
  """
  def check_budget(preauth, amount) do
    used = get_used_amount(preauth)

    if used + amount <= preauth.max_amount do
      {:ok, preauth.max_amount - (used + amount)}
    else
      {:error, :preauth_limit_exceeded}
    end
  end

  defp get_used_amount(preauth) do
    cutoff =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-preauth.window_hours * 3600, :second)

    query =
      from(r in Schema.Request,
        where:
          r.preauthorization_id == ^preauth.id and
            r.status == "accepted" and
            r.requested_at > ^cutoff,
        select: coalesce(sum(r.amount), 0)
      )

    Repo.one(query)
  end

  defp validate_is_bot(user_id) do
    case Repo.get_by(Schema.BotUser, user_id: user_id) do
      nil -> {:error, :not_bot_user}
      bot -> {:ok, bot}
    end
  end

  defp check_no_existing_preauth(bot_user_id, user_id) do
    query =
      from(p in Schema.Preauthorization,
        where:
          p.bot_user_id == ^bot_user_id and
            p.user_id == ^user_id and
            p.status in ["pending", "active"]
      )

    case Repo.one(query) do
      nil -> :ok
      _existing -> {:error, :preauth_already_exists}
    end
  end

  defp validate_status(preauth, expected) do
    if preauth.status == expected do
      :ok
    else
      {:error, :"preauth_not_#{expected}"}
    end
  end

  defp validate_active(preauth) do
    if preauth.status == "active" do
      :ok
    else
      {:error, :preauth_not_active}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/stackcoin/core/preauthorization_test.exs`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```
git add lib/stackcoin/core/preauthorization.ex test/stackcoin/core/preauthorization_test.exs
git commit -m "feat: core preauthorization logic with tests"
```

---

### Task 4: Preauth Event Types

**Files:**
- Modify: `lib/stackcoin/core/event_data.ex`

- [ ] **Step 1: Add three new event types**

Add to the end of `lib/stackcoin/core/event_data.ex`, before the closing `end`:

```elixir
defevent "preauth.created", PreauthCreated do
  field(:preauth_id, :integer, required: true, description: "Preauthorization ID")
  field(:bot_user_id, :integer, required: true, description: "Bot user ID")
  field(:user_id, :integer, required: true, description: "Target user ID")
  field(:max_amount, :integer, required: true, description: "Max amount per window")
  field(:window_hours, :integer, required: true, description: "Rolling window in hours")
end

defevent "preauth.approved", PreauthApproved do
  field(:preauth_id, :integer, required: true, description: "Preauthorization ID")
  field(:bot_user_id, :integer, required: true, description: "Bot user ID")
  field(:user_id, :integer, required: true, description: "Target user ID")
end

defevent "preauth.revoked", PreauthRevoked do
  field(:preauth_id, :integer, required: true, description: "Preauthorization ID")
  field(:bot_user_id, :integer, required: true, description: "Bot user ID")
  field(:user_id, :integer, required: true, description: "Target user ID")
end
```

- [ ] **Step 2: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: Compiles cleanly. The `defevent` macro auto-generates schemas and registry entries.

- [ ] **Step 3: Verify existing tests still pass**

Run: `mix test`
Expected: All tests pass (no regressions).

- [ ] **Step 4: Commit**

```
git add lib/stackcoin/core/event_data.ex
git commit -m "feat: add preauth event types (created, approved, revoked)"
```

---

### Task 5: Preauth-Aware Request Creation — Tests First

**Files:**
- Create: `test/stackcoin/core/preauth_request_test.exs`
- Modify: `lib/stackcoin/core/request.ex`

- [ ] **Step 1: Write tests for preauth request flow**

Create `test/stackcoin/core/preauth_request_test.exs`:

```elixir
defmodule StackCoin.Core.PreauthRequestTest do
  use StackCoin.DataCase

  alias StackCoin.Core.{Preauthorization, Request, User, Bot, Reserve, Bank}

  setup do
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 0)
    {:ok, owner} = User.create_user_account("100", "Owner", balance: 0)
    {:ok, _pump} = Reserve.pump_reserve(owner.id, 5000, "Test funding")

    {:ok, bot} = Bot.create_bot_user("100", "TestBot")
    {:ok, _txn} = Bank.transfer_between_users(1, bot.user.id, 500, "Bot funding")

    {:ok, user} = User.create_user_account("200", "TestUser", balance: 0)
    {:ok, _txn} = Bank.transfer_between_users(1, user.id, 500, "User funding")

    # Create and approve a preauth: 10 STK per 24 hours
    {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 24)
    {:ok, preauth} = Preauthorization.approve_preauth(preauth.id)

    %{bot: bot, user: user, preauth: preauth}
  end

  describe "create_request_with_preauth/5" do
    test "instant transfer with active preauth", %{bot: bot, user: user, preauth: preauth} do
      {:ok, request} =
        Request.create_request_with_preauth(bot.user.id, user.id, 5, "Test label")

      assert request.status == "accepted"
      assert request.preauthorization_id == preauth.id
      assert request.transaction_id != nil
      assert request.amount == 5

      # User balance should have decreased
      {:ok, updated_user} = User.get_user_by_id(user.id)
      assert updated_user.balance == 495

      # Bot balance should have increased
      {:ok, updated_bot} = User.get_user_by_id(bot.user.id)
      assert updated_bot.balance == 505
    end

    test "budget decreases after transfer", %{bot: bot, user: user} do
      {:ok, _} = Request.create_request_with_preauth(bot.user.id, user.id, 5, "First")
      {:ok, _} = Request.create_request_with_preauth(bot.user.id, user.id, 5, "Second")

      # Budget should now be 0
      assert {:error, :preauth_limit_exceeded} =
               Request.create_request_with_preauth(bot.user.id, user.id, 1, "Third")
    end

    test "exact max_amount succeeds", %{bot: bot, user: user} do
      {:ok, request} =
        Request.create_request_with_preauth(bot.user.id, user.id, 10, "Max")

      assert request.status == "accepted"
    end

    test "exceeds max_amount fails", %{bot: bot, user: user} do
      assert {:error, :preauth_limit_exceeded} =
               Request.create_request_with_preauth(bot.user.id, user.id, 11, "Over")
    end

    test "insufficient balance returns error", %{bot: bot, user: user} do
      # Drain user's balance
      {:ok, _txn} = Bank.transfer_between_users(user.id, 1, 500, "drain")

      assert {:error, :insufficient_balance} =
               Request.create_request_with_preauth(bot.user.id, user.id, 5, "No funds")
    end

    test "no active preauth falls back to pending request", %{bot: bot} do
      {:ok, other_user} = User.create_user_account("300", "Other", balance: 0)
      {:ok, _txn} = Bank.transfer_between_users(1, other_user.id, 100, "Fund other")

      {:ok, request} =
        Request.create_request_with_preauth(bot.user.id, other_user.id, 5, "Fallback")

      assert request.status == "pending"
      assert request.preauthorization_id == nil
    end

    test "revoked preauth falls back to pending", %{bot: bot, user: user, preauth: preauth} do
      {:ok, _} = Preauthorization.revoke_preauth(preauth.id)

      {:ok, request} =
        Request.create_request_with_preauth(bot.user.id, user.id, 5, "After revoke")

      assert request.status == "pending"
      assert request.preauthorization_id == nil
    end

    test "pending preauth falls back to pending request", %{bot: bot} do
      {:ok, other_user} = User.create_user_account("400", "PendingUser", balance: 0)
      {:ok, _txn} = Bank.transfer_between_users(1, other_user.id, 100, "Fund")
      {:ok, _pending_preauth} = Preauthorization.create_preauth(bot.user.id, other_user.id, 10, 24)

      {:ok, request} =
        Request.create_request_with_preauth(bot.user.id, other_user.id, 5, "Pending preauth")

      assert request.status == "pending"
    end

    test "preauth request links via preauthorization_id", %{bot: bot, user: user, preauth: preauth} do
      {:ok, request} =
        Request.create_request_with_preauth(bot.user.id, user.id, 5, "Linked")

      assert request.preauthorization_id == preauth.id
      loaded = StackCoin.Repo.preload(request, :preauthorization)
      assert loaded.preauthorization.id == preauth.id
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/stackcoin/core/preauth_request_test.exs`
Expected: All fail (`create_request_with_preauth` undefined).

- [ ] **Step 3: Implement `create_request_with_preauth`**

Add to `lib/stackcoin/core/request.ex`:

```elixir
@doc """
Creates a request using preauth if available. If the bot has an active preauth
with budget remaining, does an atomic transfer (request created as "accepted").
Otherwise falls back to a normal pending request.
"""
def create_request_with_preauth(requester_id, responder_id, amount, label \\ nil) do
  case Preauthorization.get_active_preauth(requester_id, responder_id) do
    {:ok, preauth} ->
      case Preauthorization.check_budget(preauth, amount) do
        {:ok, _remaining} ->
          execute_preauth_transfer(preauth, requester_id, responder_id, amount, label)

        {:error, :preauth_limit_exceeded} ->
          {:error, :preauth_limit_exceeded}
      end

    {:error, :no_active_preauth} ->
      create_request(requester_id, responder_id, amount, label)
  end
end
```

And add the private function:

```elixir
defp execute_preauth_transfer(preauth, requester_id, responder_id, amount, label) do
  result =
    Repo.transaction(fn ->
      # Transfer funds: responder (user) pays requester (bot)
      case Bank.transfer_between_users(responder_id, requester_id, amount, label) do
        {:ok, transaction} ->
          request_attrs = %{
            requester_id: requester_id,
            responder_id: responder_id,
            status: "accepted",
            amount: amount,
            requested_at: NaiveDateTime.utc_now(),
            resolved_at: NaiveDateTime.utc_now(),
            transaction_id: transaction.id,
            preauthorization_id: preauth.id,
            label: label
          }

          case Repo.insert(Schema.Request.changeset(%Schema.Request{}, request_attrs)) do
            {:ok, request} ->
              {request, transaction}

            {:error, changeset} ->
              Repo.rollback(changeset)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)

  case result do
    {:ok, {request, transaction}} ->
      preloaded = Repo.preload(request, [:requester, :responder, :transaction, :preauthorization])

      for user_id <- [requester_id, responder_id] do
        Event.create_event("request.accepted", user_id, %{
          request_id: request.id,
          status: "accepted",
          transaction_id: transaction.id,
          amount: amount
        })
      end

      {:ok, preloaded}

    {:error, reason} ->
      {:error, reason}
  end
end
```

Also add `alias StackCoin.Core.Preauthorization` at the top of the module.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/stackcoin/core/preauth_request_test.exs`
Expected: All tests pass.

- [ ] **Step 5: Run full suite**

Run: `mix test`
Expected: All tests pass, no regressions.

- [ ] **Step 6: Commit**

```
git add lib/stackcoin/core/request.ex test/stackcoin/core/preauth_request_test.exs
git commit -m "feat: preauth-aware request creation with tests"
```

---

### Task 6: Preauth API Endpoints — Tests First

**Files:**
- Create: `test/stackcoin_web/controllers/preauth_controller_test.exs`
- Create: `lib/stackcoin_web/controllers/preauth_controller.ex`
- Modify: `lib/stackcoin_web/router.ex`
- Modify: `lib/stackcoin_web/controllers/request_controller.ex`

- [ ] **Step 1: Write controller tests for preauth CRUD and use_preauth on request creation**

Create `test/stackcoin_web/controllers/preauth_controller_test.exs` with tests covering:
- `POST /api/user/:user_id/preauth` — success, duplicate rejection, non-bot caller, invalid params
- `GET /api/preauths` — list all, filter by user_id
- `GET /api/preauth/:id` — success with remaining budget, not found
- `POST /api/user/:user_id/request` with `use_preauth: true` — instant transfer, budget exceeded, no preauth fallback

Use the same setup pattern as `request_controller_test.exs` (mock Nostrum, create reserve, bot, user).

- [ ] **Step 2: Implement `PreauthController`**

Create `lib/stackcoin_web/controllers/preauth_controller.ex` with `create/2`, `index/2`, and `show/2` actions.

- [ ] **Step 3: Add routes to router**

In `lib/stackcoin_web/router.ex`, inside the authenticated API scope, add:

```elixir
post("/user/:user_id/preauth", StackCoinWeb.PreauthController, :create)
get("/preauths", StackCoinWeb.PreauthController, :index)
get("/preauth/:id", StackCoinWeb.PreauthController, :show)
```

- [ ] **Step 4: Modify `RequestController.execute_create` for `use_preauth`**

In `lib/stackcoin_web/controllers/request_controller.ex`, modify `execute_create/2` to check for `use_preauth` in params. When true, call `Request.create_request_with_preauth` instead of `Request.create_request`. Handle `:preauth_limit_exceeded` as a 400 error.

When the preauth path returns an accepted request, include `transaction_id` in the response.

- [ ] **Step 5: Add OpenAPI schemas for preauth**

Add to `lib/stackcoin_web/schemas.ex`:
- `CreatePreauthParams` — `{max_amount, window_hours}`
- `PreauthResponse` — `{id, bot_user_id, user_id, max_amount, window_hours, status, requested_at, approved_at, revoked_at, remaining_budget}`
- `PreauthsResponse` — `{preauths: [...], pagination: {...}}`

- [ ] **Step 6: Run tests**

Run: `mix test test/stackcoin_web/controllers/preauth_controller_test.exs`
Expected: All pass.

- [ ] **Step 7: Run full suite**

Run: `mix test`
Expected: All pass.

- [ ] **Step 8: Commit**

```
git add lib/stackcoin_web/controllers/preauth_controller.ex test/stackcoin_web/controllers/preauth_controller_test.exs lib/stackcoin_web/router.ex lib/stackcoin_web/controllers/request_controller.ex lib/stackcoin_web/schemas.ex
git commit -m "feat: preauth API endpoints and use_preauth on request creation"
```

---

### Task 7: Discord Preauth DM Handler

**Files:**
- Create: `lib/stackcoin/bot/discord/preauth.ex`
- Create: `test/stackcoin/bot/discord/preauth_test.exs`
- Modify: `lib/stackcoin/bot/discord.ex` (consumer — route preauth button interactions)

- [ ] **Step 1: Write tests for parse_custom_id and notification logic**

Create `test/stackcoin/bot/discord/preauth_test.exs`:

```elixir
defmodule StackCoin.Bot.Discord.PreauthTest do
  use StackCoin.DataCase
  alias StackCoin.Bot.Discord.Preauth

  describe "parse_custom_id/1" do
    test "parses accept custom ID" do
      assert Preauth.parse_custom_id("preauth_accept_42") == {:ok, {:accept, 42}}
    end

    test "parses deny custom ID" do
      assert Preauth.parse_custom_id("preauth_deny_42") == {:ok, {:deny, 42}}
    end

    test "parses revoke custom ID" do
      assert Preauth.parse_custom_id("preauth_revoke_42") == {:ok, {:revoke, 42}}
    end

    test "returns error for invalid" do
      assert Preauth.parse_custom_id("preauth_accept_abc") == {:error, :invalid_custom_id}
      assert Preauth.parse_custom_id("something_else") == {:error, :invalid_custom_id}
    end
  end
end
```

- [ ] **Step 2: Implement `StackCoin.Bot.Discord.Preauth`**

Create `lib/stackcoin/bot/discord/preauth.ex` following the pattern from `lib/stackcoin/bot/discord/request.ex`:
- `send_preauth_notification/1` — DMs the user with preauth details and Accept/Deny buttons
- `send_preauth_transfer_notification/2` — DMs the user on each preauth use with amount, label, remaining budget, and Revoke button
- `handle_preauth_interaction/1` — handles Accept (approve), Deny (delete), and Revoke button presses
- `parse_custom_id/1` — parses `preauth_accept_N`, `preauth_deny_N`, `preauth_revoke_N`

Custom IDs: `preauth_accept_{id}`, `preauth_deny_{id}`, `preauth_revoke_{id}`.

- [ ] **Step 3: Route preauth interactions in the consumer**

In `lib/stackcoin/bot/discord.ex`, add routing for `preauth_accept_`, `preauth_deny_`, and `preauth_revoke_` prefixes in the INTERACTION_CREATE handler, delegating to `Preauth.handle_preauth_interaction/1`.

- [ ] **Step 4: Send preauth notification on creation**

In `lib/stackcoin/core/preauthorization.ex` `create_preauth/4`, after creating the record, call `StackCoin.Bot.Discord.Preauth.send_preauth_notification(preauth)` (same pattern as `Request.create_request` calling `send_request_notification`). Guard with `Application.get_env(:stackcoin, :start_discord, true)`.

- [ ] **Step 5: Send transfer notification on preauth use**

In `lib/stackcoin/core/request.ex` `execute_preauth_transfer/5`, after the successful transaction, call `StackCoin.Bot.Discord.Preauth.send_preauth_transfer_notification(request, remaining_budget)`. This sends the informational DM with the Revoke button. Guard with `Application.get_env(:stackcoin, :start_discord, true)`.

- [ ] **Step 6: Run tests**

Run: `mix test test/stackcoin/bot/discord/preauth_test.exs`
Expected: Pass.

Run: `mix test`
Expected: All pass.

- [ ] **Step 7: Commit**

```
git add lib/stackcoin/bot/discord/preauth.ex test/stackcoin/bot/discord/preauth_test.exs lib/stackcoin/bot/discord.ex lib/stackcoin/core/preauthorization.ex lib/stackcoin/core/request.ex
git commit -m "feat: Discord preauth DM notifications with accept/deny/revoke buttons"
```

---

### Task 8: `/preauths` Slash Command

**Files:**
- Create: `lib/stackcoin/bot/discord/preauths.ex`
- Modify: `lib/stackcoin/bot/discord/commands.ex`
- Modify: `lib/stackcoin/bot/discord.ex`

- [ ] **Step 1: Create the `/preauths` command module**

Create `lib/stackcoin/bot/discord/preauths.ex` with:
- `definition/0` — returns the command definition (no options needed)
- `handle/1` — looks up the calling user's active preauths via `Preauthorization.list_preauths_for_user/1` (new function that queries by `user_id` rather than `bot_user_id`), formats them with bot name, limit, remaining budget, and Revoke buttons

Add `list_preauths_for_user/1` to `lib/stackcoin/core/preauthorization.ex`:

```elixir
def list_preauths_for_user(user_id) do
  query =
    from(p in Schema.Preauthorization,
      where: p.user_id == ^user_id and p.status == "active",
      order_by: [desc: p.approved_at],
      preload: [:bot_user, :user]
    )

  {:ok, Repo.all(query)}
end
```

- [ ] **Step 2: Register in commands.ex**

Add `Preauths.definition()` to the `command_definitions/0` list in `lib/stackcoin/bot/discord/commands.ex`. Add the alias.

- [ ] **Step 3: Route in consumer**

In `lib/stackcoin/bot/discord.ex`, add routing for the `"preauths"` command name in the INTERACTION_CREATE handler.

- [ ] **Step 4: Run full suite**

Run: `mix test`
Expected: All pass.

- [ ] **Step 5: Commit**

```
git add lib/stackcoin/bot/discord/preauths.ex lib/stackcoin/bot/discord/commands.ex lib/stackcoin/bot/discord.ex lib/stackcoin/core/preauthorization.ex
git commit -m "feat: /preauths slash command for listing and revoking preauths"
```

---

### Task 9: stackcoin-python SDK Updates

**Files:**
- Modify: `tmp/stackcoin-python/src/stackcoin/client.py`
- Modify: `tmp/stackcoin-python/src/stackcoin/models.py`

- [ ] **Step 1: Add `use_preauth` param to `create_request`**

In `tmp/stackcoin-python/src/stackcoin/client.py`, modify `create_request`:

```python
async def create_request(
    self,
    to_user_id: int,
    amount: int,
    *,
    label: str | None = None,
    idempotency_key: str | None = None,
    use_preauth: bool = False,
) -> CreateRequestResponse:
    """Create a STK request to another user."""
    body: dict[str, Any] = {"amount": amount}
    if label is not None:
        body["label"] = label
    if use_preauth:
        body["use_preauth"] = True
    headers: dict[str, str] = {}
    if idempotency_key is not None:
        headers["Idempotency-Key"] = idempotency_key
    resp = await self._http.post(
        f"/api/user/{to_user_id}/request",
        json=body,
        headers=headers,
    )
    self._raise_for_error(resp)
    return CreateRequestResponse.model_validate(resp.json())
```

- [ ] **Step 2: Add `transaction_id` to `CreateRequestResponse` model**

In `tmp/stackcoin-python/src/stackcoin/models.py`, add to `CreateRequestResponse`:

```python
transaction_id: int | None = Field(None, description="Transaction ID (set when preauth accepted)")
```

- [ ] **Step 3: Add preauth API methods to client**

Add to the `Client` class:

```python
async def create_preauth(
    self,
    user_id: int,
    max_amount: int,
    window_hours: int,
) -> dict:
    """Request a preauthorization from a user."""
    resp = await self._http.post(
        f"/api/user/{user_id}/preauth",
        json={"max_amount": max_amount, "window_hours": window_hours},
    )
    self._raise_for_error(resp)
    return resp.json()

async def get_preauths(self, *, user_id: int | None = None) -> list[dict]:
    """List preauths for this bot, optionally filtered by user_id."""
    params: dict[str, Any] = {}
    if user_id is not None:
        params["user_id"] = user_id
    resp = await self._http.get("/api/preauths", params=params)
    self._raise_for_error(resp)
    return resp.json().get("preauths", [])
```

- [ ] **Step 4: Commit**

```
git add tmp/stackcoin-python/src/stackcoin/client.py tmp/stackcoin-python/src/stackcoin/models.py
git commit -m "feat: add use_preauth and preauth API methods to stackcoin-python SDK"
```

---

### Task 10: LuckyPot Integration

**Files:**
- Modify: `tmp/LuckyPot/luckypot/stk.py`
- Modify: `tmp/LuckyPot/luckypot/game.py`
- Modify: `tmp/LuckyPot/luckypot/discord/commands.py`

- [ ] **Step 1: Add preauth methods to `stk.py`**

Add to `tmp/LuckyPot/luckypot/stk.py`:

```python
async def create_preauth(
    user_id: int,
    max_amount: int,
    window_hours: int,
) -> dict | None:
    """Request a preauthorization from a user."""
    try:
        return await get_client().create_preauth(
            user_id=user_id,
            max_amount=max_amount,
            window_hours=window_hours,
        )
    except stackcoin.StackCoinError as e:
        logger.error(f"Failed to create preauth for user {user_id}: {e}")
        return None


async def get_preauths(user_id: int | None = None) -> list[dict]:
    """List preauths for this bot."""
    try:
        return await get_client().get_preauths(user_id=user_id)
    except stackcoin.StackCoinError as e:
        logger.error(f"Failed to get preauths: {e}")
        return []
```

- [ ] **Step 2: Add `use_preauth` to `create_request` in `stk.py`**

Modify the existing `create_request` function:

```python
async def create_request(
    to_user_id: int,
    amount: int,
    label: str | None = None,
    idempotency_key: str | None = None,
    use_preauth: bool = False,
) -> dict | None:
    """Create a payment request. Returns response dict or None on failure."""
    try:
        result = await get_client().create_request(
            to_user_id=to_user_id,
            amount=amount,
            label=label,
            idempotency_key=idempotency_key,
            use_preauth=use_preauth,
        )
        return {
            "success": result.success,
            "request_id": result.request_id,
            "amount": result.amount,
            "status": result.status,
            "transaction_id": result.transaction_id,
        }
    except stackcoin.StackCoinError as e:
        logger.error(
            f"Failed to create request for {amount} STK from user {to_user_id}: {e}"
        )
        return None
```

- [ ] **Step 3: Update `enter_pot` in `game.py` to use preauth**

Modify the `stk.create_request` call in `enter_pot` (around line 137) to pass `use_preauth=True`:

```python
req = await stk.create_request(
    to_user_id=stk_user_id,
    amount=POT_ENTRY_COST,
    label=f"LuckyPot entry (pot #{pot_id})",
    idempotency_key=idempotency_key,
    use_preauth=True,
)
```

Then, after the `db.add_entry` call succeeds, check if the request was already accepted (preauth path):

```python
# If preauth resolved the request instantly, confirm the entry now
if req.get("status") == "accepted":
    db.confirm_entry(conn, entry_id)
    if announce_fn:
        pot = db.get_active_pot(conn, guild_id)
        total_pot = 0
        if pot:
            participants = db.get_pot_participants(conn, pot["pot_id"])
            total_pot = sum(p["amount"] for p in participants)
        await announce_fn(
            f"<@{discord_id}> entered the pot! The pot is now at {total_pot} STK. Use `/enter-pot` to enter!"
        )
    return {
        "status": "confirmed",
        "entry_id": entry_id,
        "request_id": request_id,
        "message": f"Entry confirmed! {POT_ENTRY_COST} STK was automatically deducted.",
    }
```

Handle preauth-specific errors from `stk.create_request` — the SDK will raise `StackCoinError` for `preauth_limit_exceeded` and `insufficient_balance`. Catch these in `enter_pot` and return skip results (no ban):

```python
except stackcoin.StackCoinError as e:
    error_msg = str(e)
    if "preauth_limit_exceeded" in error_msg or "insufficient_balance" in error_msg:
        return {
            "status": "skipped",
            "message": f"Could not auto-enter: {error_msg}",
        }
    raise
```

Note: the exact error handling depends on whether `stk.create_request` returns `None` or raises. Currently it returns `None` for all errors. We need to distinguish preauth errors from general failures. The simplest approach: modify `stk.create_request` to raise `StackCoinError` for preauth-specific errors instead of returning `None`.

Actually, looking at the current code, `stk.create_request` catches all `StackCoinError` and returns `None`. For preauth errors, we need the error detail. Update `stk.create_request` to re-raise preauth-specific errors:

```python
except stackcoin.StackCoinError as e:
    error_str = str(e).lower()
    if "preauth_limit_exceeded" in error_str:
        raise
    logger.error(
        f"Failed to create request for {amount} STK from user {to_user_id}: {e}"
    )
    return None
```

And in `enter_pot`, wrap the request call:

```python
try:
    req = await stk.create_request(
        to_user_id=stk_user_id,
        amount=POT_ENTRY_COST,
        label=f"LuckyPot entry (pot #{pot_id})",
        idempotency_key=idempotency_key,
        use_preauth=True,
    )
except stackcoin.StackCoinError:
    return {
        "status": "skipped",
        "message": "Auto-payment limit reached or insufficient balance.",
    }
```

- [ ] **Step 4: Update `/auto-enter` to request preauth**

In `tmp/LuckyPot/luckypot/discord/commands.py`, modify the `AutoEnter` command's `invoke` method. After enabling auto-enter, check for and request a preauth:

```python
if self.enabled:
    # Check if preauth exists
    stk_user = await stk.get_user_by_discord_id(discord_id)
    if stk_user:
        preauths = await stk.get_preauths(user_id=stk_user["id"])
        active = [p for p in preauths if p.get("status") == "active"]
        pending = [p for p in preauths if p.get("status") == "pending"]

        if active:
            container = ui.build_auto_enter_opted_in_with_preauth()
        elif pending:
            container = ui.build_auto_enter_opted_in_pending_preauth()
        else:
            # Request a new preauth
            result = await stk.create_preauth(
                user_id=stk_user["id"],
                max_amount=10,
                window_hours=24,
            )
            if result:
                container = ui.build_auto_enter_opted_in_preauth_requested()
            else:
                container = ui.build_auto_enter_opted_in()
    else:
        container = ui.build_auto_enter_opted_in()
```

Add the new UI builder functions in `tmp/LuckyPot/luckypot/discord/ui.py`:
- `build_auto_enter_opted_in_with_preauth()` — "Auto-enter enabled with automatic payments!"
- `build_auto_enter_opted_in_pending_preauth()` — "Auto-enter enabled! Check your DMs from StackCoin to approve automatic payments."
- `build_auto_enter_opted_in_preauth_requested()` — "Auto-enter enabled! Check your DMs from StackCoin to approve automatic payments."

- [ ] **Step 5: Commit**

```
git add tmp/LuckyPot/luckypot/stk.py tmp/LuckyPot/luckypot/game.py tmp/LuckyPot/luckypot/discord/commands.py tmp/LuckyPot/luckypot/discord/ui.py
git commit -m "feat: LuckyPot preauth integration — auto-enter requests preauth, enter_pot uses use_preauth"
```

---

### Task 11: E2E Tests for Preauth Flow

**Files:**
- Modify: `test/e2e/py/conftest.py`
- Modify: `test/e2e/py/test_luckypot.py`

- [ ] **Step 1: Add preauth test helpers to conftest**

The existing e2e fixtures (`test_context`, `luckypot_db`, `configure_luckypot_stk`) provide everything we need. No conftest changes required unless we need a helper to approve preauths (which in e2e tests we'd do via the StackCoin API since Discord interactions aren't available).

Add a helper fixture or function to directly approve a preauth in the test DB (since we can't click Discord buttons in e2e). The simplest approach: call the StackCoin approve endpoint, or directly update the DB. Since there's no API endpoint for approval (it's Discord-only), we'll update the DB directly via the SQLite e2e database.

Add to conftest:

```python
def _approve_preauth_in_db(port: int, preauth_id: int):
    """Directly approve a preauth in the test database (simulates Discord accept)."""
    db_file = _db_path(port)
    conn = sqlite3.connect(db_file, timeout=10)
    try:
        conn.execute("PRAGMA busy_timeout = 5000")
        conn.execute(
            "UPDATE preauthorization SET status = 'active', approved_at = datetime('now') WHERE id = ?",
            (preauth_id,),
        )
        conn.commit()
    finally:
        conn.close()
```

And a fixture:

```python
@pytest.fixture
def approve_preauth(stackcoin_server):
    """Returns a function that directly approves a preauth in the test DB."""
    def _approve(preauth_id: int):
        _approve_preauth_in_db(stackcoin_server["port"], preauth_id)
    return _approve
```

- [ ] **Step 2: Write e2e preauth tests**

Add a new test class in `test/e2e/py/test_luckypot.py`:

```python
@pytest.mark.asyncio
class TestPreauthFlow:
    @patch("luckypot.game.random.random", return_value=0.99)
    async def test_enter_pot_with_preauth_instant_confirm(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """With active preauth, enter_pot confirms entry immediately."""
        # Create and approve preauth for user1
        preauth = await stk.create_preauth(
            user_id=test_context["user1_id"],
            max_amount=10,
            window_hours=24,
        )
        assert preauth is not None
        approve_preauth(preauth["id"])

        result = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_preauth_guild",
        )
        assert result["status"] == "confirmed"

        # Verify entry is confirmed in LuckyPot DB
        conn = db.get_connection()
        try:
            entry = db.get_entry_by_id(conn, result["entry_id"])
            assert entry["status"] == "confirmed"
        finally:
            conn.close()

    @patch("luckypot.game.random.random", return_value=0.99)
    async def test_enter_pot_without_preauth_falls_back(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Without preauth, enter_pot creates a pending request as usual."""
        result = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_no_preauth_guild",
        )
        assert result["status"] == "pending"

    @patch("luckypot.game.random.random", return_value=0.99)
    async def test_enter_pot_preauth_budget_exceeded(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """When preauth budget is exceeded, entry is skipped (no ban)."""
        preauth = await stk.create_preauth(
            user_id=test_context["user1_id"],
            max_amount=5,
            window_hours=24,
        )
        approve_preauth(preauth["id"])

        # First entry uses 5 STK (full budget)
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_budget_guild",
        )
        assert result1["status"] == "confirmed"

        # Force a new pot so user can enter again
        conn = db.get_connection()
        try:
            pot = db.get_active_pot(conn, "test_budget_guild")
            db.end_pot(conn, pot["pot_id"], test_context["user1_discord_id"], 5, "TEST")
        finally:
            conn.close()

        # Second entry exceeds budget
        result2 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_budget_guild",
        )
        assert result2["status"] == "skipped"

        # Verify no ban
        conn = db.get_connection()
        try:
            ban = db.get_active_ban(conn, test_context["user1_discord_id"], "test_budget_guild")
            assert ban is None
        finally:
            conn.close()

    @patch("luckypot.game.random.random", return_value=0.99)
    async def test_enter_pot_preauth_insufficient_balance(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """When user has preauth but no balance, entry is skipped (no ban)."""
        preauth = await stk.create_preauth(
            user_id=test_context["user1_id"],
            max_amount=10,
            window_hours=24,
        )
        approve_preauth(preauth["id"])

        # Drain user's balance via StackCoin API (send all to bot)
        client = stk.get_client()
        user1_balance = (await client.get_user(test_context["user1_id"])).balance
        if user1_balance > 0:
            # Accept a request from the bot to drain the user
            # Actually, the bot can't drain the user this way. We'll drain via DB.
            # For e2e, manipulate the test DB directly.
            import sqlite3, os
            db_file = os.path.join(os.path.dirname(__file__), f"../../../data/e2e_test_4042.db")
            sconn = sqlite3.connect(db_file, timeout=10)
            sconn.execute("UPDATE user SET balance = 0 WHERE id = ?", (test_context["user1_id"],))
            sconn.commit()
            sconn.close()

        result = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_no_balance_guild",
        )
        assert result["status"] in ("skipped", "error")
```

- [ ] **Step 3: Run e2e tests**

Run from `test/e2e/py/`: `uv run pytest test_luckypot.py -v -k "Preauth"`
Expected: All preauth e2e tests pass.

- [ ] **Step 4: Run full e2e suite**

Run from `test/e2e/py/`: `uv run pytest`
Expected: All tests pass (existing + new).

- [ ] **Step 5: Commit**

```
git add test/e2e/py/conftest.py test/e2e/py/test_luckypot.py
git commit -m "test: e2e tests for preauth flow (instant confirm, budget exceeded, fallback)"
```

---

### Task 12: Add `format_error` Cases and Final Integration

**Files:**
- Modify: `lib/stackcoin/bot/discord/commands.ex`
- Modify: `lib/stackcoin_web/controllers/request_controller.ex`

- [ ] **Step 1: Add error cases to `format_error`**

In `lib/stackcoin/bot/discord/commands.ex`, add to `error_message/1`:

```elixir
:preauth_limit_exceeded ->
  "❌ Preauthorization limit exceeded for this time window."

:preauth_already_exists ->
  "❌ A preauthorization already exists for this bot and user."

:preauth_not_found ->
  "❌ Preauthorization not found."

:no_active_preauth ->
  "❌ No active preauthorization found."

:not_bot_user ->
  "❌ Only bot users can create preauthorizations."
```

- [ ] **Step 2: Handle preauth errors in `ApiHelpers` or inline**

In `request_controller.ex`, make sure `execute_create` handles `:preauth_limit_exceeded` properly:

```elixir
{:error, :preauth_limit_exceeded} ->
  {400, %{error: "preauth_limit_exceeded"}}
```

- [ ] **Step 3: Run full test suite**

Run: `mix test`
Expected: All pass.

- [ ] **Step 4: Commit**

```
git add lib/stackcoin/bot/discord/commands.ex lib/stackcoin_web/controllers/request_controller.ex
git commit -m "feat: error handling for preauth-specific error cases"
```

---

### Task 13: Final Verification

- [ ] **Step 1: Run StackCoin full test suite**

Run: `mix test`
Expected: All tests pass.

- [ ] **Step 2: Run e2e suite**

Run from `test/e2e/py/`: `uv run pytest`
Expected: All tests pass.

- [ ] **Step 3: Verify compilation with no warnings**

Run: `mix compile --warnings-as-errors`
Expected: Clean compilation.

- [ ] **Step 4: Review git log**

Run: `git log --oneline -15`
Verify commits are clean and sequential.
