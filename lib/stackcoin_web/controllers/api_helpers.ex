defmodule StackCoinWeb.ApiHelpers do
  @moduledoc """
  Shared helper functions for API controllers.
  """

  import Plug.Conn
  import Phoenix.Controller

  @doc """
  Converts error atoms and changesets to HTTP status codes and error messages.
  """
  def error_to_status_and_message(error) do
    case error do
      :bot_not_found ->
        {:unauthorized, "bot_not_found"}

      :user_not_found ->
        {:not_found, "user_not_found"}

      :invalid_amount ->
        {:bad_request, "invalid_amount"}

      :self_transfer ->
        {:bad_request, "self_transfer"}

      :user_banned ->
        {:forbidden, "user_banned"}

      :recipient_banned ->
        {:forbidden, "recipient_banned"}

      :insufficient_balance ->
        {:unprocessable_entity, "insufficient_balance"}

      :request_not_found ->
        {:not_found, "request_not_found"}

      :not_request_responder ->
        {:forbidden, "not_request_responder"}

      :not_involved_in_request ->
        {:forbidden, "not_involved_in_request"}

      :request_not_pending ->
        {:bad_request, "request_not_pending"}

      :conflicting_filters ->
        {:bad_request, "conflicting_filters"}

      %Ecto.Changeset{} = changeset ->
        # Handle validation errors from changesets
        cond do
          Keyword.has_key?(changeset.errors, :amount) ->
            {:bad_request, "invalid_amount"}

          Keyword.has_key?(changeset.errors, :responder_id) ->
            {:bad_request, "self_transfer"}

          true ->
            {:bad_request, "validation_error"}
        end

      error_atom when is_atom(error_atom) ->
        {:internal_server_error, Atom.to_string(error_atom)}

      _ ->
        {:internal_server_error, "unknown_error"}
    end
  end

  @doc """
  Sends an error response with the appropriate status code and message.
  """
  def send_error_response(conn, error) do
    {status, message} = error_to_status_and_message(error)

    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  @doc """
  Parses a user ID string parameter and validates it's a valid integer.
  Returns {:ok, user_id} or {:error, :invalid_user_id}.
  """
  def parse_user_id(user_id_str) do
    case Integer.parse(user_id_str) do
      {user_id, ""} -> {:ok, user_id}
      _ -> {:error, :invalid_user_id}
    end
  end

  @doc """
  Parses pagination parameters from request params.
  Returns a map with :page and :limit keys.
  """
  def parse_pagination_params(params, default_limit \\ 20) do
    page =
      case Map.get(params, "page") do
        nil ->
          1

        page_str ->
          case Integer.parse(page_str) do
            {page_num, ""} when page_num > 0 -> page_num
            _ -> 1
          end
      end

    limit =
      case Map.get(params, "limit") do
        nil ->
          default_limit

        limit_str ->
          case Integer.parse(limit_str) do
            {limit_num, ""} when limit_num > 0 -> limit_num
            _ -> default_limit
          end
      end

    %{page: page, limit: limit, offset: (page - 1) * limit}
  end

  @doc """
  Validates that an amount parameter is a valid integer.
  Returns {:ok, amount} or {:error, :invalid_amount}.
  """
  def validate_amount(amount) when is_integer(amount), do: {:ok, amount}
  def validate_amount(_), do: {:error, :invalid_amount}
end
