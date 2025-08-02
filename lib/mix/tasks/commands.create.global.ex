defmodule Mix.Tasks.Commands.Create.Global do
  use Mix.Task

  @shortdoc "Create global application commands"
  @moduledoc """
  Creates global application commands.

  Usage:
      mix commands.create.global

  Note: Global commands can take up to 1 hour to propagate across all guilds.

  Example:
      mix commands.create.global
  """

  @impl Mix.Task
  @requirements ["app.start"]
  def run([]) do
    create_global_commands()
  end

  def run(_) do
    Mix.shell().error("Usage: mix commands.create.global")
    System.halt(1)
  end

  defp create_global_commands do
    Mix.shell().info("Creating global commands...")
    Mix.shell().info("Note: Global commands can take up to 1 hour to propagate!")

    case StackCoin.Bot.Discord.Commands.create_global_commands() do
      %{successes: successes, errors: errors} ->
        Enum.each(successes, fn command ->
          Mix.shell().info("✓ Created global command: #{command.name}")
        end)

        Enum.each(errors, fn {name, error} ->
          Mix.shell().error("✗ Failed to create command #{name}: #{inspect(error)}")
        end)

        if Enum.empty?(errors) do
          Mix.shell().info("All global commands created successfully!")
        else
          Mix.shell().info("Global command creation completed with #{length(errors)} error(s).")
        end
    end
  end
end
