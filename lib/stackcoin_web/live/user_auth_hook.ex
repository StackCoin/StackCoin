defmodule StackCoinWeb.Live.UserAuthHook do
  @moduledoc """
  LiveView on_mount hook that loads current_user from the session.
  """
  import Phoenix.Component, only: [assign: 3]

  alias StackCoin.Core.User

  def on_mount(:default, _params, session, socket) do
    user_id = session["user_id"]

    current_user =
      if user_id do
        case User.get_user_by_id(user_id) do
          {:ok, user} -> user
          _ -> nil
        end
      end

    {:cont, assign(socket, :current_user, current_user)}
  end
end
