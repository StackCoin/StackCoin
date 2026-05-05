defmodule StackCoin.Bot.Discord.PreauthTest do
  use StackCoin.DataCase
  alias StackCoin.Bot.Discord.Preauth

  describe "parse_custom_id/1" do
    test "parses accept" do
      assert Preauth.parse_custom_id("preauth_accept_42") == {:ok, {:accept, 42}}
    end

    test "parses deny" do
      assert Preauth.parse_custom_id("preauth_deny_42") == {:ok, {:deny, 42}}
    end

    test "parses revoke" do
      assert Preauth.parse_custom_id("preauth_revoke_42") == {:ok, {:revoke, 42}}
    end

    test "returns error for invalid id string" do
      assert Preauth.parse_custom_id("preauth_accept_abc") == {:error, :invalid_custom_id}
    end

    test "returns error for unknown prefix" do
      assert Preauth.parse_custom_id("something_else") == {:error, :invalid_custom_id}
    end

    test "returns error for trailing characters" do
      assert Preauth.parse_custom_id("preauth_accept_42abc") == {:error, :invalid_custom_id}
    end
  end
end
