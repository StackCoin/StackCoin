defmodule StackCoin.Schema.InternalUser do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "internal_user" do
    field(:identifier, :string)

    belongs_to(:user, StackCoin.Schema.User, define_field: false)
    has_many(:pumps_to, StackCoin.Schema.Pump, foreign_key: :to_id)
  end

  def changeset(internal_user, attrs) do
    internal_user
    |> cast(attrs, [:id, :identifier])
    |> validate_required([:id, :identifier])
    |> unique_constraint(:identifier)
    |> foreign_key_constraint(:id, name: :internal_user_id_fkey)
  end
end
