defmodule StackCoin.Bot.Discord.Components do
  @moduledoc """
  Discord Message Components constants, centralizing both v1 (from Nostrum) and
  v2 (manually defined) values in one place.

  ## Components v1 (via Nostrum)

  These delegate to `Nostrum.Constants.ComponentType` and
  `Nostrum.Constants.ButtonStyle` which already define them.

  ## Components v2 (manually defined)

  Discord's Components v2 types and the `IS_COMPONENTS_V2` message flag are not
  yet supported by Nostrum. These are defined manually here until upstream adds
  them:

  - https://github.com/Kraigie/nostrum/issues/712 (components v2 aren't decoded)
  - https://github.com/Kraigie/nostrum/issues/711 (message flags aren't decoded)
  """

  alias Nostrum.Constants.{ComponentType, ButtonStyle}

  # ---------------------------------------------------------------------------
  # Components v1 — delegated to Nostrum
  # ---------------------------------------------------------------------------

  defdelegate action_row, to: ComponentType
  defdelegate button, to: ComponentType
  defdelegate button_style_success, to: ButtonStyle, as: :success
  defdelegate button_style_danger, to: ButtonStyle, as: :danger

  # ---------------------------------------------------------------------------
  # Components v2 — manual definitions pending Nostrum support
  # https://github.com/Kraigie/nostrum/issues/712
  # https://github.com/Kraigie/nostrum/issues/711
  # ---------------------------------------------------------------------------

  @doc "Container component type (Components v2)"
  def container, do: 17

  @doc "Text display component type (Components v2)"
  def text_display, do: 10

  @doc "IS_COMPONENTS_V2 message flag (1 <<< 15)"
  def is_components_v2_flag, do: 32768
end
