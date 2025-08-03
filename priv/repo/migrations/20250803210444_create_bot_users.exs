defmodule StackCoin.Repo.Migrations.CreateBotUsers do
  use Ecto.Migration

  def change do
    create table(:bot_user) do
      add(:token, :string, null: false)
      add(:user_id, references(:user, on_delete: :delete_all), null: false)
      add(:owner_id, references(:user, on_delete: :delete_all), null: false)
      add(:active, :boolean, default: true, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:bot_user, [:token]))
    create(unique_index(:bot_user, [:user_id]))
    create(index(:bot_user, [:owner_id]))
  end
end
