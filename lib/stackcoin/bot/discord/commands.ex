defmodule StackCoin.Bot.Discord.Commands do
  @moduledoc """
  Defines Discord application commands and provides functions to create them.
  """

  alias Nostrum.Api.ApplicationCommand
  alias Nostrum.Cache.Me

  @doc """
  Ensures Nostrum is connected and ready before proceeding.
  """
  def ensure_ready do
    case Me.get() do
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
      %{
        name: "hello",
        description: "Say hello to the bot"
      },
      %{
        name: "ping",
        description: "Check if the bot is responsive"
      }
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
end
