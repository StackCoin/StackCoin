defmodule StackCoin.Core.Idempotency do
  import Ecto.Query

  alias StackCoin.Repo
  alias StackCoin.Schema.IdempotencyKey

  @max_age_days 7

  def check(bot_id, key) do
    case Repo.get_by(IdempotencyKey, bot_id: bot_id, key: key) do
      nil -> :miss
      record -> {:hit, record.response_code, record.response_body}
    end
  end

  def store(bot_id, key, response_code, response_body) do
    require Logger

    %IdempotencyKey{}
    |> IdempotencyKey.changeset(%{
      bot_id: bot_id,
      key: key,
      response_code: response_code,
      response_body: response_body
    })
    |> Repo.insert()
    |> case do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Idempotency store failed: #{inspect(changeset.errors)}")
        :ok
    end
  end

  @doc """
  Delete idempotency keys older than `@max_age_days` days.

  Returns the number of deleted rows.
  """
  def delete_expired do
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-@max_age_days, :day)

    {count, _} =
      from(k in IdempotencyKey, where: k.inserted_at < ^cutoff)
      |> Repo.delete_all()

    count
  end
end
