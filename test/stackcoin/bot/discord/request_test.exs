defmodule StackCoin.Bot.Discord.RequestTest do
  use StackCoin.DataCase
  alias StackCoin.Bot.Discord.Request

  describe "parse_custom_id/1" do
    test "parses accept custom ID correctly" do
      assert Request.parse_custom_id("request_accept_123") == {:ok, {:accept, 123}}
    end

    test "parses deny custom ID correctly" do
      assert Request.parse_custom_id("request_deny_456") == {:ok, {:deny, 456}}
    end

    test "returns error for invalid custom ID" do
      assert Request.parse_custom_id("invalid_id") == {:error, :invalid_custom_id}
      assert Request.parse_custom_id("request_accept_abc") == {:error, :invalid_custom_id}
    end
  end
end
