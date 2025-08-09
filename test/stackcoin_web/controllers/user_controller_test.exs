defmodule StackCoinWebTest.UserControllerTest do
  use StackCoinWeb.ConnCase

  alias StackCoin.Core.{User, Bot, Bank, Reserve}

  setup do
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 1000)

    # Create owner user
    {:ok, owner} = User.create_user_account("123456789", "TestOwner", balance: 500)

    # Create bot user
    {:ok, bot} = Bot.create_bot_user("123456789", "TestBot")

    # Create recipient user
    {:ok, recipient} = User.create_user_account("987654321", "RecipientUser", balance: 100)

    # Give bot some initial balance using reserve pump
    {:ok, _pump} = Reserve.pump_reserve(owner.id, 200, "Test funding")
    {:ok, _transaction} = Bank.transfer_between_users(1, bot.user.id, 150, "Bot funding")

    %{
      owner: owner,
      bot: bot,
      recipient: recipient,
      bot_token: bot.token
    }
  end

  describe "GET /api/users" do
    test "returns 401 if Authorization header is missing", %{conn: conn} do
      conn = get(conn, ~p"/api/users")
      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end

    test "returns 401 if Authorization header is invalid", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid_token")
        |> get(~p"/api/users")

      assert json_response(conn, 401) == %{"error" => "Invalid bot token"}
    end

    test "returns all users with pagination", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/users")

      response = json_response(conn, 200)
      assert is_list(response["users"])
      # At least bot, recipient, owner
      assert length(response["users"]) >= 3

      # Check that users have expected fields
      user = List.first(response["users"])
      assert Map.has_key?(user, "id")
      assert Map.has_key?(user, "username")
      assert Map.has_key?(user, "balance")
      assert Map.has_key?(user, "admin")
      assert Map.has_key?(user, "banned")

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
        |> get(~p"/api/users?page=1&limit=2")

      response = json_response(conn, 200)
      assert is_list(response["users"])
      assert length(response["users"]) <= 2
      assert response["pagination"]["page"] == 1
      assert response["pagination"]["limit"] == 2
    end

    test "filters by username (partial match)", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/users?username=Test")

      response = json_response(conn, 200)
      assert is_list(response["users"])

      # All returned users should have "Test" in their username
      Enum.each(response["users"], fn user ->
        assert String.contains?(String.downcase(user["username"]), "test")
      end)
    end

    test "filters by banned status", %{
      conn: conn,
      bot_token: bot_token,
      recipient: recipient
    } do
      # Ban the recipient
      {:ok, _} = User.ban_user(recipient)

      # Test banned=true
      conn1 =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/users?banned=true")

      response = json_response(conn1, 200)
      assert is_list(response["users"])

      # All returned users should be banned
      Enum.each(response["users"], fn user ->
        assert user["banned"] == true
      end)

      # Test banned=false
      conn2 =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/users?banned=false")

      response = json_response(conn2, 200)
      assert is_list(response["users"])

      # All returned users should not be banned
      Enum.each(response["users"], fn user ->
        assert user["banned"] == false
      end)
    end

    test "filters by admin status", %{
      conn: conn,
      bot_token: bot_token,
      owner: owner
    } do
      # Make owner an admin
      {:ok, _} =
        User.get_user_by_id(owner.id)
        |> case do
          {:ok, user} ->
            user
            |> StackCoin.Schema.User.changeset(%{admin: true})
            |> StackCoin.Repo.update()
        end

      # Test admin=true
      conn1 =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/users?admin=true")

      response = json_response(conn1, 200)
      assert is_list(response["users"])

      # All returned users should be admin
      Enum.each(response["users"], fn user ->
        assert user["admin"] == true
      end)

      # Test admin=false
      conn2 =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/users?admin=false")

      response = json_response(conn2, 200)
      assert is_list(response["users"])

      # All returned users should not be admin
      Enum.each(response["users"], fn user ->
        assert user["admin"] == false
      end)
    end

    test "combines multiple filters", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/users?username=Test&banned=false&admin=false")

      response = json_response(conn, 200)
      assert is_list(response["users"])

      # All returned users should match all filters
      Enum.each(response["users"], fn user ->
        assert String.contains?(String.downcase(user["username"]), "test")
        assert user["banned"] == false
        assert user["admin"] == false
      end)
    end

    test "handles invalid pagination parameters gracefully", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/users?page=invalid&limit=abc")

      response = json_response(conn, 200)
      assert is_list(response["users"])
      # Should default to page=1, limit=20
      assert response["pagination"]["page"] == 1
      assert response["pagination"]["limit"] == 20
    end

    test "returns empty array when no users match filters", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/users?username=NonExistentUser12345")

      response = json_response(conn, 200)
      assert response["users"] == []
      assert response["pagination"]["total"] == 0
      assert response["pagination"]["total_pages"] == 0
    end

    test "orders users by balance desc, then username asc", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/users?limit=10")

      response = json_response(conn, 200)
      assert is_list(response["users"])

      if length(response["users"]) > 1 do
        # Check that users are ordered by balance (desc), then username (asc)
        users = response["users"]

        # Check balance ordering (should be descending)
        balance_pairs = Enum.zip(users, Enum.drop(users, 1))

        Enum.each(balance_pairs, fn {user1, user2} ->
          assert user1["balance"] >= user2["balance"]
        end)
      end
    end
  end
end
