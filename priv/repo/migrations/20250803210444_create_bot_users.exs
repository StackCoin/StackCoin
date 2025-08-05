defmodule StackCoin.Repo.Migrations.CreateBotUsers do
  use Ecto.Migration

  def change do
    create table(:bot_user) do
      add(:name, :string, null: false)
      add(:token, :string, null: false)
      add(:user_id, references(:user, on_delete: :delete_all), null: false)
      add(:owner_id, references(:user, on_delete: :delete_all), null: false)
      add(:active, :boolean, default: true, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:bot_user, [:name]))
    create(unique_index(:bot_user, [:token]))
    create(unique_index(:bot_user, [:user_id]))
    create(index(:bot_user, [:owner_id]))

    create table(:request) do
      add(:requester_id, references(:user, on_delete: :delete_all), null: false)
      add(:responder_id, references(:user, on_delete: :delete_all), null: false)
      add(:status, :string, null: false)

      add(:amount, :integer,
        null: false,
        check: %{name: "amount_must_be_positive", expr: "amount > 0"}
      )

      add(:requested_at, :naive_datetime, null: false)
      add(:transaction_id, references(:transaction, on_delete: :nilify_all))
      add(:resolved_at, :naive_datetime)
      add(:denied_by_id, references(:user, on_delete: :nilify_all), null: true)
      add(:label, :string)

      timestamps(type: :utc_datetime)
    end

    create(index(:request, [:requester_id]))
    create(index(:request, [:responder_id]))
    create(index(:request, [:status]))
    create(index(:request, [:requested_at]))
    create(index(:request, [:denied_by_id]))
  end
end
