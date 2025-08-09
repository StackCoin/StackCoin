defmodule StackCoin.Bot.Discord.Transactions do
  @moduledoc """
  Discord transactions command implementation.
  """

  alias StackCoin.Core.{Bank, User, DiscordGuild}
  alias StackCoin.Bot.Discord.Commands
  alias Nostrum.Api
  alias Nostrum.Constants.InteractionCallbackType
  alias Nostrum.Constants.ApplicationCommandOptionType

  @transactions_per_page 5

  @doc """
  Returns the command definition for the transactions command.
  """
  def definition do
    %{
      name: "transactions",
      description: "Search through StackCoin transactions",
      options: [
        %{
          type: ApplicationCommandOptionType.user(),
          name: "from",
          description: "Show transactions sent by this user",
          required: false
        },
        %{
          type: ApplicationCommandOptionType.user(),
          name: "to",
          description: "Show transactions received by this user",
          required: false
        },
        %{
          type: ApplicationCommandOptionType.user(),
          name: "includes",
          description: "Show transactions involving this user (either sent or received)",
          required: false
        },
        %{
          type: ApplicationCommandOptionType.integer(),
          name: "page",
          description: "Page number to view",
          required: false,
          min_value: 1
        }
      ]
    }
  end

  @doc """
  Handles the transactions command interaction.
  """
  def handle(interaction) do
    with {:ok, guild} <- DiscordGuild.get_guild_by_discord_id(interaction.guild_id),
         {:ok, _channel_check} <- DiscordGuild.validate_channel(guild, interaction.channel_id),
         {:ok, search_opts} <- parse_search_options(interaction),
         {:ok, transactions} <- Bank.search_transactions(search_opts) do
      send_transactions_response(interaction, transactions, search_opts)
    else
      {:error, reason} ->
        Commands.send_error_response(interaction, reason)
    end
  end

  defp parse_search_options(interaction) do
    options = get_options_map(interaction)

    from_user_id = get_user_id_from_option(options["from"])
    to_user_id = get_user_id_from_option(options["to"])
    includes_user_id = get_user_id_from_option(options["includes"])
    page = Map.get(options, "page", 1)

    # Check for conflicting filters
    if includes_user_id && (from_user_id || to_user_id) do
      {:error, :conflicting_transaction_filters}
    else
      offset = (page - 1) * @transactions_per_page
      search_opts = [limit: @transactions_per_page, offset: offset]

      search_opts =
        if from_user_id,
          do: Keyword.put(search_opts, :from_user_id, from_user_id),
          else: search_opts

      search_opts =
        if to_user_id, do: Keyword.put(search_opts, :to_user_id, to_user_id), else: search_opts

      search_opts =
        if includes_user_id,
          do: Keyword.put(search_opts, :includes_user_id, includes_user_id),
          else: search_opts

      {:ok, search_opts}
    end
  end

  defp get_options_map(interaction) do
    case interaction.data.options do
      nil ->
        %{}

      options ->
        Enum.reduce(options, %{}, fn option, acc ->
          Map.put(acc, option.name, option.value)
        end)
    end
  end

  defp get_user_id_from_option(nil), do: nil

  defp get_user_id_from_option(discord_snowflake) do
    case User.get_user_by_discord_id(discord_snowflake) do
      {:ok, user} -> user.id
      {:error, _} -> nil
    end
  end

  defp send_transactions_response(interaction, transactions, search_opts) do
    if Enum.empty?(transactions) do
      send_no_transactions_response(interaction)
    else
      send_transactions_embed(interaction, transactions, search_opts)
    end
  end

  defp send_no_transactions_response(interaction) do
    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        embeds: [
          %{
            title: "#{Commands.stackcoin_emoji()} No Transactions Found",
            description: "No transactions match your search criteria.",
            color: Commands.stackcoin_color()
          }
        ]
      }
    })
  end

  defp send_transactions_embed(interaction, transactions, search_opts) do
    title = build_title(search_opts)
    description = build_description(transactions, search_opts)

    fields =
      transactions
      |> Enum.with_index(1)
      |> Enum.map(fn {transaction, index} ->
        time_str = format_time(transaction.time)
        label_str = if transaction.label, do: " (#{transaction.label})", else: ""

        %{
          name: "#{index}. #{transaction.from_username} → #{transaction.to_username}",
          value: "**#{transaction.amount} STK** • #{time_str}#{label_str}",
          inline: false
        }
      end)

    embed = %{
      title: title,
      description: description,
      color: Commands.stackcoin_color(),
      fields: fields
    }

    Api.create_interaction_response(interaction, %{
      type: InteractionCallbackType.channel_message_with_source(),
      data: %{
        embeds: [embed]
      }
    })
  end

  defp build_title(search_opts) do
    page = Keyword.get(search_opts, :page, 1)

    if page == 1 do
      "#{Commands.stackcoin_emoji()} Recent Transactions"
    else
      "#{Commands.stackcoin_emoji()} Recent Transactions (Page #{page})"
    end
  end

  defp build_description(transactions, search_opts) do
    filter_desc = build_filter_description(search_opts)
    count = length(transactions)
    page = Keyword.get(search_opts, :page, 1)
    per_page = @transactions_per_page

    base_desc =
      if count == per_page do
        if page == 1 do
          "Showing latest #{per_page} transactions"
        else
          start_num = (page - 1) * per_page + 1
          end_num = start_num + count - 1
          "Showing transactions #{start_num}-#{end_num}"
        end
      else
        if page == 1 do
          "Found #{count} transactions"
        else
          start_num = (page - 1) * per_page + 1
          end_num = start_num + count - 1
          "Showing transactions #{start_num}-#{end_num} (#{count} found on this page)"
        end
      end

    if filter_desc do
      "#{base_desc} #{filter_desc}"
    else
      base_desc
    end
  end

  defp build_filter_description(search_opts) do
    cond do
      Keyword.has_key?(search_opts, :from_user_id) ->
        "sent by specified user"

      Keyword.has_key?(search_opts, :to_user_id) ->
        "received by specified user"

      Keyword.has_key?(search_opts, :includes_user_id) ->
        "involving specified user"

      true ->
        nil
    end
  end

  defp format_time(naive_datetime) do
    unix_timestamp = DateTime.from_naive!(naive_datetime, "Etc/UTC") |> DateTime.to_unix()
    "<t:#{unix_timestamp}:f>"
  end
end
