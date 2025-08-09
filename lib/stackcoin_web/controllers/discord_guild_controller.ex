defmodule StackCoinWeb.DiscordGuildController do
  use StackCoinWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias StackCoin.Core.DiscordGuild
  alias StackCoinWeb.ApiHelpers

  operation :show,
    operation_id: "stackcoin_discord_guild",
    summary: "Get Discord guild by snowflake",
    description: "Retrieves a single Discord guild by its snowflake ID.",
    parameters: [
      snowflake: [
        in: :path,
        description: "Discord guild snowflake ID",
        type: :string,
        example: "123456789012345678"
      ]
    ],
    responses: [
      ok:
        {"Discord guild response", "application/json", StackCoinWeb.Schemas.DiscordGuildResponse},
      not_found: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse}
    ]

  operation :index,
    operation_id: "stackcoin_discord_guilds",
    summary: "Get Discord guilds",
    description: "Retrieves Discord guilds with optional filtering and pagination.",
    parameters: [
      page: [in: :query, description: "Page number", type: :integer, example: 1],
      limit: [in: :query, description: "Items per page", type: :integer, example: 20],
      name: [in: :query, description: "Filter by guild name", type: :string, example: "My Server"],
      snowflake: [
        in: :query,
        description: "Filter by Discord snowflake ID",
        type: :string,
        example: "123456789012345678"
      ]
    ],
    responses: [
      ok:
        {"Discord guilds response", "application/json",
         StackCoinWeb.Schemas.DiscordGuildsResponse}
    ]

  def index(conn, params) do
    %{page: page, limit: limit, offset: offset} = ApiHelpers.parse_pagination_params(params)

    # Parse filter parameters
    name = Map.get(params, "name")
    snowflake = Map.get(params, "snowflake")

    opts = [limit: limit, offset: offset]
    opts = if name, do: Keyword.put(opts, :name, name), else: opts
    opts = if snowflake, do: Keyword.put(opts, :snowflake, snowflake), else: opts

    {:ok, %{guilds: guilds, total_count: total_count}} = DiscordGuild.search_guilds(opts)

    formatted_guilds =
      Enum.map(guilds, fn guild ->
        %{
          id: guild.id,
          snowflake: guild.snowflake,
          name: guild.name,
          designated_channel_snowflake: guild.designated_channel_snowflake,
          last_updated: guild.last_updated
        }
      end)

    total_pages = ceil(total_count / limit)

    json(conn, %{
      guilds: formatted_guilds,
      pagination: %{
        page: page,
        limit: limit,
        total: total_count,
        total_pages: total_pages
      }
    })
  end

  def show(conn, %{"snowflake" => snowflake}) do
    case DiscordGuild.get_guild_by_discord_id(snowflake) do
      {:ok, guild} ->
        formatted_guild = %{
          id: guild.id,
          snowflake: guild.snowflake,
          name: guild.name,
          designated_channel_snowflake: guild.designated_channel_snowflake,
          last_updated: guild.last_updated
        }

        json(conn, formatted_guild)

      {:error, :guild_not_registered} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Guild not found"})
    end
  end
end
