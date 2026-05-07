defmodule StackCoinWeb.AdminLive do
  use StackCoinWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(_params, _uri, socket) do
    current_user = socket.assigns[:current_user]

    cond do
      current_user == nil ->
        {:noreply,
         socket
         |> put_flash(:error, "You must be logged in.")
         |> push_navigate(to: ~p"/")}

      !socket.assigns[:is_admin] ->
        {:noreply,
         socket
         |> put_flash(:error, "Admin access required.")
         |> push_navigate(to: ~p"/")}

      true ->
        {:noreply, assign(socket, :page_title, "Admin — StackCoin")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto px-4 py-6 w-full">
      <.link navigate={~p"/"} class="text-sm text-gray-500 mb-6 inline-block">
        &larr; Back
      </.link>
      <h1 class="text-2xl font-bold mb-4">Admin</h1>
      <p class="text-gray-500">Coming soon.</p>
    </div>
    """
  end
end
