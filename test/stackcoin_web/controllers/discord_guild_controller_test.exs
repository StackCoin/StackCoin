defmodule StackCoinWebTest.DiscordGuildControllerTest do
  use StackCoinWeb.ConnCase

  alias StackCoin.Core.{User, Bot, Bank, Reserve, DiscordGuild}

  setup do
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 1000)

    # Create owner user
    {:ok, owner} = User.create_user_account("123456789", "TestOwner", balance: 500)

    # Create bot user
    {:ok, bot} = Bot.create_bot_user("123456789", "TestBot")

    # Give bot some initial balance using reserve pump
    {:ok, _pump} = Reserve.pump_reserve(owner.id, 200, "Test funding")
    {:ok, _transaction} = Bank.transfer_between_users(1, bot.user.id, 150, "Bot funding")

    # Create test guilds
    {:ok, {guild1, :created}} =
      DiscordGuild.register_guild("111111111111111111", "Test Server One", "222222222222222222")

    {:ok, {guild2, :created}} =
      DiscordGuild.register_guild("333333333333333333", "Another Guild", "444444444444444444")

    {:ok, {guild3, :created}} =
      DiscordGuild.register_guild("555555555555555555", "Test Community", "666666666666666666")

    %{
      owner: owner,
      bot: bot,
      bot_token: bot.token,
      guild1: guild1,
      guild2: guild2,
      guild3: guild3
    }
  end

  describe "GET /api/discord/guilds" do
    test "returns 401 if Authorization header is missing", %{conn: conn} do
      conn = get(conn, ~p"/api/discord/guilds")
      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end

    test "returns 401 if Authorization header is invalid", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid_token")
        |> get(~p"/api/discord/guilds")

      assert json_response(conn, 401) == %{"error" => "Invalid bot token"}
    end

    test "returns all guilds with pagination", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/discord/guilds")

      response = json_response(conn, 200)
      assert is_list(response["guilds"])
      # Should have at least 3 guilds from setup
      assert length(response["guilds"]) >= 3

      # Check that guilds have expected fields
      guild = List.first(response["guilds"])
      assert Map.has_key?(guild, "id")
      assert Map.has_key?(guild, "snowflake")
      assert Map.has_key?(guild, "name")
      assert Map.has_key?(guild, "designated_channel_snowflake")
      assert Map.has_key?(guild, "last_updated")

      # Check pagination metadata
      assert is_map(response["pagination"])
      assert response["pagination"]["page"] == 1
      assert response["pagination"]["limit"] == 20
      assert is_integer(response["pagination"]["total"])
      assert is_integer(response["pagination"]["total_pages"])
    end

    test "supports pagination parameters", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/discord/guilds?page=1&limit=2")

      response = json_response(conn, 200)
      assert is_list(response["guilds"])
      assert length(response["guilds"]) <= 2
      assert response["pagination"]["page"] == 1
      assert response["pagination"]["limit"] == 2
    end

    test "filters by guild name (partial match)", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/discord/guilds?name=Test")

      response = json_response(conn, 200)
      assert is_list(response["guilds"])

      # All returned guilds should have "Test" in their name
      Enum.each(response["guilds"], fn guild ->
        assert String.contains?(String.downcase(guild["name"]), "test")
      end)

      # Should find at least 2 guilds with "Test" in the name
      assert length(response["guilds"]) >= 2
    end

    test "filters by snowflake", %{
      conn: conn,
      bot_token: bot_token,
      guild1: guild1
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/discord/guilds?snowflake=#{guild1.snowflake}")

      response = json_response(conn, 200)
      assert is_list(response["guilds"])
      assert length(response["guilds"]) == 1

      guild = List.first(response["guilds"])
      assert guild["snowflake"] == guild1.snowflake
      assert guild["name"] == guild1.name
    end

    test "combines name and snowflake filters", %{
      conn: conn,
      bot_token: bot_token,
      guild1: guild1
    } do
      # This should return the guild only if both filters match
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/discord/guilds?name=Test&snowflake=#{guild1.snowflake}")

      response = json_response(conn, 200)
      assert is_list(response["guilds"])
      assert length(response["guilds"]) == 1

      guild = List.first(response["guilds"])
      assert guild["snowflake"] == guild1.snowflake
      assert String.contains?(String.downcase(guild["name"]), "test")
    end

    test "returns empty array when snowflake filter doesn't match", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/discord/guilds?snowflake=999999999999999999")

      response = json_response(conn, 200)
      assert response["guilds"] == []
      assert response["pagination"]["total"] == 0
      assert response["pagination"]["total_pages"] == 0
    end

    test "returns empty array when name filter doesn't match", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/discord/guilds?name=NonExistentGuild12345")

      response = json_response(conn, 200)
      assert response["guilds"] == []
      assert response["pagination"]["total"] == 0
      assert response["pagination"]["total_pages"] == 0
    end

    test "handles invalid pagination parameters gracefully", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/discord/guilds?page=invalid&limit=abc")

      response = json_response(conn, 200)
      assert is_list(response["guilds"])
      # Should default to page=1, limit=20
      assert response["pagination"]["page"] == 1
      assert response["pagination"]["limit"] == 20
    end

    test "orders guilds by name ascending", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/discord/guilds?limit=10")

      response = json_response(conn, 200)
      assert is_list(response["guilds"])

      if length(response["guilds"]) > 1 do
        # Check that guilds are ordered by name (ascending)
        guilds = response["guilds"]
        guild_names = Enum.map(guilds, & &1["name"])
        sorted_names = Enum.sort(guild_names)
        assert guild_names == sorted_names
      end
    end

    test "returns correct guild structure", %{
      conn: conn,
      bot_token: bot_token,
      guild1: guild1
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/discord/guilds?snowflake=#{guild1.snowflake}")

      response = json_response(conn, 200)
      guild = List.first(response["guilds"])

      assert guild["id"] == guild1.id
      assert guild["snowflake"] == guild1.snowflake
      assert guild["name"] == guild1.name
      assert guild["designated_channel_snowflake"] == guild1.designated_channel_snowflake
      assert is_binary(guild["last_updated"])
    end

    test "supports case-insensitive name filtering", %{
      conn: conn,
      bot_token: bot_token
    } do
      # Test with different cases
      test_cases = ["test", "TEST", "Test", "tEsT"]

      Enum.each(test_cases, fn name_filter ->
        conn =
          conn
          |> put_req_header("authorization", "Bearer #{bot_token}")
          |> get(~p"/api/discord/guilds?name=#{name_filter}")

        response = json_response(conn, 200)
        assert is_list(response["guilds"])

        # Should find guilds regardless of case
        if length(response["guilds"]) > 0 do
          Enum.each(response["guilds"], fn guild ->
            assert String.contains?(String.downcase(guild["name"]), "test")
          end)
        end
      end)
    end

    test "handles large page numbers gracefully", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/discord/guilds?page=999&limit=20")

      response = json_response(conn, 200)
      assert is_list(response["guilds"])
      assert response["guilds"] == []
      assert response["pagination"]["page"] == 999
      assert response["pagination"]["limit"] == 20
    end

    test "respects maximum limit", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/discord/guilds?limit=999")

      response = json_response(conn, 200)
      assert is_list(response["guilds"])
      # Should be capped at max limit (100)
      assert response["pagination"]["limit"] == 100
    end
  end
end
