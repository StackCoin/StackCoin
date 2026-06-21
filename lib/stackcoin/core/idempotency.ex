defmodule StackCoin.Core.Idempotency do
  @moduledoc """
  Idempotency key management for bot API requests.

  Uses an atomic claim-then-execute pattern to prevent TOCTOU races:
  1. Atomically INSERT OR IGNORE a placeholder row (response_code=0)
  2. If we claimed it (row was inserted): execute the operation, UPDATE with real response
  3. If someone else claimed it: poll until the real response appears, then return it
  """

  import Ecto.Query

  alias StackCoin.Repo
  alias StackCoin.Schema.IdempotencyKey

  require Logger

  @max_age_days 7
  # Sentinel: response_code=0 means "claimed but operation still in progress".
  # Real HTTP status codes are always >= 200.
  @pending_code 0
  @poll_interval_ms 50
  @poll_timeout_ms 5_000

  @doc """
  Execute a function with idempotency protection.

  `fun` is a zero-arity function that returns `{status_code, response_body_map}`.
  If the key was already used, returns the cached response without calling `fun`.
  If two concurrent requests race on the same key, only one executes `fun`.

  Returns `{status_code, response_body_map}`.
  """
  def execute(bot_id, key, fun) do
    case claim_key(bot_id, key) do
      :claimed ->
        {status, response_body} = fun.()

        # Only cache successful responses. Error responses (4xx/5xx) may be
        # transient (e.g., preauth budget recovers, balance refilled).
        # The placeholder row (response_code=0) is treated as :miss by check/2
        # and cleaned up by delete_expired/0.
        if status >= 200 and status < 300 do
          encoded = Jason.encode!(response_body)
          finalize_key(bot_id, key, status, encoded)
        end

        {status, response_body}

      {:already_done, code, body} ->
        {code, Jason.decode!(body)}

      :contended ->
        case poll_for_response(bot_id, key) do
          {:ok, code, body} ->
            {code, Jason.decode!(body)}

          :timeout ->
            Logger.warning(
              "Idempotency poll timeout for bot_id=#{bot_id} key=#{key}, executing as fallback"
            )

            {status, response_body} = fun.()

            if status >= 200 and status < 300 do
              encoded = Jason.encode!(response_body)
              finalize_key(bot_id, key, status, encoded)
            end

            {status, response_body}
        end
    end
  end

  @doc """
  Check if an idempotency key exists and has a completed response.
  Returns {:hit, code, body} or :miss.
  """
  def check(bot_id, key) do
    case Repo.get_by(IdempotencyKey, bot_id: bot_id, key: key) do
      nil -> :miss
      %{response_code: code} when code == @pending_code -> :miss
      record -> {:hit, record.response_code, record.response_body}
    end
  end

  @doc """
  Directly store an idempotency key with a response. Used for test setup
  and backward compatibility. For production request handling, use `execute/3`.
  """
  def store(bot_id, key, response_code, response_body) do
    now =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.truncate(:second)
      |> NaiveDateTime.to_iso8601()

    Repo.query!(
      """
      INSERT OR REPLACE INTO idempotency_keys
        (bot_id, key, response_code, response_body, inserted_at)
      VALUES (?, ?, ?, ?, ?)
      """,
      [bot_id, key, response_code, response_body, now]
    )

    :ok
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

  # --- Private ---

  # Atomically try to claim an idempotency key.
  #
  # Uses INSERT OR IGNORE which is atomic in SQLite — if the unique index
  # on (bot_id, key) is violated, zero rows are inserted and no error is raised.
  # We check `num_rows` to know if we got it.
  #
  # Returns:
  #   :claimed           — we inserted the placeholder, we own this key
  #   {:already_done, code, body} — another request already completed
  #   :contended         — another request claimed it but is still executing
  defp claim_key(bot_id, key) do
    now =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.truncate(:second)
      |> NaiveDateTime.to_iso8601()

    result =
      Repo.query!(
        """
        INSERT OR IGNORE INTO idempotency_keys
          (bot_id, key, response_code, response_body, inserted_at)
        VALUES (?, ?, ?, ?, ?)
        """,
        [bot_id, key, @pending_code, "", now]
      )

    if result.num_rows == 1 do
      :claimed
    else
      # Key already exists — check if the other request has finished
      case Repo.get_by(IdempotencyKey, bot_id: bot_id, key: key) do
        %{response_code: code} when code == @pending_code ->
          :contended

        %{response_code: code, response_body: body} ->
          {:already_done, code, body}

        nil ->
          # Shouldn't happen (row existed for INSERT OR IGNORE to skip, but
          # now gone — possibly expired by cleanup). Treat as claimable.
          :claimed
      end
    end
  end

  defp finalize_key(bot_id, key, status_code, response_body) do
    Repo.query!(
      "UPDATE idempotency_keys SET response_code = ?, response_body = ? WHERE bot_id = ? AND key = ?",
      [status_code, response_body, bot_id, key]
    )
  rescue
    e ->
      Logger.warning("Idempotency finalize failed: #{inspect(e)}")
  end

  defp poll_for_response(bot_id, key, elapsed \\ 0)

  defp poll_for_response(_bot_id, _key, elapsed) when elapsed >= @poll_timeout_ms do
    :timeout
  end

  defp poll_for_response(bot_id, key, elapsed) do
    Process.sleep(@poll_interval_ms)

    case Repo.get_by(IdempotencyKey, bot_id: bot_id, key: key) do
      %{response_code: code, response_body: body} when code != @pending_code ->
        {:ok, code, body}

      _ ->
        poll_for_response(bot_id, key, elapsed + @poll_interval_ms)
    end
  end
end
