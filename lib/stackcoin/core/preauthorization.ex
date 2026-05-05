defmodule StackCoin.Core.Preauthorization do
  @moduledoc """
  Core preauthorization logic.

  Preauthorizations allow a user to grant a bot permission to spend
  up to a capped amount on their behalf within a rolling time window.
  """

  alias StackCoin.Repo
  alias StackCoin.Schema
  alias StackCoin.Core.Event
  import Ecto.Query

  @doc """
  Creates a new preauthorization request (status: pending).
  """
  def create_preauth(bot_user_id, user_id, max_amount, window_hours) do
    with {:ok, _bot} <- validate_is_bot(bot_user_id),
         {:ok, _} <- validate_params(max_amount, window_hours),
         {:ok, _} <- check_no_existing_preauth(bot_user_id, user_id) do
      attrs = %{
        bot_user_id: bot_user_id,
        user_id: user_id,
        max_amount: max_amount,
        window_hours: window_hours,
        status: "pending",
        requested_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      }

      case %Schema.Preauthorization{}
           |> Schema.Preauthorization.changeset(attrs)
           |> Repo.insert() do
        {:ok, preauth} ->
          preauth = Repo.preload(preauth, [:bot_user, :user])

          fire_event("preauth.created", preauth, %{
            preauth_id: preauth.id,
            bot_user_id: preauth.bot_user_id,
            user_id: preauth.user_id,
            max_amount: preauth.max_amount,
            window_hours: preauth.window_hours
          })

          {:ok, preauth}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Gets a preauthorization by ID with preloaded associations.
  """
  def get_preauth(id) do
    case Repo.get(Schema.Preauthorization, id) do
      nil -> {:error, :preauth_not_found}
      preauth -> {:ok, Repo.preload(preauth, [:bot_user, :user])}
    end
  end

  @doc """
  Approves a pending preauthorization (sets status to active).
  """
  def approve_preauth(id) do
    with {:ok, preauth} <- get_preauth(id),
         {:ok, _} <- validate_status(preauth, "pending", :preauth_not_pending) do
      preauth
      |> Schema.Preauthorization.changeset(%{
        status: "active",
        approved_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      })
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          updated = Repo.preload(updated, [:bot_user, :user])

          fire_event("preauth.approved", updated, %{
            preauth_id: updated.id,
            bot_user_id: updated.bot_user_id,
            user_id: updated.user_id
          })

          {:ok, updated}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Revokes an active preauthorization.
  """
  def revoke_preauth(id) do
    with {:ok, preauth} <- get_preauth(id),
         {:ok, _} <- validate_status(preauth, "active", :preauth_not_active) do
      preauth
      |> Schema.Preauthorization.changeset(%{
        status: "revoked",
        revoked_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      })
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          updated = Repo.preload(updated, [:bot_user, :user])

          fire_event("preauth.revoked", updated, %{
            preauth_id: updated.id,
            bot_user_id: updated.bot_user_id,
            user_id: updated.user_id
          })

          {:ok, updated}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Hard-deletes a pending preauthorization.
  """
  def delete_preauth(id) do
    with {:ok, preauth} <- get_preauth(id),
         {:ok, _} <- validate_status(preauth, "pending", :preauth_not_pending) do
      Repo.delete(preauth)
    end
  end

  @doc """
  Gets the active preauthorization for a bot+user pair.
  """
  def get_active_preauth(bot_user_id, user_id) do
    query =
      from(p in Schema.Preauthorization,
        where:
          p.bot_user_id == ^bot_user_id and
            p.user_id == ^user_id and
            p.status == "active",
        preload: [:bot_user, :user]
      )

    case Repo.one(query) do
      nil -> {:error, :no_active_preauth}
      preauth -> {:ok, preauth}
    end
  end

  @doc """
  Lists preauthorizations for a bot, with optional user_id filter.
  """
  def list_preauths(bot_user_id, opts \\ []) do
    user_id = Keyword.get(opts, :user_id)

    query =
      from(p in Schema.Preauthorization,
        where: p.bot_user_id == ^bot_user_id,
        preload: [:bot_user, :user],
        order_by: [desc: p.id]
      )

    query =
      if user_id do
        from(p in query, where: p.user_id == ^user_id)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Gets the remaining budget for a preauthorization within its rolling window.
  """
  def get_remaining_budget(preauth_id) do
    with {:ok, preauth} <- get_preauth(preauth_id) do
      used = get_used_amount(preauth)
      {:ok, max(preauth.max_amount - used, 0)}
    end
  end

  @doc """
  Checks whether `amount` fits within the preauth's remaining budget.
  """
  def check_budget(preauth, amount) do
    used = get_used_amount(preauth)

    if used + amount <= preauth.max_amount do
      {:ok, preauth.max_amount - used - amount}
    else
      {:error, :budget_exceeded}
    end
  end

  # ── Private helpers ──────────────────────────────────────────────

  defp validate_is_bot(user_id) do
    case Repo.get_by(Schema.BotUser, user_id: user_id) do
      nil -> {:error, :not_bot_user}
      bot -> {:ok, bot}
    end
  end

  defp validate_params(max_amount, window_hours) do
    cond do
      max_amount <= 0 -> {:error, :invalid_max_amount}
      window_hours <= 0 -> {:error, :invalid_window_hours}
      true -> {:ok, :valid}
    end
  end

  defp check_no_existing_preauth(bot_user_id, user_id) do
    query =
      from(p in Schema.Preauthorization,
        where:
          p.bot_user_id == ^bot_user_id and
            p.user_id == ^user_id and
            p.status in ["pending", "active"]
      )

    case Repo.one(query) do
      nil -> {:ok, :no_existing}
      _preauth -> {:error, :preauth_already_exists}
    end
  end

  defp validate_status(preauth, expected, error_atom) do
    if preauth.status == expected do
      {:ok, preauth}
    else
      {:error, error_atom}
    end
  end

  defp get_used_amount(preauth) do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -preauth.window_hours * 3600, :second)

    from(r in Schema.Request,
      where:
        r.preauthorization_id == ^preauth.id and
          r.status == "accepted" and
          r.requested_at > ^cutoff,
      select: coalesce(sum(r.amount), 0)
    )
    |> Repo.one()
  end

  defp fire_event(type, preauth, data) do
    Event.create_event(type, preauth.bot_user_id, data)
    Event.create_event(type, preauth.user_id, data)
  end
end
