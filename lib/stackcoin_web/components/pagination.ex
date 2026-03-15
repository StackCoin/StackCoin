defmodule StackCoinWeb.Components.Pagination do
  @moduledoc """
  Shared pagination component for LiveView pages.
  """
  use Phoenix.Component

  @doc """
  Renders page number navigation.

  ## Assigns
    * `current_page` - the current page number (1-indexed)
    * `total_pages` - total number of pages
    * `patch_url` - function that takes a page number and returns a URL string
  """
  attr(:current_page, :integer, required: true)
  attr(:total_pages, :integer, required: true)
  attr(:patch_url, :any, required: true)

  def pagination(assigns) do
    assigns = assign(assigns, :pages, page_numbers(assigns.current_page, assigns.total_pages))

    ~H"""
    <nav :if={@total_pages > 1} class="flex items-center justify-center gap-1 mt-4">
      <.link
        :if={@current_page > 1}
        patch={@patch_url.(@current_page - 1)}
        class="px-2 py-1 text-sm text-gray-500"
      >
        &larr;
      </.link>
      <span :if={@current_page == 1} class="px-2 py-1 text-sm text-gray-300">
        &larr;
      </span>

      <%= for page <- @pages do %>
        <%= if page == :gap do %>
          <span class="px-2 py-1 text-sm text-gray-400">&hellip;</span>
        <% else %>
          <.link
            patch={@patch_url.(page)}
            class={[
              "px-2 py-1 text-sm",
              page == @current_page && "font-bold border-b-2 border-black",
              page != @current_page && "text-gray-500"
            ]}
          >
            {page}
          </.link>
        <% end %>
      <% end %>

      <.link
        :if={@current_page < @total_pages}
        patch={@patch_url.(@current_page + 1)}
        class="px-2 py-1 text-sm text-gray-500"
      >
        &rarr;
      </.link>
      <span :if={@current_page >= @total_pages} class="px-2 py-1 text-sm text-gray-300">
        &rarr;
      </span>
    </nav>
    """
  end

  # Build the list of page numbers to display, with :gap for ellipsis.
  # Always shows first, last, and a window around the current page.
  defp page_numbers(_current, total) when total <= 7 do
    Enum.to_list(1..total)
  end

  defp page_numbers(current, total) do
    # Always include: 1, current-1, current, current+1, total
    around =
      [1, current - 1, current, current + 1, total]
      |> Enum.filter(&(&1 >= 1 and &1 <= total))
      |> Enum.uniq()
      |> Enum.sort()

    # Insert :gap between non-consecutive numbers
    around
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce([hd(around)], fn [a, b], acc ->
      if b - a > 1 do
        acc ++ [:gap, b]
      else
        acc ++ [b]
      end
    end)
  end
end
