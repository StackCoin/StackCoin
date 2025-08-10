defmodule StackCoinWebTest.ApiHelpersTest do
  use ExUnit.Case, async: true

  alias StackCoinWeb.ApiHelpers

  describe "parse_time_duration/1" do
    test "returns {:ok, nil} for nil input" do
      assert ApiHelpers.parse_time_duration(nil) == {:ok, nil}
    end

    test "returns {:ok, nil} for empty string" do
      assert ApiHelpers.parse_time_duration("") == {:ok, nil}
    end

    test "parses seconds correctly" do
      {:ok, datetime} = ApiHelpers.parse_time_duration("30s")
      assert %NaiveDateTime{} = datetime

      # Should be approximately 30 seconds ago
      now = NaiveDateTime.utc_now()
      diff = NaiveDateTime.diff(now, datetime, :second)
      assert diff >= 29 and diff <= 31
    end

    test "parses minutes correctly" do
      {:ok, datetime} = ApiHelpers.parse_time_duration("5m")
      assert %NaiveDateTime{} = datetime

      # Should be approximately 5 minutes ago
      now = NaiveDateTime.utc_now()
      diff = NaiveDateTime.diff(now, datetime, :second)
      assert diff >= 299 and diff <= 301
    end

    test "parses hours correctly" do
      {:ok, datetime} = ApiHelpers.parse_time_duration("2h")
      assert %NaiveDateTime{} = datetime

      # Should be approximately 2 hours ago
      now = NaiveDateTime.utc_now()
      diff = NaiveDateTime.diff(now, datetime, :second)
      assert diff >= 7199 and diff <= 7201
    end

    test "parses days correctly" do
      {:ok, datetime} = ApiHelpers.parse_time_duration("3d")
      assert %NaiveDateTime{} = datetime

      # Should be approximately 3 days ago
      now = NaiveDateTime.utc_now()
      diff = NaiveDateTime.diff(now, datetime, :second)
      expected = 3 * 24 * 60 * 60
      assert diff >= expected - 1 and diff <= expected + 1
    end

    test "parses weeks correctly" do
      {:ok, datetime} = ApiHelpers.parse_time_duration("1w")
      assert %NaiveDateTime{} = datetime

      # Should be approximately 1 week ago
      now = NaiveDateTime.utc_now()
      diff = NaiveDateTime.diff(now, datetime, :second)
      expected = 7 * 24 * 60 * 60
      assert diff >= expected - 1 and diff <= expected + 1
    end

    test "handles case insensitive input" do
      {:ok, datetime1} = ApiHelpers.parse_time_duration("1D")
      {:ok, datetime2} = ApiHelpers.parse_time_duration("1d")

      # Both should be approximately the same
      diff = abs(NaiveDateTime.diff(datetime1, datetime2, :second))
      assert diff <= 1
    end

    test "returns error for invalid format" do
      assert ApiHelpers.parse_time_duration("invalid") == {:error, :invalid_time_format}
    end

    test "returns error for invalid unit" do
      assert ApiHelpers.parse_time_duration("5x") == {:error, :invalid_time_format}
    end

    test "returns error for missing number" do
      assert ApiHelpers.parse_time_duration("d") == {:error, :invalid_time_format}
    end

    test "returns error for missing unit" do
      assert ApiHelpers.parse_time_duration("5") == {:error, :invalid_time_format}
    end

    test "returns error for zero duration" do
      assert ApiHelpers.parse_time_duration("0s") == {:error, :invalid_time_format}
    end

    test "returns error for negative duration" do
      assert ApiHelpers.parse_time_duration("-5m") == {:error, :invalid_time_format}
    end

    test "returns error for non-string input" do
      assert ApiHelpers.parse_time_duration(123) == {:error, :invalid_time_format}
      assert ApiHelpers.parse_time_duration(%{}) == {:error, :invalid_time_format}
    end

    test "handles large numbers" do
      {:ok, datetime} = ApiHelpers.parse_time_duration("999d")
      assert %NaiveDateTime{} = datetime

      now = NaiveDateTime.utc_now()
      diff = NaiveDateTime.diff(now, datetime, :second)
      expected = 999 * 24 * 60 * 60
      assert diff >= expected - 1 and diff <= expected + 1
    end
  end
end
