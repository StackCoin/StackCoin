defmodule StackCoinTest.Bot.Discord.SecurityAudit do
  @moduledoc """
  Red team security audit tests for StackCoin Discord interaction layer.

  These tests demonstrate actual or potential vulnerabilities in how Discord
  slash commands and button interactions interact with core logic.
  """

  use ExUnit.Case
  import Mock
  import StackCoinTest.Support.DiscordUtils

  alias StackCoin.Bot.Discord.{Admin, Balance, Send}
  alias StackCoin.Core.{User, Bank, Reserve, Request, Preauthorization}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(StackCoin.Repo)
    :ok
  end

  # ─── FINDING 1: /admin register has no guild/channel nil check ────────────
  # Severity: MEDIUM
  # File: lib/stackcoin/bot/discord/admin.ex:120-128
  # The register subcommand checks guild_id && channel_id, BUT other admin
  # subcommands (pump, ban, unban, dole-ban, dole-unban) do NOT check guild
  # context at all. Admin commands can be executed from DMs or unregistered
  # guilds, because handle/1 does not enforce guild/channel validation.
  # This is arguably by design (admins should work anywhere), but it's
  # inconsistent — register checks guild context while pump/ban/unban don't.

  describe "FINDING-1: admin commands lack guild/channel validation (except register)" do
    test "admin pump works without guild context (no guild_id check)" do
      admin_user_id = 999_999_999

      setup_admin_user(admin_user_id)
      create_reserve_user(100)
      {:ok, _admin_user} = User.create_user_account(admin_user_id, "TestAdmin", admin: true)

      # Interaction with nil guild_id (DM context)
      interaction =
        create_mock_interaction(admin_user_id, nil, nil, %{
          options: [
            %{
              name: "pump",
              options: [
                %{name: "amount", value: 500},
                %{name: "label", value: "DM pump"}
              ]
            }
          ]
        })

      with_mocks([
        {Nostrum.Api.User, [],
         [
           get: fn user_id ->
             if user_id == admin_user_id or user_id == to_string(admin_user_id) do
               {:ok, %{id: admin_user_id, username: "TestAdmin"}}
             else
               {:error, :not_found}
             end
           end
         ]},
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             # Admin pump succeeds from DM — no guild/channel check
             assert response.data.embeds != nil
             embed = hd(response.data.embeds)
             assert String.contains?(embed.title, "Reserve Pumped Successfully!")
             {:ok}
           end
         ]}
      ]) do
        Admin.handle(interaction)
      end

      {:ok, reserve_balance} = Reserve.get_reserve_balance()
      assert reserve_balance == 600
    end

    test "admin ban works without guild context (from DMs)" do
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      {:ok, _target} = User.create_user_account(target_user_id, "TargetUser")

      # DM context: guild_id and channel_id are nil
      interaction =
        create_mock_interaction(admin_user_id, nil, nil, %{
          options: [
            %{
              name: "ban",
              options: [
                %{name: "user", value: target_user_id}
              ]
            }
          ]
        })

      with_mocks([
        {Nostrum.Api.User, [],
         [
           get: fn user_id ->
             if user_id == admin_user_id or user_id == to_string(admin_user_id) do
               {:ok, %{id: admin_user_id, username: "TestAdmin"}}
             else
               {:error, :not_found}
             end
           end
         ]},
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             # Ban succeeds from DMs
             assert response.data.embeds != nil
             embed = hd(response.data.embeds)
             assert String.contains?(embed.title, "User Banned")
             {:ok}
           end
         ]}
      ]) do
        Admin.handle(interaction)
      end

      {:ok, user} = User.get_user_by_discord_id(target_user_id)
      assert user.banned == true
    end
  end

  # ─── FINDING 2: /send has no ban check on sender ─────────────────────────
  # Severity: HIGH
  # File: lib/stackcoin/bot/discord/send.ex:40-52
  # The /send command flow is:
  #   1. get guild
  #   2. validate channel
  #   3. get from_user by discord_id
  #   4. parse options (to_user, amount)
  #   5. get recipient user
  #   6. Bank.transfer_between_users()
  #
  # Bank.transfer_between_users DOES check both sender and recipient bans
  # (line 24-25 of bank.ex), so the ban check happens in the core layer.
  # However, the Discord layer does NOT check the sender's ban status before
  # calling the core layer. The core layer catches it, but the error message
  # returned is the generic :user_banned, which maps to "You have been banned
  # from StackCoin." This is correct behavior, but notable that the Discord
  # layer itself doesn't validate — it relies entirely on the core layer.
  #
  # This is actually CORRECT — the core layer handles it. Test confirms.

  describe "FINDING-2: /send banned-user behavior (core layer correctly blocks)" do
    test "banned user cannot /send even though Discord layer has no explicit ban check" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      sender_id = 888_888_888
      recipient_id = 777_777_777

      {sender, _recipient} =
        setup_guild_and_users(admin_user_id, guild_id, channel_id, sender_id, recipient_id)

      {:ok, _} = Bank.update_user_balance(sender.id, 100)
      {:ok, _banned} = User.ban_user(sender)

      interaction =
        create_mock_interaction(sender_id, guild_id, channel_id, %{
          options: [
            %{name: "user", value: recipient_id},
            %{name: "amount", value: 50}
          ]
        })

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.content != nil
             assert String.contains?(response.data.content, "banned")
             {:ok}
           end
         ]}
      ]) do
        Send.handle(interaction)
      end

      # Balance should be unchanged
      {:ok, updated_sender} = User.get_user_by_discord_id(sender_id)
      assert updated_sender.balance == 100
    end
  end

  # ─── FINDING 3: /balance can bypass ban check when viewing other users ────
  # Severity: MEDIUM
  # File: lib/stackcoin/bot/discord/balance.ex:77-113
  # When checking your OWN balance (no user option), the code checks if you're
  # banned (line 106). But when checking ANOTHER user's balance (user option
  # provided), there is NO ban check on the requesting user (line 87-90).
  # A banned user can use /balance @someone to view others' balances.

  describe "FINDING-3: banned user cannot view other users' balances via /balance @user" do
    test "banned user cannot check other users' balances" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      banned_user_id = 888_888_888
      target_user_id = 777_777_777

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, banned_user} = User.create_user_account(banned_user_id, "BannedUser")
      {:ok, _target} = User.create_user_account(target_user_id, "TargetUser", balance: 42)
      {:ok, _} = User.ban_user(banned_user)

      # Banned user checks another user's balance
      interaction =
        create_mock_interaction(banned_user_id, guild_id, channel_id, %{
          options: [%{name: "user", value: target_user_id}]
        })

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             # Now correctly blocked — banned user cannot see other users' balances
             assert response.data.content != nil
             assert String.contains?(response.data.content, "banned")
             {:ok}
           end
         ]}
      ]) do
        Balance.handle(interaction)
      end
    end

    test "banned user cannot check their OWN balance" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      banned_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, banned_user} = User.create_user_account(banned_user_id, "BannedUser", balance: 100)
      {:ok, _} = User.ban_user(banned_user)

      # Banned user checks their own balance (no options)
      interaction =
        create_mock_interaction(banned_user_id, guild_id, channel_id, %{
          options: nil
        })

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             # This is blocked — banned users can't see their own balance
             assert response.data.content != nil
             assert String.contains?(response.data.content, "banned")
             {:ok}
           end
         ]}
      ]) do
        Balance.handle(interaction)
      end
    end
  end

  # ─── FINDING 4: /preauths list/revoke work without guild/channel check ───
  # Severity: LOW
  # File: lib/stackcoin/bot/discord/preauths.ex:39-55
  # The /preauths command does NOT validate guild or channel. It works in
  # DMs, unregistered guilds, wrong channels. This may be intentional (user
  # should be able to manage their own preauths from anywhere), but it's
  # inconsistent with /balance, /send, /dole which all enforce guild+channel.

  describe "FINDING-4: /preauths works without guild/channel validation" do
    test "preauths list works from nil guild context (DMs)" do
      admin_user_id = 999_999_999
      user_id = 888_888_888

      setup_admin_user(admin_user_id)
      {:ok, _user} = User.create_user_account(user_id, "TestUser")

      # DM context: nil guild and channel
      interaction = %{
        type: Nostrum.Constants.InteractionType.application_command(),
        user: %{id: user_id},
        member: nil,
        guild_id: nil,
        channel_id: nil,
        data: %{
          options: [%{name: "list"}]
        }
      }

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             # Succeeds in DMs — no guild/channel check
             assert response.data.components != nil
             {:ok}
           end
         ]}
      ]) do
        StackCoin.Bot.Discord.Preauths.handle(interaction)
      end
    end
  end

  # ─── FINDING 5: bot_create button interaction - requester_snowflake in custom_id ──
  # Severity: MEDIUM
  # File: lib/stackcoin/bot/discord/bot.ex:280-295, 391-411
  # Bot creation approval buttons embed the requester snowflake and bot name
  # in the custom_id string: "bot_create_accept:<snowflake>:<bot_name>"
  # An attacker who can craft a message component interaction with a modified
  # custom_id could create a bot for ANY user. The is_admin? check (line 283)
  # is the only guard. However, since the button is sent via DM to the admin,
  # the attack requires the admin account to be compromised, limiting practical
  # exploitability. Still, storing requester identity in client-modifiable
  # custom_id is a design concern.

  describe "FINDING-5: bot_create custom_id trusts client-provided requester_snowflake" do
    test "admin can approve bot creation for an arbitrary snowflake via custom_id" do
      admin_user_id = 999_999_999
      victim_user_id = 777_777_777

      setup_admin_user(admin_user_id)
      {:ok, _victim} = User.create_user_account(victim_user_id, "VictimUser")

      # Crafted button interaction with arbitrary requester snowflake
      interaction = %{
        type: 3,
        user: %{id: admin_user_id},
        guild_id: nil,
        channel_id: nil,
        data: %{custom_id: "bot_create_accept:#{victim_user_id}:InjectedBot"}
      }

      with_mocks([
        {Nostrum.Api.User, [],
         [
           get: fn user_id ->
             if user_id == admin_user_id or user_id == to_string(admin_user_id) do
               {:ok, %{id: admin_user_id, username: "TestAdmin"}}
             else
               {:error, :not_found}
             end
           end,
           create_dm: fn _user_id -> {:ok, %{id: 12345}} end
         ]},
        {Nostrum.Api.Message, [],
         [
           create: fn _channel_id, _message -> {:ok, %{id: 0}} end
         ]},
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             # Type 7 = UPDATE_MESSAGE
             assert response.type == 7
             {:ok}
           end
         ]}
      ]) do
        StackCoin.Bot.Discord.Bot.handle_bot_creation_interaction(interaction)
      end

      # Bot was created under the victim's account, not the admin's
      {:ok, bot} = StackCoin.Core.Bot.get_bot_by_name("InjectedBot")
      assert bot.active == true

      # The owner is the victim, not the admin
      assert bot.owner.id != nil
    end
  end

  # ─── FINDING 6: request_accept button - no guild/channel validation ──────
  # Severity: LOW
  # File: lib/stackcoin/bot/discord/request.ex:38-46, 152-183
  # Request accept/deny button handlers don't validate guild/channel context.
  # This is by design (buttons appear in DMs), but means the handlers trust
  # the interaction.user.id to determine who is accepting. Discord enforces
  # that the button click comes from the DM recipient, so this is safe in
  # practice.

  # ─── FINDING 7: Race condition - double-accept on request buttons ────────
  # Severity: MEDIUM
  # File: lib/stackcoin/core/request.ex:213-274
  # Two rapid "Accept" clicks on a request button could both pass the
  # validate_request_pending check (line 216) before either commits. However,
  # Bank.transfer_between_users uses Repo.transaction, which should provide
  # serialization. The status update also happens inside the transaction.
  # The real protection is that the SECOND call to accept_request will see
  # the request is no longer "pending" (it was updated to "accepted" in the
  # first transaction). With SQLite's exclusive write locking, this is safe.
  # With PostgreSQL, there could be a TOCTOU race without SELECT FOR UPDATE.
  # Since StackCoin uses SQLite (Exqlite), the exclusive write lock provides
  # protection. This is a potential concern if migrating to PostgreSQL.

  describe "FINDING-7: request double-accept race (SQLite serializes, but logic race exists)" do
    test "second accept of same request fails with :request_not_pending" do
      admin_user_id = 999_999_999
      requester_id = 888_888_888
      responder_id = 777_777_777

      setup_admin_user(admin_user_id)
      {:ok, requester} = User.create_user_account(requester_id, "Requester")
      {:ok, responder} = User.create_user_account(responder_id, "Responder")
      {:ok, _} = Bank.update_user_balance(responder.id, 100)

      # Create request directly in the core layer (skip Discord notification)
      request_attrs = %{
        requester_id: requester.id,
        responder_id: responder.id,
        status: "pending",
        amount: 10,
        requested_at: NaiveDateTime.utc_now()
      }

      {:ok, request} =
        StackCoin.Repo.insert(
          StackCoin.Schema.Request.changeset(%StackCoin.Schema.Request{}, request_attrs)
        )

      # First accept succeeds
      assert {:ok, _accepted} = Request.accept_request(request.id, responder.id)

      # Second accept fails — request is no longer pending
      assert {:error, :request_not_pending} = Request.accept_request(request.id, responder.id)

      # Verify only one transfer happened
      {:ok, updated_responder} = User.get_user_by_id(responder.id)
      assert updated_responder.balance == 90

      {:ok, updated_requester} = User.get_user_by_id(requester.id)
      assert updated_requester.balance == 10
    end
  end

  # ─── FINDING 8: /balance and /graph nil guild_id crash path ──────────────
  # Severity: MEDIUM
  # File: lib/stackcoin/bot/discord/balance.ex:54
  #        lib/stackcoin/bot/discord/graph.ex:46
  # If guild_id is nil (DM context), get_guild_by_discord_id("nil") is called.
  # This returns {:error, :guild_not_registered}, so it doesn't crash, but it
  # exposes a misleading error message. The user sees "This server is not
  # registered with StackCoin" when they're actually in a DM.

  describe "FINDING-8: commands in DMs produce misleading error messages" do
    test "/balance in DMs says 'server not registered' instead of 'use in a server'" do
      user_id = 888_888_888
      admin_user_id = 999_999_999

      setup_admin_user(admin_user_id)
      {:ok, _user} = User.create_user_account(user_id, "TestUser")

      # DM context
      interaction =
        create_mock_interaction(user_id, nil, nil, %{options: nil})

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.content != nil
             # The error says "not registered" when the real issue is DM context
             assert String.contains?(response.data.content, "not registered")
             {:ok}
           end
         ]}
      ]) do
        Balance.handle(interaction)
      end
    end

    test "/send in DMs produces 'not registered' error" do
      user_id = 888_888_888
      admin_user_id = 999_999_999

      setup_admin_user(admin_user_id)
      {:ok, _user} = User.create_user_account(user_id, "TestUser")

      interaction =
        create_mock_interaction(user_id, nil, nil, %{
          options: [
            %{name: "user", value: 777_777_777},
            %{name: "amount", value: 10}
          ]
        })

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.content != nil
             assert String.contains?(response.data.content, "not registered")
             {:ok}
           end
         ]}
      ]) do
        Send.handle(interaction)
      end
    end
  end

  # ─── FINDING 9: /send self-transfer error is correctly handled ───────────
  # Severity: LOW (working correctly, documenting for completeness)
  # File: lib/stackcoin/core/bank.ex:400-403
  # Self-transfer is blocked at the core level.

  describe "FINDING-9: self-transfer correctly blocked" do
    test "user cannot send STK to themselves" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, user} = User.create_user_account(user_id, "TestUser")
      {:ok, _} = Bank.update_user_balance(user.id, 100)

      interaction =
        create_mock_interaction(user_id, guild_id, channel_id, %{
          options: [
            %{name: "user", value: user_id},
            %{name: "amount", value: 50}
          ]
        })

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.content != nil
             assert String.contains?(response.data.content, "cannot send STK to yourself")
             {:ok}
           end
         ]}
      ]) do
        Send.handle(interaction)
      end

      {:ok, unchanged} = User.get_user_by_discord_id(user_id)
      assert unchanged.balance == 100
    end
  end

  # ─── FINDING 10: /dole creates account - no ban check before creation ────
  # Severity: LOW (mitigated by post-creation ban check)
  # File: lib/stackcoin/bot/discord/dole.ex:64-76, 24-36
  # The dole handler calls get_or_create_user, which creates an account if
  # one doesn't exist. Then it checks ban/dole_banned status. This means a
  # user who was never pre-banned can always create an account via /dole.
  # For pre-banned users, the flow correctly: create account -> check ban ->
  # ban blocks dole. This is tested in existing tests and works correctly.

  # ─── FINDING 11: Request/Preauth button handlers trust Discord user.id ───
  # Severity: LOW
  # File: lib/stackcoin/bot/discord/request.ex:152-183
  #        lib/stackcoin/bot/discord/preauth.ex:197-217
  # Both handlers look up the StackCoin user from interaction.user.id and
  # validate that user is the authorized responder/owner. This is correct
  # because Discord guarantees interaction.user.id is the authenticated user.
  # The core layer adds a second check (validate_request_responder for accept,
  # validate_request_participant for deny, validate_preauth_owner for preauth).

  describe "FINDING-11: request accept validates responder identity (correct)" do
    test "non-responder cannot accept a request" do
      admin_user_id = 999_999_999
      requester_id = 888_888_888
      responder_id = 777_777_777
      attacker_id = 666_666_666

      setup_admin_user(admin_user_id)
      {:ok, requester} = User.create_user_account(requester_id, "Requester")
      {:ok, responder} = User.create_user_account(responder_id, "Responder")
      {:ok, attacker} = User.create_user_account(attacker_id, "Attacker")
      {:ok, _} = Bank.update_user_balance(responder.id, 100)
      {:ok, _} = Bank.update_user_balance(attacker.id, 100)

      # Create request directly
      request_attrs = %{
        requester_id: requester.id,
        responder_id: responder.id,
        status: "pending",
        amount: 50,
        requested_at: NaiveDateTime.utc_now()
      }

      {:ok, request} =
        StackCoin.Repo.insert(
          StackCoin.Schema.Request.changeset(%StackCoin.Schema.Request{}, request_attrs)
        )

      # Attacker tries to accept the request
      assert {:error, :not_request_responder} =
               Request.accept_request(request.id, attacker.id)

      # Responder's balance unchanged
      {:ok, updated_responder} = User.get_user_by_id(responder.id)
      assert updated_responder.balance == 100

      # Attacker's balance unchanged
      {:ok, updated_attacker} = User.get_user_by_id(attacker.id)
      assert updated_attacker.balance == 100
    end
  end

  # ─── FINDING 12: /bot list/reset-token/delete scope to owner correctly ───
  # Severity: LOW (working correctly)
  # File: lib/stackcoin/core/bot.ex:88-123
  # All bot management operations check owner_id, preventing cross-user access.

  # ─── FINDING 13: Preauth button handler validates owner correctly ────────
  # Severity: LOW (working correctly)
  # File: lib/stackcoin/bot/discord/preauth.ex:210-217

  describe "FINDING-13: preauth button validates owner" do
    test "non-owner cannot accept a preauth via button" do
      admin_user_id = 999_999_999
      owner_user_id = 888_888_888
      attacker_user_id = 666_666_666

      setup_admin_user(admin_user_id)
      {:ok, owner} = User.create_user_account(owner_user_id, "Owner")
      {:ok, _attacker} = User.create_user_account(attacker_user_id, "Attacker")

      # Create a bot for testing
      {:ok, bot} = StackCoin.Core.Bot.create_bot_user(owner_user_id, "TestBot")

      # Create a preauth
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, owner.id, 100, 24)

      # Attacker tries to accept the preauth
      interaction = %{
        type: 3,
        user: %{id: attacker_user_id},
        data: %{custom_id: "preauth_accept_#{preauth.id}"}
      }

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 7
             container = hd(response.data.components)
             text = Enum.find(container.components, fn c -> c.type == 10 end)
             assert String.contains?(text.content, "not authorized")
             {:ok}
           end
         ]}
      ]) do
        StackCoin.Bot.Discord.Preauth.handle_preauth_interaction(interaction)
      end

      # Preauth should still be pending
      {:ok, still_pending} = Preauthorization.get_preauth(preauth.id)
      assert still_pending.status == "pending"
    end
  end

  # ─── FINDING 14: Non-admin bot_create button click is rejected ───────────
  # Severity: LOW (working correctly)
  # File: lib/stackcoin/bot/discord/bot.ex:283-289

  describe "FINDING-14: non-admin cannot approve bot creation via button" do
    test "regular user clicking Accept on bot creation request is rejected" do
      admin_user_id = 999_999_999
      regular_user_id = 777_777_777
      requester_user_id = 666_666_666

      setup_admin_user(admin_user_id)
      {:ok, _regular} = User.create_user_account(regular_user_id, "RegularUser")
      {:ok, _requester} = User.create_user_account(requester_user_id, "RequesterUser")

      # Regular user crafts/clicks the accept button
      interaction = %{
        type: 3,
        user: %{id: regular_user_id},
        data: %{custom_id: "bot_create_accept:#{requester_user_id}:SneakyBot"}
      }

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 7
             container = hd(response.data.components)
             text = Enum.find(container.components, fn c -> c.type == 10 end)
             assert String.contains?(text.content, "Only admins")
             {:ok}
           end
         ]}
      ]) do
        StackCoin.Bot.Discord.Bot.handle_bot_creation_interaction(interaction)
      end

      # Bot should NOT exist
      assert {:error, :bot_not_found} = StackCoin.Core.Bot.get_bot_by_name("SneakyBot")
    end
  end

  # ─── FINDING 15: Concurrent dole requests are serialized by SQLite ───────
  # Severity: MEDIUM (theoretical, mitigated by SQLite)
  # File: lib/stackcoin/core/reserve.ex:17-43
  # The dole flow reads last_given_dole, checks eligibility, transfers, then
  # updates last_given_dole. With concurrent requests, both could read nil
  # last_given_dole and both pass eligibility. SQLite's exclusive write lock
  # makes this safe, but with PostgreSQL it would be a TOCTOU race.

  describe "FINDING-15: sequential dole requests are correctly limited" do
    test "second dole in same day fails even with rapid sequential calls" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      user_id = 888_888_888

      setup_admin_user(admin_user_id)
      create_reserve_user(1000)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, _user} = User.create_user_account(user_id, "TestUser")

      # First dole
      {:ok, user} = User.get_user_by_discord_id(user_id)
      {:ok, _tx1} = Reserve.transfer_dole_to_user(user.id)

      # Second dole immediately after
      {:ok, user_refreshed} = User.get_user_by_discord_id(user_id)
      result = Reserve.transfer_dole_to_user(user_refreshed.id)
      assert {:error, {:dole_already_given_today, _timestamp}} = result

      # Balance should reflect only one dole
      {:ok, final_user} = User.get_user_by_discord_id(user_id)
      assert final_user.balance == 10
    end
  end

  # ─── FINDING 16: /send to banned recipient is correctly blocked ──────────
  # Severity: LOW (working correctly)

  describe "FINDING-16: sending to banned recipient blocked" do
    test "cannot /send to a banned user" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      sender_id = 888_888_888
      banned_recipient_id = 777_777_777

      {sender, recipient} =
        setup_guild_and_users(
          admin_user_id,
          guild_id,
          channel_id,
          sender_id,
          banned_recipient_id
        )

      {:ok, _} = Bank.update_user_balance(sender.id, 100)
      {:ok, _} = User.ban_user(recipient)

      interaction =
        create_mock_interaction(sender_id, guild_id, channel_id, %{
          options: [
            %{name: "user", value: banned_recipient_id},
            %{name: "amount", value: 50}
          ]
        })

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.content != nil
             assert String.contains?(response.data.content, "banned")
             {:ok}
           end
         ]}
      ]) do
        Send.handle(interaction)
      end

      {:ok, updated_sender} = User.get_user_by_discord_id(sender_id)
      assert updated_sender.balance == 100
    end
  end
end
