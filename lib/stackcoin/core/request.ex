defmodule StackCoin.Core.Request do
  @moduledoc """
  Request management operations for payment requests.
  """

  alias StackCoin.Repo
  alias StackCoin.Schema
  alias StackCoin.Core.{User, Bank, Event, Preauthorization}
  import Ecto.Query

  @max_limit 100

  @doc """
  Creates a new payment request from requester to responder.
  """
  def create_request(requester_id, responder_id, amount, label \\ nil) do
    with {:ok, requester} <- User.get_user_by_id(requester_id),
         {:ok, responder} <- User.get_user_by_id(responder_id),
         {:ok, :not_banned} <- User.check_user_banned(requester),
         {:ok, :not_banned} <- User.check_recipient_banned(responder) do
      request_attrs = %{
        requester_id: requester_id,
        responder_id: responder_id,
        status: "pending",
        amount: amount,
        requested_at: NaiveDateTime.utc_now(),
        label: label
      }

      case Repo.insert(Schema.Request.changeset(%Schema.Request{}, request_attrs)) do
        {:ok, request} ->
          preloaded_request = Repo.preload(request, [:requester, :responder])
          StackCoin.Bot.Discord.Request.send_request_notification(preloaded_request)

          Phoenix.PubSub.broadcast(
            StackCoin.PubSub,
            "requests",
            {:request_created, preloaded_request}
          )

          for user_id <- [requester_id, responder_id] do
            Event.create_event("request.created", user_id, %{
              request_id: request.id,
              requester_id: requester_id,
              responder_id: responder_id,
              amount: amount,
              label: label
            })
          end

          {:ok, preloaded_request}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a request using preauth if available. If the bot has an active preauth
  with budget remaining, does an atomic transfer (request created as "accepted").
  Otherwise falls back to a normal pending request.
  """
  def create_request_with_preauth(requester_id, responder_id, amount, label \\ nil) do
    case Preauthorization.get_active_preauth(requester_id, responder_id) do
      {:ok, preauth} ->
        case Preauthorization.check_budget(preauth, amount) do
          {:ok, _remaining} ->
            execute_preauth_transfer(preauth, requester_id, responder_id, amount, label)

          {:error, :preauth_limit_exceeded} ->
            {:error, :preauth_limit_exceeded}
        end

      {:error, :no_active_preauth} ->
        create_request(requester_id, responder_id, amount, label)
    end
  end

  @doc """
  Gets a request by ID.
  """
  def get_request_by_id(request_id) do
    case Repo.get(Schema.Request, request_id) do
      nil -> {:error, :request_not_found}
      request -> {:ok, Repo.preload(request, [:requester, :responder, :transaction])}
    end
  end

  @doc """
  Gets requests for a user with optional filtering and pagination.
  Options:
  - :role - :requester (requests made by user) or :responder (requests to user)
  - :status - filter by status ("pending", "accepted", "denied", "expired")
  - :discord_id - filter by Discord ID of the other party (requester or responder)
  - :since - filter requests created after this NaiveDateTime
  - :limit - number of results to return (max #{@max_limit})
  - :offset - number of results to skip
  """
  def get_requests_for_user(user_id, opts \\ []) do
    role = Keyword.get(opts, :role)
    status = Keyword.get(opts, :status)
    discord_id = Keyword.get(opts, :discord_id)
    since = Keyword.get(opts, :since)
    limit = min(Keyword.get(opts, :limit, 20), @max_limit)
    offset = Keyword.get(opts, :offset, 0)

    base_query =
      case role do
        :requester ->
          from(r in Schema.Request,
            where: r.requester_id == ^user_id,
            preload: [:requester, :responder, :transaction],
            order_by: [desc: r.requested_at]
          )

        :responder ->
          from(r in Schema.Request,
            where: r.responder_id == ^user_id,
            preload: [:requester, :responder, :transaction],
            order_by: [desc: r.requested_at]
          )

        nil ->
          from(r in Schema.Request,
            where: r.requester_id == ^user_id or r.responder_id == ^user_id,
            preload: [:requester, :responder, :transaction],
            order_by: [desc: r.requested_at]
          )
      end

    filtered_query =
      case status do
        nil ->
          base_query

        status when status in ["pending", "accepted", "denied", "expired"] ->
          from(r in base_query, where: r.status == ^status)

        _ ->
          # Invalid status, return empty result
          from(r in base_query, where: false)
      end

    # Apply Discord ID filter if provided
    discord_filtered_query =
      case discord_id do
        nil ->
          filtered_query

        discord_id ->
          case role do
            :requester ->
              # Filter by responder's Discord ID
              from(r in filtered_query,
                join: du in Schema.DiscordUser,
                on: du.id == r.responder_id,
                where: du.snowflake == ^to_string(discord_id)
              )

            :responder ->
              # Filter by requester's Discord ID
              from(r in filtered_query,
                join: du in Schema.DiscordUser,
                on: du.id == r.requester_id,
                where: du.snowflake == ^to_string(discord_id)
              )

            nil ->
              # Filter by either requester's or responder's Discord ID
              from(r in filtered_query,
                join: requester_du in Schema.DiscordUser,
                on: requester_du.id == r.requester_id,
                join: responder_du in Schema.DiscordUser,
                on: responder_du.id == r.responder_id,
                where:
                  requester_du.snowflake == ^to_string(discord_id) or
                    responder_du.snowflake == ^to_string(discord_id)
              )
          end
      end

    # Apply time filter if provided
    time_filtered_query =
      case since do
        nil ->
          discord_filtered_query

        %NaiveDateTime{} = since_datetime ->
          from(r in discord_filtered_query, where: r.requested_at >= ^since_datetime)
      end

    # Get total count for pagination metadata
    total_count = Repo.aggregate(time_filtered_query, :count, :id)

    # Apply pagination
    paginated_query =
      from(r in time_filtered_query,
        limit: ^limit,
        offset: ^offset
      )

    requests = Repo.all(paginated_query)

    {:ok, %{requests: requests, total_count: total_count}}
  end

  @doc """
  Accepts a payment request and creates a transaction.
  """
  def accept_request(request_id, responder_id) do
    with {:ok, request} <- get_request_by_id(request_id),
         :ok <- validate_request_responder(request, responder_id),
         :ok <- validate_request_pending(request) do
      result =
        Repo.transaction(fn ->
          case Bank.transfer_between_users(
                 responder_id,
                 request.requester_id,
                 request.amount,
                 request.label
               ) do
            {:ok, transaction} ->
              # Atomic status check: only update if still "pending" to prevent
              # double-accept race conditions from double-charging the responder.
              {count, _} =
                from(r in Schema.Request,
                  where: r.id == ^request.id and r.status == "pending"
                )
                |> Repo.update_all(
                  set: [
                    status: "accepted",
                    resolved_at: NaiveDateTime.utc_now(),
                    transaction_id: transaction.id
                  ]
                )

              if count == 0 do
                # Another concurrent call already accepted/denied this request.
                # Rollback to undo the transfer.
                Repo.rollback(:request_not_pending)
              else
                updated_request =
                  Repo.get!(Schema.Request, request.id)
                  |> Repo.preload([:requester, :responder, :transaction], force: true)

                {updated_request, transaction}
              end

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)

      case result do
        {:ok, {updated_request, transaction}} ->
          Phoenix.PubSub.broadcast(
            StackCoin.PubSub,
            "requests",
            {:request_accepted, updated_request}
          )

          for user_id <- [request.requester_id, request.responder_id] do
            Event.create_event("request.accepted", user_id, %{
              request_id: request.id,
              status: "accepted",
              transaction_id: transaction.id,
              amount: request.amount
            })
          end

          {:ok, updated_request}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Denies a payment request.
  Can be called by either the responder or the requester (to cancel their own request).
  """
  def deny_request(request_id, user_id) do
    with {:ok, request} <- get_request_by_id(request_id),
         :ok <- validate_request_participant(request, user_id),
         :ok <- validate_request_pending(request) do
      # Atomic status check: only update if still "pending" to prevent
      # concurrent deny/accept race conditions.
      {count, _} =
        from(r in Schema.Request,
          where: r.id == ^request.id and r.status == "pending"
        )
        |> Repo.update_all(
          set: [
            status: "denied",
            resolved_at: NaiveDateTime.utc_now(),
            denied_by_id: user_id
          ]
        )

      if count == 0 do
        {:error, :request_not_pending}
      else
        preloaded =
          Repo.get!(Schema.Request, request.id)
          |> Repo.preload([:requester, :responder, :denied_by], force: true)

        Phoenix.PubSub.broadcast(
          StackCoin.PubSub,
          "requests",
          {:request_denied, preloaded}
        )

        for uid <- [request.requester_id, request.responder_id] do
          Event.create_event("request.denied", uid, %{
            denied_by_id: user_id,
            request_id: request.id,
            status: "denied"
          })
        end

        {:ok, preloaded}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Cancels all pending requests where the given user is either the requester or responder.
  Returns the number of requests cancelled.
  """
  def cancel_all_pending_requests(user_id) do
    now = NaiveDateTime.utc_now()

    {count, _} =
      from(r in Schema.Request,
        where: r.status == "pending",
        where: r.requester_id == ^user_id or r.responder_id == ^user_id
      )
      |> Repo.update_all(set: [status: "cancelled", resolved_at: now])

    {:ok, count}
  end

  defp execute_preauth_transfer(preauth, requester_id, responder_id, amount, label) do
    result =
      Repo.transaction(fn ->
        # Transfer funds: responder (user) pays requester (bot)
        case Bank.transfer_between_users(responder_id, requester_id, amount, label) do
          {:ok, transaction} ->
            request_attrs = %{
              requester_id: requester_id,
              responder_id: responder_id,
              status: "accepted",
              amount: amount,
              requested_at: NaiveDateTime.utc_now(),
              resolved_at: NaiveDateTime.utc_now(),
              transaction_id: transaction.id,
              preauthorization_id: preauth.id,
              label: label
            }

            case Repo.insert(Schema.Request.changeset(%Schema.Request{}, request_attrs)) do
              {:ok, request} ->
                {request, transaction}

              {:error, changeset} ->
                Repo.rollback(changeset)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {request, transaction}} ->
        preloaded =
          Repo.preload(request, [:requester, :responder, :transaction, :preauthorization])

        for user_id <- [requester_id, responder_id] do
          Event.create_event("request.accepted", user_id, %{
            request_id: request.id,
            status: "accepted",
            transaction_id: transaction.id,
            amount: amount
          })
        end

        {:ok, preloaded}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_request_responder(request, responder_id) do
    if request.responder_id == responder_id do
      :ok
    else
      {:error, :not_request_responder}
    end
  end

  defp validate_request_participant(request, user_id) do
    if request.responder_id == user_id or request.requester_id == user_id do
      :ok
    else
      {:error, :not_involved_in_request}
    end
  end

  defp validate_request_pending(request) do
    if request.status == "pending" do
      :ok
    else
      {:error, :request_not_pending}
    end
  end
end
