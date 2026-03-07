# Bot Creation Approval Flow Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow non-admin users to request bot creation, with admin approval via Discord DM buttons.

**Architecture:** When a non-admin runs `/bot create`, instead of rejecting with "no permission", the handler sends a pending-approval reply to the user and DMs the admin with Accept/Reject buttons. The requester's snowflake and bot name are encoded in the button `custom_id` (no new DB table). On approval, `Bot.create_bot_user/2` is called with the requester as owner and the token is DM'd to them. Admins still create bots instantly.

**Tech Stack:** Elixir, Nostrum (Discord API), Ecto, ExUnit + Mock

---

### Task 1: Write failing tests for the approval request flow

**Files:**
- Modify: `test/stackcoin/bot/discord/bot_test.exs`

**Step 1: Add test "non-admin bot create sends approval request to admin"**

Add a new `describe "bot creation approval flow"` block. The test should:
- Set up a non-admin user with a StackCoin account
- Run `/bot create name:MyBot` as that user
- Assert the channel response contains "pending approval" or "request has been sent"
- Assert `Api.User.create_dm` was called (to DM the admin)
- Assert the DM message contains the bot name, requester info, and has components (buttons)
- Assert the bot does NOT exist in DB yet

```elixir
describe "bot creation approval flow" do
  test "non-admin bot create sends approval request to admin" do
    guild_id = 123_456_789
    channel_id = 987_654_321
    admin_user_id = 999_999_999
    regular_user_id = 777_777_777

    setup_admin_user(admin_user_id)
    setup_guild_with_admin(admin_user_id, guild_id, channel_id)
    {:ok, _regular} = User.create_user_account(regular_user_id, "RegularUser")

    interaction =
      create_bot_interaction(regular_user_id, guild_id, channel_id, "create", [
        {"name", "RequestedBot"}
      ])

    dm_message_sent = :ets.new(:dm_message_sent, [:set, :public])
    :ets.insert(dm_message_sent, {:sent, false})

    with_mocks([
      {Nostrum.Api.User, [],
       [
         create_dm: fn _user_id -> {:ok, %{id: 12345}} end
       ]},
      {Nostrum.Api.Message, [],
       [
         create: fn _channel_id, message ->
           # Verify the DM to admin has the bot name, requester, and buttons
           assert message.components != nil
           container = hd(message.components)
           text = hd(container.components)
           assert String.contains?(text.content, "RequestedBot")
           assert String.contains?(text.content, "RegularUser")
           :ets.insert(dm_message_sent, {:sent, true})
           {:ok, %{id: 0}}
         end
       ]},
      {Nostrum.Api, [],
       [
         create_interaction_response: fn _interaction, response ->
           assert response.type == 4
           assert response.data.embeds != nil
           embed = hd(response.data.embeds)
           assert String.contains?(embed.description, "RequestedBot")
           assert String.contains?(embed.description, "approval") or
                    String.contains?(embed.description, "sent")
           {:ok}
         end
       ]}
    ]) do
      BotCommand.handle(interaction)
    end

    [{:sent, was_sent}] = :ets.lookup(dm_message_sent, :sent)
    assert was_sent, "Approval request DM should have been sent to admin"
    :ets.delete(dm_message_sent)

    # Bot should NOT exist yet
    assert {:error, :bot_not_found} = Bot.get_bot_by_name("RequestedBot")
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/stackcoin/bot/discord/bot_test.exs --only describe:"bot creation approval flow" -v`

Expected: FAIL — current code returns "don't have permission" error instead of sending approval request.

---

### Task 2: Write failing test for admin approving a bot creation request

**Files:**
- Modify: `test/stackcoin/bot/discord/bot_test.exs`

**Step 1: Add test "admin approves bot creation request"**

Inside the same `describe "bot creation approval flow"` block. This test simulates the admin clicking the Accept button by constructing an interaction with `type: 3` (message component) and a `custom_id` of `bot_create_accept:{snowflake}:{name}`.

```elixir
test "admin approves bot creation request via button" do
  guild_id = 123_456_789
  channel_id = 987_654_321
  admin_user_id = 999_999_999
  requester_user_id = 777_777_777

  setup_admin_user(admin_user_id)
  setup_guild_with_admin(admin_user_id, guild_id, channel_id)
  {:ok, _requester} = User.create_user_account(requester_user_id, "RequesterUser")

  # Simulate admin clicking Accept button
  interaction = %{
    type: 3,
    user: %{id: admin_user_id},
    guild_id: guild_id,
    channel_id: channel_id,
    data: %{custom_id: "bot_create_accept:#{requester_user_id}:ApprovedBot"}
  }

  token_dm_sent = :ets.new(:token_dm_sent, [:set, :public])
  :ets.insert(token_dm_sent, {:sent, false})

  with_mocks([
    {Nostrum.Api.User, [],
     [
       create_dm: fn _user_id -> {:ok, %{id: 12345}} end
     ]},
    {Nostrum.Api.Message, [],
     [
       create: fn _channel_id, message ->
         # This should be the token DM to the requester
         embed = hd(message.embeds)
         assert String.contains?(embed.description, "ApprovedBot")
         assert String.contains?(embed.description, "||")
         :ets.insert(token_dm_sent, {:sent, true})
         {:ok, %{id: 0}}
       end
     ]},
    {Nostrum.Api, [],
     [
       create_interaction_response: fn _interaction, response ->
         # Should update the admin's message to show approval
         assert response.type == 7
         {:ok}
       end
     ]}
  ]) do
    BotCommand.handle_bot_creation_interaction(interaction)
  end

  [{:sent, was_sent}] = :ets.lookup(token_dm_sent, :sent)
  assert was_sent, "Token DM should have been sent to requester"
  :ets.delete(token_dm_sent)

  # Bot should now exist
  {:ok, bot} = Bot.get_bot_by_name("ApprovedBot")
  assert bot.active == true
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/stackcoin/bot/discord/bot_test.exs --only describe:"bot creation approval flow" -v`

Expected: FAIL — `handle_bot_creation_interaction/1` does not exist yet.

---

### Task 3: Write failing tests for reject and duplicate approval

**Files:**
- Modify: `test/stackcoin/bot/discord/bot_test.exs`

**Step 1: Add test "admin rejects bot creation request"**

```elixir
test "admin rejects bot creation request via button" do
  guild_id = 123_456_789
  channel_id = 987_654_321
  admin_user_id = 999_999_999
  requester_user_id = 777_777_777

  setup_admin_user(admin_user_id)
  setup_guild_with_admin(admin_user_id, guild_id, channel_id)
  {:ok, _requester} = User.create_user_account(requester_user_id, "RequesterUser")

  interaction = %{
    type: 3,
    user: %{id: admin_user_id},
    guild_id: guild_id,
    channel_id: channel_id,
    data: %{custom_id: "bot_create_reject:#{requester_user_id}:RejectedBot"}
  }

  rejection_dm_sent = :ets.new(:rejection_dm_sent, [:set, :public])
  :ets.insert(rejection_dm_sent, {:sent, false})

  with_mocks([
    {Nostrum.Api.User, [],
     [
       create_dm: fn _user_id -> {:ok, %{id: 12345}} end
     ]},
    {Nostrum.Api.Message, [],
     [
       create: fn _channel_id, message ->
         embed = hd(message.embeds)
         assert String.contains?(embed.description, "RejectedBot")
         assert String.contains?(embed.description, "denied") or
                  String.contains?(embed.description, "rejected")
         :ets.insert(rejection_dm_sent, {:sent, true})
         {:ok, %{id: 0}}
       end
     ]},
    {Nostrum.Api, [],
     [
       create_interaction_response: fn _interaction, response ->
         # Should update the admin's message to show rejection
         assert response.type == 7
         {:ok}
       end
     ]}
  ]) do
    BotCommand.handle_bot_creation_interaction(interaction)
  end

  [{:sent, was_sent}] = :ets.lookup(rejection_dm_sent, :sent)
  assert was_sent, "Rejection DM should have been sent to requester"
  :ets.delete(rejection_dm_sent)

  # Bot should NOT exist
  assert {:error, :bot_not_found} = Bot.get_bot_by_name("RejectedBot")
end
```

**Step 2: Add test "duplicate approval handled gracefully"**

```elixir
test "duplicate approval is handled gracefully" do
  guild_id = 123_456_789
  channel_id = 987_654_321
  admin_user_id = 999_999_999
  requester_user_id = 777_777_777

  setup_admin_user(admin_user_id)
  setup_guild_with_admin(admin_user_id, guild_id, channel_id)
  {:ok, _requester} = User.create_user_account(requester_user_id, "RequesterUser")

  # First approval — create the bot directly to simulate already-approved
  {:ok, _bot} = Bot.create_bot_user(requester_user_id, "AlreadyApproved")

  # Second approval attempt via button
  interaction = %{
    type: 3,
    user: %{id: admin_user_id},
    guild_id: guild_id,
    channel_id: channel_id,
    data: %{custom_id: "bot_create_accept:#{requester_user_id}:AlreadyApproved"}
  }

  with_mocks([
    {Nostrum.Api.User, [],
     [
       create_dm: fn _user_id -> {:ok, %{id: 12345}} end
     ]},
    {Nostrum.Api.Message, [],
     [
       create: fn _channel_id, _message -> {:ok, %{id: 0}} end
     ]},
    {Nostrum.Api, [],
     [
       create_interaction_response: fn _interaction, response ->
         # Should update message with an error, not crash
         assert response.type == 7
         {:ok}
       end
     ]}
  ]) do
    # Should not raise
    BotCommand.handle_bot_creation_interaction(interaction)
  end
end
```

**Step 3: Run tests to verify they fail**

Run: `mix test test/stackcoin/bot/discord/bot_test.exs --only describe:"bot creation approval flow" -v`

Expected: FAIL — functions don't exist yet.

---

### Task 4: Implement the approval request flow in bot.ex

**Files:**
- Modify: `lib/stackcoin/bot/discord/bot.ex:149-160`

**Step 1: Change `create_bot/2` to handle the non-admin case**

Replace the `:not_admin` error branch with a call to `send_bot_creation_request/2`:

```elixir
defp create_bot(bot_name, interaction) do
  case Bot.admin_create_bot_user(interaction.user.id, bot_name) do
    {:ok, bot} ->
      send_bot_created_response(interaction, bot)

    {:error, :not_admin} ->
      send_bot_creation_request(bot_name, interaction)

    {:error, changeset} ->
      Commands.send_error_response(interaction, changeset)
  end
end
```

**Step 2: Add `send_bot_creation_request/2`**

Add this new private function. It should:
1. Look up the requester's username for display
2. Send a channel reply telling the user their request is pending
3. DM the admin with Accept/Reject buttons

Use the Components v2 constants from the Request module (or define them locally). The button custom_ids use the format `bot_create_accept:{requester_snowflake}:{bot_name}` and `bot_create_reject:{requester_snowflake}:{bot_name}`.

```elixir
# Discord Message Components v2 constants
@is_components_v2_flag 32768
@container_component 17
@text_display_component 10
@action_row_component 1
@button_component 2
@button_style_success 3
@button_style_danger 4

defp send_bot_creation_request(bot_name, interaction) do
  requester_id = interaction.user.id
  admin_user_id = Application.get_env(:stackcoin, :admin_user_id)

  # Send channel reply to requester
  Api.create_interaction_response(interaction, %{
    type: InteractionCallbackType.channel_message_with_source(),
    data: %{
      embeds: [
        %{
          title: "#{Commands.stackcoin_emoji()} Bot Creation Request Sent",
          description:
            "Your request to create bot **#{bot_name}** has been sent to an admin for approval.\n\nYou will receive a DM when your request is approved or denied.",
          color: Commands.stackcoin_color()
        }
      ]
    }
  })

  # DM the admin with accept/reject buttons
  if admin_user_id do
    admin_snowflake = String.to_integer(admin_user_id)

    case Api.User.create_dm(admin_snowflake) do
      {:ok, dm_channel} ->
        {:ok, requester} = StackCoin.Core.User.get_user_by_discord_id(requester_id)

        components = [
          %{
            type: @container_component,
            accent_color: Commands.stackcoin_color(),
            components: [
              %{
                type: @text_display_component,
                content:
                  "#{Commands.stackcoin_emoji()} Bot Creation Request\n\n**#{requester.username}** (<@#{requester_id}>) is requesting to create a bot named **#{bot_name}**."
              },
              %{
                type: @action_row_component,
                components: [
                  %{
                    type: @button_component,
                    style: @button_style_success,
                    label: "Approve",
                    custom_id: "bot_create_accept:#{requester_id}:#{bot_name}"
                  },
                  %{
                    type: @button_component,
                    style: @button_style_danger,
                    label: "Reject",
                    custom_id: "bot_create_reject:#{requester_id}:#{bot_name}"
                  }
                ]
              }
            ]
          }
        ]

        Api.Message.create(dm_channel.id, %{
          flags: @is_components_v2_flag,
          components: components
        })

      {:error, _reason} ->
        :error
    end
  end
end
```

**Step 3: Run the first test to verify it passes**

Run: `mix test test/stackcoin/bot/discord/bot_test.exs --only test:"non-admin bot create sends approval request to admin" -v`

Expected: PASS

---

### Task 5: Implement the button interaction handler

**Files:**
- Modify: `lib/stackcoin/bot/discord/bot.ex`
- Modify: `lib/stackcoin/bot/discord.ex:78-91`

**Step 1: Add `handle_bot_creation_interaction/1` and helpers to bot.ex**

```elixir
@doc """
Handles button interactions for bot creation accept/reject actions.
"""
def handle_bot_creation_interaction(interaction) do
  case parse_bot_creation_custom_id(interaction.data.custom_id) do
    {:ok, {:accept, requester_snowflake, bot_name}} ->
      handle_bot_creation_accept(requester_snowflake, bot_name, interaction)

    {:ok, {:reject, requester_snowflake, bot_name}} ->
      handle_bot_creation_reject(requester_snowflake, bot_name, interaction)

    {:error, :invalid_custom_id} ->
      Api.create_interaction_response(interaction, %{
        type: InteractionCallbackType.update_message(),
        data: %{
          flags: @is_components_v2_flag,
          components: [
            %{
              type: @container_component,
              accent_color: 0xFF6B6B,
              components: [
                %{type: @text_display_component, content: "❌ Invalid bot creation action."}
              ]
            }
          ]
        }
      })
  end
end

defp parse_bot_creation_custom_id("bot_create_accept:" <> rest) do
  case String.split(rest, ":", parts: 2) do
    [snowflake_str, bot_name] ->
      case Integer.parse(snowflake_str) do
        {snowflake, ""} -> {:ok, {:accept, snowflake, bot_name}}
        _ -> {:error, :invalid_custom_id}
      end

    _ ->
      {:error, :invalid_custom_id}
  end
end

defp parse_bot_creation_custom_id("bot_create_reject:" <> rest) do
  case String.split(rest, ":", parts: 2) do
    [snowflake_str, bot_name] ->
      case Integer.parse(snowflake_str) do
        {snowflake, ""} -> {:ok, {:reject, snowflake, bot_name}}
        _ -> {:error, :invalid_custom_id}
      end

    _ ->
      {:error, :invalid_custom_id}
  end
end

defp parse_bot_creation_custom_id(_), do: {:error, :invalid_custom_id}

defp handle_bot_creation_accept(requester_snowflake, bot_name, interaction) do
  case Bot.create_bot_user(requester_snowflake, bot_name) do
    {:ok, bot} ->
      # Update admin's message to show approved
      Api.create_interaction_response(interaction, %{
        type: InteractionCallbackType.update_message(),
        data: %{
          flags: @is_components_v2_flag,
          components: [
            %{
              type: @container_component,
              accent_color: 0x00FF00,
              components: [
                %{
                  type: @text_display_component,
                  content:
                    "#{Commands.stackcoin_emoji()} Bot Creation Approved\n\nBot **#{bot_name}** has been created for <@#{requester_snowflake}>.\n\nBot ID: #{bot.id}"
                }
              ]
            }
          ]
        }
      })

      # DM the requester with their bot token
      send_bot_token_dm(requester_snowflake, bot)

    {:error, reason} ->
      error_msg =
        case reason do
          %Ecto.Changeset{} -> "Bot creation failed (name may already be taken)."
          _ -> "Bot creation failed: #{inspect(reason)}"
        end

      Api.create_interaction_response(interaction, %{
        type: InteractionCallbackType.update_message(),
        data: %{
          flags: @is_components_v2_flag,
          components: [
            %{
              type: @container_component,
              accent_color: 0xFF6B6B,
              components: [
                %{type: @text_display_component, content: "❌ #{error_msg}"}
              ]
            }
          ]
        }
      })
  end
end

defp handle_bot_creation_reject(requester_snowflake, bot_name, interaction) do
  # Update admin's message to show rejected
  Api.create_interaction_response(interaction, %{
    type: InteractionCallbackType.update_message(),
    data: %{
      flags: @is_components_v2_flag,
      components: [
        %{
          type: @container_component,
          accent_color: 0xFF0000,
          components: [
            %{
              type: @text_display_component,
              content:
                "#{Commands.stackcoin_emoji()} Bot Creation Rejected\n\nBot creation request for **#{bot_name}** from <@#{requester_snowflake}> has been rejected."
            }
          ]
        }
      ]
    }
  })

  # DM the requester about the rejection
  case Api.User.create_dm(requester_snowflake) do
    {:ok, dm_channel} ->
      Api.Message.create(dm_channel.id, %{
        embeds: [
          %{
            title: "#{Commands.stackcoin_emoji()} Bot Creation Request Denied",
            description:
              "Your request to create bot **#{bot_name}** has been denied by an admin.",
            color: 0xFF0000
          }
        ]
      })

    {:error, _reason} ->
      :error
  end
end
```

**Step 2: Route button interactions in discord.ex**

Add a new `handle_message_component` clause before the catch-all:

```elixir
defp handle_message_component("bot_create_" <> _rest, interaction) do
  Bot.handle_bot_creation_interaction(interaction)
end
```

**Step 3: Run all approval flow tests**

Run: `mix test test/stackcoin/bot/discord/bot_test.exs -v`

Expected: All tests PASS (both existing and new).

---

### Task 6: Run full test suite and verify coverage

**Step 1: Run full suite**

Run: `mix test`

Expected: All tests pass, no regressions.

**Step 2: Check coverage**

Run: `just cover`

Verify `bot/discord/bot.ex` coverage increased.

**Step 3: Commit**

```bash
git add -A
git commit -m "feat: add bot creation approval flow for non-admin users"
```
