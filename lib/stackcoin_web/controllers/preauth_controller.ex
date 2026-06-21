defmodule StackCoinWeb.PreauthController do
  use StackCoinWeb, :controller

  alias StackCoin.Core.Preauthorization
  alias StackCoinWeb.ApiHelpers

  def create(conn, %{"user_id" => user_id_str} = params) do
    current_bot = conn.assigns.current_bot
    max_amount = Map.get(params, "max_amount")
    window_hours = Map.get(params, "window_hours")

    with {:ok, user_id} <- ApiHelpers.parse_user_id(user_id_str),
         {:ok, max_amount} <- validate_positive_integer(max_amount, "max_amount"),
         {:ok, window_hours} <- validate_positive_integer(window_hours, "window_hours") do
      try do
        case Preauthorization.create_preauth(
               current_bot.user.id,
               user_id,
               max_amount,
               window_hours
             ) do
          {:ok, preauth} ->
            json(conn, format_preauth(preauth))

          {:error, :preauth_already_exists} ->
            conn
            |> put_status(:conflict)
            |> json(%{error: "A preauthorization already exists for this user"})

          {:error, :not_bot_user} ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: "Only bot users can create preauthorizations"})

          {:error, :user_not_found} ->
            conn |> put_status(:not_found) |> json(%{error: "User not found"})

          {:error, %Ecto.Changeset{}} ->
            conn
            |> put_status(:conflict)
            |> json(%{error: "A preauthorization already exists for this user"})

          {:error, reason} ->
            ApiHelpers.send_error_response(conn, reason)
        end
      rescue
        Ecto.ConstraintError ->
          conn
          |> put_status(:conflict)
          |> json(%{error: "A preauthorization already exists for this user"})
      end
    else
      {:error, msg} when is_binary(msg) ->
        conn |> put_status(:bad_request) |> json(%{error: msg})

      {:error, :invalid_user_id} ->
        conn |> put_status(:bad_request) |> json(%{error: "Invalid user ID"})
    end
  end

  def index(conn, params) do
    current_bot = conn.assigns.current_bot
    user_id = Map.get(params, "user_id")

    opts =
      if user_id do
        case ApiHelpers.parse_user_id(user_id) do
          {:ok, id} -> [user_id: id]
          _ -> []
        end
      else
        []
      end

    preauths = Preauthorization.list_preauths(current_bot.user.id, opts)
    json(conn, %{preauths: Enum.map(preauths, &format_preauth/1)})
  end

  def show(conn, %{"id" => id_str}) do
    case ApiHelpers.parse_user_id(id_str) do
      {:ok, id} ->
        case Preauthorization.get_preauth(id) do
          {:ok, preauth} ->
            {:ok, remaining} = Preauthorization.get_remaining_budget(preauth.id)
            json(conn, format_preauth(preauth) |> Map.put(:remaining_budget, remaining))

          {:error, :preauth_not_found} ->
            conn |> put_status(:not_found) |> json(%{error: "Preauthorization not found"})
        end

      {:error, :invalid_user_id} ->
        conn |> put_status(:bad_request) |> json(%{error: "Invalid preauthorization ID"})
    end
  end

  def revoke(conn, %{"id" => id_str}) do
    current_bot = conn.assigns.current_bot

    case ApiHelpers.parse_user_id(id_str) do
      {:ok, id} ->
        case Preauthorization.get_preauth(id) do
          {:ok, preauth} ->
            if preauth.bot_user_id != current_bot.user.id do
              conn |> put_status(:forbidden) |> json(%{error: "Not your preauthorization"})
            else
              case Preauthorization.revoke_preauth(id) do
                {:ok, revoked} ->
                  json(conn, format_preauth(revoked))

                {:error, :preauth_not_active} ->
                  conn
                  |> put_status(:bad_request)
                  |> json(%{error: "Preauthorization is not active"})

                {:error, reason} ->
                  ApiHelpers.send_error_response(conn, reason)
              end
            end

          {:error, :preauth_not_found} ->
            conn |> put_status(:not_found) |> json(%{error: "Preauthorization not found"})
        end

      {:error, :invalid_user_id} ->
        conn |> put_status(:bad_request) |> json(%{error: "Invalid preauthorization ID"})
    end
  end

  defp format_preauth(preauth) do
    %{
      id: preauth.id,
      bot_user_id: preauth.bot_user_id,
      user_id: preauth.user_id,
      max_amount: preauth.max_amount,
      window_hours: preauth.window_hours,
      status: preauth.status,
      requested_at: preauth.requested_at,
      approved_at: preauth.approved_at,
      revoked_at: preauth.revoked_at
    }
  end

  defp validate_positive_integer(nil, field), do: {:error, "#{field} is required"}

  defp validate_positive_integer(value, _field) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp validate_positive_integer(value, field) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, "#{field} must be a positive integer"}
    end
  end

  defp validate_positive_integer(_, field), do: {:error, "#{field} must be a positive integer"}
end
