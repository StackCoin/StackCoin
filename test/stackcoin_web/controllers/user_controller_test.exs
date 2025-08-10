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

    # Get the bot user again, with the updated balance
    {:ok, bot} = Bot.get_bot_by_name("TestBot")

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

  describe "GET /api/user/:user_id" do
    test "returns 401 if Authorization header is missing", %{conn: conn, owner: owner} do
      conn = get(conn, ~p"/api/user/#{owner.id}")
      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end

    test "returns 401 if Authorization header is invalid", %{conn: conn, owner: owner} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid_token")
        |> get(~p"/api/user/#{owner.id}")

      assert json_response(conn, 401) == %{"error" => "Invalid bot token"}
    end

    test "returns user when found", %{
      conn: conn,
      bot_token: bot_token,
      owner: owner
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/user/#{owner.id}")

      response = json_response(conn, 200)
      assert is_map(response)

      assert response["id"] == owner.id
      assert response["username"] == owner.username
      assert response["balance"] == owner.balance
      assert response["admin"] == owner.admin
      assert response["banned"] == owner.banned
      assert is_binary(response["inserted_at"])
      assert is_binary(response["updated_at"])
    end

    test "returns 404 when user not found", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/user/99999")

      response = json_response(conn, 404)
      assert response == %{"error" => "User not found"}
    end

    test "returns 400 for invalid user_id", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/user/invalid_id")

      response = json_response(conn, 400)
      assert response == %{"error" => "Invalid user ID"}
    end

    test "returns correct user structure", %{
      conn: conn,
      bot_token: bot_token,
      recipient: recipient
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/user/#{recipient.id}")

      response = json_response(conn, 200)

      # Verify all expected fields are present
      assert Map.has_key?(response, "id")
      assert Map.has_key?(response, "username")
      assert Map.has_key?(response, "balance")
      assert Map.has_key?(response, "admin")
      assert Map.has_key?(response, "banned")
      assert Map.has_key?(response, "inserted_at")
      assert Map.has_key?(response, "updated_at")

      # Verify field types
      assert is_integer(response["id"])
      assert is_binary(response["username"])
      assert is_integer(response["balance"])
      assert is_boolean(response["admin"])
      assert is_boolean(response["banned"])
      assert is_binary(response["inserted_at"])
      assert is_binary(response["updated_at"])
    end

    test "returns user with different admin/banned states", %{
      conn: conn,
      bot_token: bot_token,
      recipient: recipient
    } do
      # Make recipient an admin and ban them
      {:ok, _updated_user} =
        recipient
        |> StackCoin.Schema.User.changeset(%{admin: true, banned: true})
        |> StackCoin.Repo.update()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/user/#{recipient.id}")

      response = json_response(conn, 200)

      assert response["id"] == recipient.id
      assert response["admin"] == true
      assert response["banned"] == true
      assert response["username"] == recipient.username
    end

    test "returns user with zero balance", %{
      conn: conn,
      bot_token: bot_token
    } do
      # Create a user with zero balance
      {:ok, zero_balance_user} =
        User.create_user_account("555555555", "ZeroBalanceUser", balance: 0)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/user/#{zero_balance_user.id}")

      response = json_response(conn, 200)

      assert response["id"] == zero_balance_user.id
      assert response["username"] == "ZeroBalanceUser"
      assert response["balance"] == 0
      assert response["admin"] == false
      assert response["banned"] == false
    end

    test "returns user with high balance", %{
      conn: conn,
      bot_token: bot_token
    } do
      # Create a user with high balance
      {:ok, rich_user} = User.create_user_account("666666666", "RichUser", balance: 999_999)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/user/#{rich_user.id}")

      response = json_response(conn, 200)

      assert response["id"] == rich_user.id
      assert response["username"] == "RichUser"
      assert response["balance"] == 999_999
      assert response["admin"] == false
      assert response["banned"] == false
    end
  end

  describe "GET /api/user/me" do
    test "returns 401 if Authorization header is missing", %{conn: conn} do
      conn = get(conn, ~p"/api/user/me")
      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end

    test "returns 401 if Authorization header is invalid", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid_token")
        |> get(~p"/api/user/me")

      assert json_response(conn, 401) == %{"error" => "Invalid bot token"}
    end

    test "returns authenticated bot user profile", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/user/me")

      response = json_response(conn, 200)
      assert is_map(response)

      assert response["id"] == bot.user.id
      assert response["username"] == bot.user.username
      assert response["balance"] == bot.user.balance
      assert response["admin"] == bot.user.admin
      assert response["banned"] == bot.user.banned
      assert is_binary(response["inserted_at"])
      assert is_binary(response["updated_at"])
    end

    test "returns correct user structure for authenticated bot", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/user/me")

      response = json_response(conn, 200)

      # Verify all expected fields are present
      assert Map.has_key?(response, "id")
      assert Map.has_key?(response, "username")
      assert Map.has_key?(response, "balance")
      assert Map.has_key?(response, "admin")
      assert Map.has_key?(response, "banned")
      assert Map.has_key?(response, "inserted_at")
      assert Map.has_key?(response, "updated_at")

      # Verify field types
      assert is_integer(response["id"])
      assert is_binary(response["username"])
      assert is_integer(response["balance"])
      assert is_boolean(response["admin"])
      assert is_boolean(response["banned"])
      assert is_binary(response["inserted_at"])
      assert is_binary(response["updated_at"])
    end

    test "returns current balance from setup", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/user/me")

      response = json_response(conn, 200)

      # Bot should have 150 balance from setup (received from reserve)
      assert response["balance"] == bot.user.balance
      assert response["username"] == "TestBot"
      assert response["admin"] == false
      assert response["banned"] == false
    end

    test "reflects balance changes after transactions", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Get initial balance
      conn_initial =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/user/me")

      initial_response = json_response(conn_initial, 200)
      initial_balance = initial_response["balance"]

      # Make a transaction
      {:ok, _transaction} =
        Bank.transfer_between_users(bot.user.id, recipient.id, 25, "Test spend")

      # Check balance after transaction
      conn_after =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/user/me")

      after_response = json_response(conn_after, 200)

      # Balance should be reduced by 25
      assert after_response["balance"] == initial_balance - 25
      assert after_response["id"] == bot.user.id
      assert after_response["username"] == "TestBot"
    end

    test "works with different bot tokens", %{conn: conn, owner: owner} do
      # Create another bot
      {:ok, another_bot} = Bot.create_bot_user("123456789", "AnotherBot")

      # Give the new bot some balance
      {:ok, _transaction} =
        Bank.transfer_between_users(owner.id, another_bot.user.id, 100, "Fund new bot")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{another_bot.token}")
        |> get(~p"/api/user/me")

      response = json_response(conn, 200)

      assert response["id"] == another_bot.user.id
      assert response["username"] == "AnotherBot"
      assert response["balance"] == 100
      assert response["admin"] == false
      assert response["banned"] == false
    end

    test "returns updated user state after admin/banned changes", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot
    } do
      # Make bot an admin
      {:ok, _updated_user} =
        bot.user
        |> StackCoin.Schema.User.changeset(%{admin: true})
        |> StackCoin.Repo.update()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/user/me")

      response = json_response(conn, 200)

      assert response["id"] == bot.user.id
      assert response["admin"] == true
      assert response["banned"] == false
    end

    test "provides replacement for balance controller self_balance", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot
    } do
      # Test that /user/me provides same info as /balance but with more details
      conn_me =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/user/me")

      me_response = json_response(conn_me, 200)

      # Should have balance and username like the old balance endpoint
      assert Map.has_key?(me_response, "balance")
      assert Map.has_key?(me_response, "username")
      assert me_response["balance"] == bot.user.balance
      assert me_response["username"] == bot.user.username

      # But also have additional user profile information
      assert Map.has_key?(me_response, "id")
      assert Map.has_key?(me_response, "admin")
      assert Map.has_key?(me_response, "banned")
      assert Map.has_key?(me_response, "inserted_at")
      assert Map.has_key?(me_response, "updated_at")
    end
  end
end
