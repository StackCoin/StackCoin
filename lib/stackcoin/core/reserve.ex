defmodule StackCoin.Core.Reserve do
  @moduledoc """
  Core logic for handling reserve system operations.
  """

  alias StackCoin.Core.Bank
  alias StackCoin.Repo
  alias StackCoin.Schema.{User, Pump}

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

  @doc """
  Pumps money into the reserve system.
  Creates a pump record and updates the reserve balance.
  """
  def pump_reserve(signee_user_id, amount, label \\ "Admin pump") do
    Repo.transaction(fn ->
      with {:ok, signee} <- Bank.get_user_by_id(signee_user_id),
           {:ok, reserve_user} <- Bank.get_user_by_id(@reserve_user_id),
           {:ok, pump_record} <- create_pump_record(signee.id, @reserve_user_id, amount, label),
           {:ok, _updated_reserve} <-
             Bank.update_user_balance(@reserve_user_id, reserve_user.balance + amount) do
        pump_record
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Admin-only pump operation with permission check.
  """
  def admin_pump_reserve(admin_discord_snowflake, amount, label \\ "Admin pump") do
    with {:ok, _admin_check} <- Bank.check_admin_permissions(admin_discord_snowflake),
         {:ok, admin_user} <- Bank.get_user_by_discord_id(admin_discord_snowflake) do
      pump_reserve(admin_user.id, amount, label)
    else
      {:error, :not_admin} -> {:error, :not_admin}
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

  defp create_pump_record(signee_id, to_id, amount, label) do
    with {:ok, reserve_user} <- Bank.get_user_by_id(to_id) do
      pump_attrs = %{
        signee_id: signee_id,
        to_id: to_id,
        to_new_balance: reserve_user.balance + amount,
        amount: amount,
        time: NaiveDateTime.utc_now(),
        label: label
      }

      Repo.insert(Pump.changeset(%Pump{}, pump_attrs))
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
