defmodule StackCoin.Core.Reserve do
  @moduledoc """
  Core logic for handling reserve system operations.
  """

  alias StackCoin.Core.Bank
  alias StackCoin.Repo
  alias StackCoin.Schema.User

  @reserve_user_id 1
  @dole_amount 10

  @doc """
  Transfers the dole amount from the reserve system to a user.
  Returns {:ok, transaction} on success or {:error, reason} on failure.
  """
  def transfer_dole_to_user(user_id) do
    with {:ok, user} <- Bank.get_user_by_id(user_id),
         {:ok, _dole_check} <- check_daily_dole_eligibility(user),
         {:ok, reserve_balance} <- get_reserve_balance(),
         {:ok, _balance_check} <- check_reserve_balance(reserve_balance),
         {:ok, transaction} <-
           Bank.transfer_between_users(@reserve_user_id, user_id, @dole_amount, "Daily dole"),
         {:ok, _updated_user} <- update_last_given_dole(user_id) do
      {:ok, transaction}
    else
      {:error, :user_not_found} ->
        {:error, :user_not_found}

      {:error, :insufficient_balance} ->
        {:error, :insufficient_reserve_balance}

      {:error, {:dole_already_given_today, timestamp}} ->
        {:error, {:dole_already_given_today, timestamp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets the current balance of the reserve system.
  """
  def get_reserve_balance do
    case Bank.get_user_balance(@reserve_user_id) do
      {:ok, balance} -> {:ok, balance}
      {:error, :user_not_found} -> {:error, :reserve_user_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_reserve_balance(balance) do
    if balance >= @dole_amount do
      {:ok, :sufficient_balance}
    else
      {:error, :insufficient_reserve_balance}
    end
  end

  defp check_daily_dole_eligibility(user) do
    today = Date.utc_today()

    case user.last_given_dole do
      nil ->
        {:ok, :eligible}

      last_dole_datetime ->
        last_dole_date = NaiveDateTime.to_date(last_dole_datetime)

        if Date.compare(last_dole_date, today) == :lt do
          # Last dole was before today
          {:ok, :eligible}
        else
          # Already received dole today - calculate next day timestamp
          next_day = Date.add(today, 1)
          next_day_start = DateTime.new!(next_day, ~T[00:00:00], "Etc/UTC")
          next_day_unix = DateTime.to_unix(next_day_start)
          {:error, {:dole_already_given_today, next_day_unix}}
        end
    end
  end

  defp update_last_given_dole(user_id) do
    case Bank.get_user_by_id(user_id) do
      {:ok, user} ->
        user
        |> User.changeset(%{last_given_dole: NaiveDateTime.utc_now()})
        |> Repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end
end
