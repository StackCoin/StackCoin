defmodule StackCoin.Core.Idempotency do
  alias StackCoin.Repo
  alias StackCoin.Schema.IdempotencyKey

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
end
