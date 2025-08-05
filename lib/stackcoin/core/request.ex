defmodule StackCoin.Core.Request do
  @moduledoc """
  Request management operations for payment requests.
  """

  alias StackCoin.Repo
  alias StackCoin.Schema
  alias StackCoin.Core.{User, Bank}
  import Ecto.Query

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
        {:ok, request} -> {:ok, Repo.preload(request, [:requester, :responder])}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:error, reason} -> {:error, reason}
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
  Gets requests for a user with optional filtering.
  Options:
  - :role - :requester (requests made by user) or :responder (requests to user)
  - :status - filter by status ("pending", "accepted", "denied", "expired")
  """
  def get_requests_for_user(user_id, opts \\ []) do
    role = Keyword.get(opts, :role, :requester)
    status = Keyword.get(opts, :status)

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
      end

    query =
      case status do
        nil ->
          base_query

        status when status in ["pending", "accepted", "denied", "expired"] ->
          from(r in base_query, where: r.status == ^status)

        _ ->
          # Invalid status, return empty result
          from(r in base_query, where: false)
      end

    {:ok, Repo.all(query)}
  end

  @doc """
  Accepts a payment request and creates a transaction.
  """
  def accept_request(request_id, responder_id) do
    with {:ok, request} <- get_request_by_id(request_id),
         :ok <- validate_request_responder(request, responder_id),
         :ok <- validate_request_pending(request) do
      Repo.transaction(fn ->
        case Bank.transfer_between_users(
               responder_id,
               request.requester_id,
               request.amount,
               request.label
             ) do
          {:ok, transaction} ->
            request_attrs = %{
              status: "accepted",
              resolved_at: NaiveDateTime.utc_now(),
              transaction_id: transaction.id
            }

            case request
                 |> Schema.Request.changeset(request_attrs)
                 |> Repo.update() do
              {:ok, updated_request} ->
                Repo.preload(updated_request, [:requester, :responder, :transaction], force: true)

              {:error, changeset} ->
                Repo.rollback(changeset)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
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
      request_attrs = %{
        status: "denied",
        resolved_at: NaiveDateTime.utc_now(),
        denied_by_id: user_id
      }

      case request
           |> Schema.Request.changeset(request_attrs)
           |> Repo.update() do
        {:ok, updated_request} ->
          {:ok, Repo.preload(updated_request, [:requester, :responder, :denied_by])}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:error, reason} -> {:error, reason}
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
