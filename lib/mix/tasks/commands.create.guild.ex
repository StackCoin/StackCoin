defmodule Mix.Tasks.Commands.Create.Guild do
  use Mix.Task

  @shortdoc "Create guild application commands"
  @moduledoc """
  Creates application commands for a specific guild.

  Usage:
      mix commands.create.guild [guild_id]

  If no guild_id is provided, uses STACKCOIN_TEST_GUILD_ID from config.

  Examples:
      mix commands.create.guild 123456789012345678
      mix commands.create.guild
  """

  @impl Mix.Task
  @requirements ["app.start"]
  def run([guild_id]) when is_binary(guild_id) do
    guild_id = String.to_integer(guild_id)
    create_commands(guild_id)
  end

  def run([]) do
    case Application.get_env(:stackcoin, :test_guild_id) do
      nil ->
        Mix.shell().error("No guild_id provided and STACKCOIN_TEST_GUILD_ID not configured.")
        Mix.shell().error("Usage: mix commands.create.guild [guild_id]")
        System.halt(1)

      guild_id ->
        create_commands(guild_id)
    end
  end

  def run(_) do
    Mix.shell().error("Usage: mix commands.create.guild [guild_id]")
    System.halt(1)
  end

  defp create_commands(guild_id) do
    Mix.shell().info("Creating commands for guild #{guild_id}...")

    case StackCoin.Bot.Discord.Commands.create_guild_commands(guild_id) do
      %{successes: successes, errors: errors} ->
        Enum.each(successes, fn command ->
          Mix.shell().info("✓ Created command: #{command.name}")
        end)

        Enum.each(errors, fn {name, error} ->
          Mix.shell().error("✗ Failed to create command #{name}: #{inspect(error)}")
        end)

        if Enum.empty?(errors) do
          Mix.shell().info("All commands created successfully!")
        else
          Mix.shell().info("Command creation completed with #{length(errors)} error(s).")
        end
    end
  end
end
