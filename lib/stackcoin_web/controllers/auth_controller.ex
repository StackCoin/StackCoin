defmodule StackCoinWeb.AuthController do
  use StackCoinWeb, :controller

  alias StackCoin.Core.User

  @discord_authorize_url "https://discord.com/oauth2/authorize"
  @discord_token_url "https://discord.com/api/oauth2/token"
  @discord_user_url "https://discord.com/api/users/@me"

  @doc """
  Redirects to Discord's OAuth2 authorization page.
  """
  def discord(conn, _params) do
    state = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    params =
      URI.encode_query(%{
        client_id: discord_client_id(),
        redirect_uri: redirect_uri(conn),
        response_type: "code",
        scope: "identify",
        state: state
      })

    conn
    |> put_session(:oauth_state, state)
    |> redirect(external: "#{@discord_authorize_url}?#{params}")
  end

  @doc """
  Handles the OAuth2 callback from Discord.
  """
  def callback(conn, %{"code" => code, "state" => state}) do
    saved_state = get_session(conn, :oauth_state)

    cond do
      saved_state == nil or state != saved_state ->
        conn
        |> put_flash(:error, "Invalid OAuth state. Please try again.")
        |> redirect(to: ~p"/")

      true ->
        conn = delete_session(conn, :oauth_state)
        handle_code_exchange(conn, code)
    end
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "Discord authorization was cancelled.")
    |> redirect(to: ~p"/")
  end

  @doc """
  Logs out the current user.
  """
  def logout(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/")
  end

  defp handle_code_exchange(conn, code) do
    with {:ok, access_token} <- exchange_code(conn, code),
         {:ok, discord_user} <- fetch_discord_user(access_token),
         {:ok, user} <- User.get_user_by_discord_id(discord_user["id"]) do
      conn
      |> put_session(:user_id, user.id)
      |> redirect(to: ~p"/")
    else
      {:error, :user_not_found} ->
        conn
        |> put_flash(:error, "No StackCoin account found. Use /dole in Discord first.")
        |> redirect(to: ~p"/")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Login failed: #{inspect(reason)}")
        |> redirect(to: ~p"/")
    end
  end

  defp exchange_code(conn, code) do
    body = %{
      client_id: discord_client_id(),
      client_secret: discord_client_secret(),
      grant_type: "authorization_code",
      code: code,
      redirect_uri: redirect_uri(conn)
    }

    case Req.post(@discord_token_url, form: body) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} ->
        {:ok, token}

      {:ok, %{body: body}} ->
        {:error, body["error"] || "token exchange failed"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_discord_user(access_token) do
    case Req.get(@discord_user_url, headers: [{"authorization", "Bearer #{access_token}"}]) do
      {:ok, %{status: 200, body: %{"id" => _} = user}} ->
        {:ok, user}

      {:ok, %{body: body}} ->
        {:error, body["message"] || "failed to fetch user"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp discord_client_id do
    Application.get_env(:stackcoin, :discord_application_id) |> Integer.to_string()
  end

  defp discord_client_secret do
    Application.get_env(:stackcoin, :discord_client_secret)
  end

  defp redirect_uri(_conn) do
    StackCoinWeb.Endpoint.url() <> "/auth/discord/callback"
  end
end
