defmodule StackCoinWeb.Plugs.UserAuth do
  @moduledoc """
  Plug that loads the current user from the session.
  Assigns `current_user` to the conn (nil if not logged in).
  """
  import Plug.Conn

  alias StackCoin.Core.User

  def init(opts), do: opts

  def call(conn, _opts) do
    user_id = get_session(conn, :user_id)

    current_user =
      if user_id do
        case User.get_user_by_id(user_id) do
          {:ok, user} -> user
          _ -> nil
        end
      end

    assign(conn, :current_user, current_user)
  end
end
