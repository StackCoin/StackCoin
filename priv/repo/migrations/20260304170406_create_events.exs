defmodule StackCoin.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events) do
      add(:type, :string, null: false)
      add(:user_id, references(:user, type: :integer), null: true)
      add(:data, :text, null: false)
      add(:inserted_at, :naive_datetime, null: false, default: fragment("CURRENT_TIMESTAMP"))
    end

    create(index(:events, [:user_id]))
    create(index(:events, [:user_id, :id]))
    create(index(:events, [:type]))
  end
end
