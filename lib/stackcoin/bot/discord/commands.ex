defmodule StackCoin.Bot.Discord.Commands do
  @moduledoc """
  Defines Discord application commands and provides functions to create them.
  """

  alias Nostrum.Api.ApplicationCommand
  alias Nostrum.Api
  alias Nostrum.Constants.InteractionCallbackType
  alias StackCoin.Bot.Discord.{Balance, Admin, Dole}

  @stackcoin_emoji "🪙"
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
      Dole.definition()
    ]
  end

  @doc """
  Creates all commands for a specific guild.
  """
  def create_guild_commands(guild_id) do
    ensure_ready()
    commands = command_definitions()

    results =
      Enum.map(commands, fn command ->
        case ApplicationCommand.create_guild_command(guild_id, command) do
          {:ok, created_command} ->
            {:ok, created_command}

          {:error, error} ->
            {:error, {command.name, error}}
        end
      end)

    {successes, errors} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        {:error, _} -> false
      end)

    %{
      successes: Enum.map(successes, fn {:ok, cmd} -> cmd end),
      errors: Enum.map(errors, fn {:error, {name, error}} -> {name, error} end)
    }
  end

  @doc """
  Creates all commands globally.
  """
  def create_global_commands do
    ensure_ready()
    commands = command_definitions()

    results =
      Enum.map(commands, fn command ->
        case ApplicationCommand.create_global_command(command) do
          {:ok, created_command} ->
            {:ok, created_command}

          {:error, error} ->
            {:error, {command.name, error}}
        end
      end)

    {successes, errors} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        {:error, _} -> false
      end)

    %{
      successes: Enum.map(successes, fn {:ok, cmd} -> cmd end),
      errors: Enum.map(errors, fn {:error, {name, error}} -> {name, error} end)
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
          "❌ This command can only be used in the designated StackCoin channel: <##{guild.designated_channel_snowflake}>"

        :user_not_found ->
          "❌ You don't have a StackCoin account yet. Use `/dole` to get started."

        :insufficient_reserve_balance ->
          "❌ The reserve system doesn't have enough StackCoins to give you dole!"

        {:dole_already_given_today, next_timestamp} ->
          "❌ You have already received your daily dole today, next dole available: <t:#{next_timestamp}:R>"

        :not_admin ->
          "❌ You don't have permission to use admin commands."

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
