defmodule StackCoin.Repo.Migrations.CreateIdempotencyKeys do
  use Ecto.Migration

  def change do
    create table(:idempotency_keys) do
      add(:key, :string, null: false)
      add(:bot_id, references(:bot_user, column: :id, type: :integer), null: false)
      add(:response_code, :integer, null: false)
      add(:response_body, :text, null: false)
      add(:inserted_at, :naive_datetime, null: false, default: fragment("CURRENT_TIMESTAMP"))
    end

    create(unique_index(:idempotency_keys, [:bot_id, :key]))
  end
end
