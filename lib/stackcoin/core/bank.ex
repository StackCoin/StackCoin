defmodule StackCoin.Core.Bank do
  @moduledoc """
  Core banking operations for transactions and balances.
  """

  alias StackCoin.Repo
  alias StackCoin.Schema
  alias StackCoin.Core.{User, Bot}
  import Ecto.Query

  @max_limit 100

  @doc """
  Creates a transaction between two users.
  Updates both user balances and creates a transaction record.
  """
  def transfer_between_users(from_user_id, to_user_id, amount, label \\ nil) do
    Repo.transaction(fn ->
      with {:ok, _amount_check} <- validate_transfer_amount(amount),
           {:ok, _self_check} <- validate_not_self_transfer(from_user_id, to_user_id),
           {:ok, from_user} <- User.get_user_by_id(from_user_id),
           {:ok, to_user} <- User.get_user_by_id(to_user_id),
           {:ok, _from_banned_check} <- User.check_user_banned(from_user),
           {:ok, _to_banned_check} <- User.check_recipient_banned(to_user),
           {:ok, _balance_check} <- check_sufficient_balance(from_user, amount),
           {:ok, transaction} <- create_transaction(from_user, to_user, amount, label) do
        transaction
      else
        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Gets the balance of a user.
  """
  def get_user_balance(user_id) do
    case User.get_user_by_id(user_id) do
      {:ok, user} -> {:ok, user.balance}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets a transaction by ID with user details.
  """
  def get_transaction_by_id(transaction_id) do
    query =
      from(t in Schema.Transaction,
        join: from_user in Schema.User,
        on: t.from_id == from_user.id,
        join: to_user in Schema.User,
        on: t.to_id == to_user.id,
        where: t.id == ^transaction_id,
        select: %{
          id: t.id,
          from_id: t.from_id,
          from_username: from_user.username,
          to_id: t.to_id,
          to_username: to_user.username,
          amount: t.amount,
          time: t.time,
          label: t.label
        }
      )

    case Repo.one(query) do
      nil -> {:error, :transaction_not_found}
      transaction -> {:ok, transaction}
    end
  end

  @doc """
  Updates a user's balance directly.
  """
  def update_user_balance(user_id, new_balance) do
    case User.get_user_by_id(user_id) do
      {:ok, user} ->
        user
        |> Schema.User.changeset(%{balance: new_balance})
        |> Repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets the top N users by balance.
  """
  def get_top_users(limit \\ 5) do
    query =
      from(u in Schema.User,
        where: u.banned == false,
        order_by: [desc: u.balance],
        limit: ^limit,
        select: u
      )

    {:ok, Repo.all(query)}
  end

  @doc """
  Gets a user's balance history over time based on their transactions.
  Returns a list of {timestamp, balance} tuples showing balance after each transaction.
  """
  def get_user_balance_history(user_id) do
    with {:ok, user} <- User.get_user_by_id(user_id) do
      query =
        from(t in Schema.Transaction,
          where: t.from_id == ^user_id or t.to_id == ^user_id,
          order_by: [asc: t.time],
          select: %{
            time: t.time,
            from_id: t.from_id,
            to_id: t.to_id,
            from_new_balance: t.from_new_balance,
            to_new_balance: t.to_new_balance
          }
        )

      transactions = Repo.all(query)

      balance_history =
        transactions
        |> Enum.map(fn transaction ->
          balance =
            if transaction.from_id == user_id do
              transaction.from_new_balance
            else
              transaction.to_new_balance
            end

          {transaction.time, balance}
        end)

      # Add current balance as the latest point if there are transactions
      final_history =
        case balance_history do
          [] -> [{NaiveDateTime.utc_now(), user.balance}]
          _ -> balance_history ++ [{NaiveDateTime.utc_now(), user.balance}]
        end

      {:ok, final_history}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Searches transactions with various filters and pagination.
  Options:
  - :from_user_id - filter by sender
  - :to_user_id - filter by recipient
  - :includes_user_id - filter by either sender or recipient
  - :from_discord_id - filter by sender's Discord ID
  - :to_discord_id - filter by recipient's Discord ID
  - :includes_discord_id - filter by either sender or recipient Discord ID
  - :limit - number of results to return (max #{@max_limit})
  - :offset - number of results to skip
  """
  def search_transactions(opts \\ []) do
    limit = min(Keyword.get(opts, :limit, 10), @max_limit)
    offset = Keyword.get(opts, :offset, 0)
    from_user_id = Keyword.get(opts, :from_user_id)
    to_user_id = Keyword.get(opts, :to_user_id)
    includes_user_id = Keyword.get(opts, :includes_user_id)
    from_discord_id = Keyword.get(opts, :from_discord_id)
    to_discord_id = Keyword.get(opts, :to_discord_id)
    includes_discord_id = Keyword.get(opts, :includes_discord_id)

    # Validate that includes_user_id is not used with from/to filters
    if includes_user_id && (from_user_id || to_user_id) do
      {:error, :conflicting_filters}
    else
      # Get total count for pagination metadata
      count_query =
        build_transaction_count_query(
          from_user_id,
          to_user_id,
          includes_user_id,
          from_discord_id,
          to_discord_id,
          includes_discord_id
        )

      total_count = Repo.aggregate(count_query, :count, :id)

      # Get paginated results
      query =
        build_transaction_query(
          from_user_id,
          to_user_id,
          includes_user_id,
          from_discord_id,
          to_discord_id,
          includes_discord_id,
          limit,
          offset
        )

      transactions = Repo.all(query)

      {:ok, %{transactions: transactions, total_count: total_count}}
    end
  end

  defp build_transaction_count_query(
         from_user_id,
         to_user_id,
         includes_user_id,
         from_discord_id,
         to_discord_id,
         includes_discord_id
       ) do
    query = from(t in Schema.Transaction)

    query
    |> apply_from_filter(from_user_id)
    |> apply_to_filter(to_user_id)
    |> apply_includes_filter(includes_user_id)
    |> apply_from_discord_filter(from_discord_id)
    |> apply_to_discord_filter(to_discord_id)
    |> apply_includes_discord_filter(includes_discord_id)
  end

  defp build_transaction_query(
         from_user_id,
         to_user_id,
         includes_user_id,
         from_discord_id,
         to_discord_id,
         includes_discord_id,
         limit,
         offset
       ) do
    query =
      from(t in Schema.Transaction,
        join: from_user in Schema.User,
        on: t.from_id == from_user.id,
        join: to_user in Schema.User,
        on: t.to_id == to_user.id,
        order_by: [desc: t.time],
        limit: ^limit,
        offset: ^offset,
        select: %{
          id: t.id,
          from_id: t.from_id,
          from_username: from_user.username,
          to_id: t.to_id,
          to_username: to_user.username,
          amount: t.amount,
          time: t.time,
          label: t.label
        }
      )

    query
    |> apply_from_filter(from_user_id)
    |> apply_to_filter(to_user_id)
    |> apply_includes_filter(includes_user_id)
    |> apply_from_discord_filter(from_discord_id)
    |> apply_to_discord_filter(to_discord_id)
    |> apply_includes_discord_filter(includes_discord_id)
  end

  defp apply_from_filter(query, nil), do: query

  defp apply_from_filter(query, from_user_id) do
    from(t in query, where: t.from_id == ^from_user_id)
  end

  defp apply_to_filter(query, nil), do: query

  defp apply_to_filter(query, to_user_id) do
    from(t in query, where: t.to_id == ^to_user_id)
  end

  defp apply_includes_filter(query, nil), do: query

  defp apply_includes_filter(query, includes_user_id) do
    from(t in query, where: t.from_id == ^includes_user_id or t.to_id == ^includes_user_id)
  end

  defp apply_from_discord_filter(query, nil), do: query

  defp apply_from_discord_filter(query, from_discord_id) do
    from(t in query,
      join: du in Schema.DiscordUser,
      on: du.id == t.from_id,
      where: du.snowflake == ^to_string(from_discord_id)
    )
  end

  defp apply_to_discord_filter(query, nil), do: query

  defp apply_to_discord_filter(query, to_discord_id) do
    from(t in query,
      join: du in Schema.DiscordUser,
      on: du.id == t.to_id,
      where: du.snowflake == ^to_string(to_discord_id)
    )
  end

  defp apply_includes_discord_filter(query, nil), do: query

  defp apply_includes_discord_filter(query, includes_discord_id) do
    from(t in query,
      join: from_du in Schema.DiscordUser,
      on: from_du.id == t.from_id,
      join: to_du in Schema.DiscordUser,
      on: to_du.id == t.to_id,
      where:
        from_du.snowflake == ^to_string(includes_discord_id) or
          to_du.snowflake == ^to_string(includes_discord_id)
    )
  end

  defp validate_transfer_amount(amount) when amount <= 0, do: {:error, :invalid_amount}
  defp validate_transfer_amount(_amount), do: {:ok, :valid}

  defp validate_not_self_transfer(from_id, to_id) when from_id == to_id,
    do: {:error, :self_transfer}

  defp validate_not_self_transfer(_from_id, _to_id), do: {:ok, :valid}

  defp check_sufficient_balance(user, amount) do
    if user.balance >= amount do
      {:ok, :sufficient}
    else
      {:error, :insufficient_balance}
    end
  end

  @doc """
  Bot transfer - allows a bot to send STK from its own balance.
  """
  def bot_transfer(bot_token, to_user_id, amount, label \\ nil) do
    with {:ok, bot} <- Bot.get_bot_by_token(bot_token),
         {:ok, to_user} <- User.get_user_by_id(to_user_id) do
      transfer_between_users(bot.user.id, to_user.id, amount, label)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_transaction(from_user, to_user, amount, label) do
    new_from_balance = from_user.balance - amount
    new_to_balance = to_user.balance + amount

    transaction_attrs = %{
      from_id: from_user.id,
      from_new_balance: new_from_balance,
      to_id: to_user.id,
      to_new_balance: new_to_balance,
      amount: amount,
      time: NaiveDateTime.utc_now(),
      label: label
    }

    with {:ok, transaction} <-
           Repo.insert(Schema.Transaction.changeset(%Schema.Transaction{}, transaction_attrs)),
         {:ok, _from_user} <- update_user_balance(from_user.id, new_from_balance),
         {:ok, _to_user} <- update_user_balance(to_user.id, new_to_balance) do
      {:ok, transaction}
    else
      {:error, changeset} -> {:error, changeset}
    end
  end
end
