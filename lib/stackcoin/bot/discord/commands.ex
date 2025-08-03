defmodule StackCoin.Bot.Discord.Commands do
  @moduledoc """
  Defines Discord application commands and provides functions to create them.
  """

  alias Nostrum.Api.ApplicationCommand
  alias Nostrum.Api
  alias Nostrum.Constants.InteractionCallbackType
  alias StackCoin.Bot.Discord.{Balance, Admin, Dole, Send, Leaderboard, Transactions, Graph, Bot}

  @stackcoin_emoji "<:stackcoin:1401621482026827908>"
  @stackcoin_color 0xFFFD5D

  def stackcoin_emoji, do: @stackcoin_emoji
  def stackcoin_color, do: @stackcoin_color

  @doc """
  Ensures Nostrum is connected and ready before proceeding.
  """
  def ensure_ready do
    case Nostrum.Cache.Me.get() do
      nil ->
        Mix.shell().info("Waiting for Nostrum to connect...")
        :timer.sleep(1000)
        ensure_ready()

      _user ->
        :ok
    end
  end

  @doc """
  Returns the list of application command definitions.
  """
  def command_definitions do
    [
      Balance.definition(),
      Admin.definition(),
      Dole.definition(),
      Send.definition(),
      Leaderboard.definition(),
      Transactions.definition(),
      Graph.definition(),
      Bot.definition()
    ]
  end

  @doc """
  Creates all commands for a specific guild and deletes any commands that are no longer defined.
  """
  def create_guild_commands(guild_id) do
    ensure_ready()
    commands = command_definitions()
    current_command_names = MapSet.new(commands, & &1.name)

    existing_commands =
      case ApplicationCommand.guild_commands(guild_id) do
        {:ok, commands} -> commands
        {:error, _} -> []
      end

    deletion_results =
      existing_commands
      |> Enum.reject(fn cmd -> MapSet.member?(current_command_names, cmd.name) end)
      |> Enum.map(fn cmd ->
        case ApplicationCommand.delete_guild_command(guild_id, cmd.id) do
          {:ok} -> {:deleted, cmd.name}
          {:error, error} -> {:delete_error, {cmd.name, error}}
        end
      end)

    creation_results =
      Enum.map(commands, fn command ->
        case ApplicationCommand.create_guild_command(guild_id, command) do
          {:ok, created_command} ->
            {:ok, created_command}

          {:error, error} ->
            {:error, {command.name, error}}
        end
      end)

    {successes, errors} =
      Enum.split_with(creation_results, fn
        {:ok, _} -> true
        {:error, _} -> false
      end)

    {deletions, delete_errors} =
      Enum.split_with(deletion_results, fn
        {:deleted, _} -> true
        {:delete_error, _} -> false
      end)

    %{
      successes: Enum.map(successes, fn {:ok, cmd} -> cmd end),
      errors: Enum.map(errors, fn {:error, {name, error}} -> {name, error} end),
      deletions: Enum.map(deletions, fn {:deleted, name} -> name end),
      delete_errors:
        Enum.map(delete_errors, fn {:delete_error, {name, error}} -> {name, error} end)
    }
  end

  @doc """
  Creates all commands globally and deletes any commands that are no longer defined.
  """
  def create_global_commands do
    ensure_ready()
    commands = command_definitions()
    current_command_names = MapSet.new(commands, & &1.name)

    existing_commands =
      case ApplicationCommand.global_commands() do
        {:ok, commands} -> commands
        {:error, _} -> []
      end

    deletion_results =
      existing_commands
      |> Enum.reject(fn cmd -> MapSet.member?(current_command_names, cmd.name) end)
      |> Enum.map(fn cmd ->
        case ApplicationCommand.delete_global_command(cmd.id) do
          {:ok} -> {:deleted, cmd.name}
          {:error, error} -> {:delete_error, {cmd.name, error}}
        end
      end)

    creation_results =
      Enum.map(commands, fn command ->
        case ApplicationCommand.create_global_command(command) do
          {:ok, created_command} ->
            {:ok, created_command}

          {:error, error} ->
            {:error, {command.name, error}}
        end
      end)

    {successes, errors} =
      Enum.split_with(creation_results, fn
        {:ok, _} -> true
        {:error, _} -> false
      end)

    {deletions, delete_errors} =
      Enum.split_with(deletion_results, fn
        {:deleted, _} -> true
        {:delete_error, _} -> false
      end)

    %{
      successes: Enum.map(successes, fn {:ok, cmd} -> cmd end),
      errors: Enum.map(errors, fn {:error, {name, error}} -> {name, error} end),
      deletions: Enum.map(deletions, fn {:deleted, name} -> name end),
      delete_errors:
        Enum.map(delete_errors, fn {:delete_error, {name, error}} -> {name, error} end)
    }
  end

  @doc """
  Sends an ephemeral error response for common error cases.
  """
  def send_error_response(interaction, error_type) do
    content =
      case error_type do
        :guild_not_registered ->
          "❌ This server is not registered with StackCoin."

        {:wrong_channel, guild} ->
          if is_nil(guild.designated_channel_snowflake) do
            "❌ There is no designated StackCoin channel set for this server."
          else
            "❌ This command can only be used in the designated StackCoin channel: <##{guild.designated_channel_snowflake}>"
          end

        :user_not_found ->
          "❌ You don't have a StackCoin account yet. Use `/dole` to get started."

        :other_user_not_found ->
          "❌ That user doesn't have a StackCoin account yet."

        :insufficient_reserve_balance ->
          "❌ The reserve doesn't have enough STK to give you dole!"

        {:dole_already_given_today, next_timestamp} ->
          "❌ You have already received your daily dole today, next dole available: <t:#{next_timestamp}:R>"

        :not_admin ->
          "❌ You don't have permission to use admin commands."

        :insufficient_balance ->
          "❌ You don't have enough STK to complete this transfer."

        :invalid_amount ->
          "❌ Transfer amount must be greater than 0."

        :self_transfer ->
          "❌ You cannot send STK to yourself."

        :recipient_not_found ->
          "❌ The recipient doesn't have a StackCoin account yet. They need to use `/dole` first to create an account."

        :user_banned ->
          "❌ You have been banned from StackCoin."

        :recipient_banned ->
          "❌ You cannot send STK to a banned user."

        :conflicting_transaction_filters ->
          "❌ You cannot use 'includes' with 'from' or 'to' filters. Use either 'includes' alone, or 'from'/'to' together."

        reason ->
          "❌ An error occurred: #{inspect(reason)}"
      end

    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        content: content
      }
    })
  end
end
