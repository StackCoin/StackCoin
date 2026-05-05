defmodule StackCoin.Repo.Migrations.CreatePreauthorizations do
  use Ecto.Migration

  def change do
    create table(:preauthorization) do
      add(:bot_user_id, references(:user, on_delete: :delete_all), null: false)
      add(:user_id, references(:user, on_delete: :delete_all), null: false)
      add(:max_amount, :integer, null: false,
        check: %{name: "preauth_max_amount_positive", expr: "max_amount > 0"})
      add(:window_hours, :integer, null: false,
        check: %{name: "preauth_window_hours_positive", expr: "window_hours > 0"})
      add(:status, :string, null: false)
      add(:requested_at, :naive_datetime, null: false)
      add(:approved_at, :naive_datetime)
      add(:revoked_at, :naive_datetime)

      timestamps(type: :utc_datetime)
    end

    create(index(:preauthorization, [:bot_user_id]))
    create(index(:preauthorization, [:user_id]))
    create(index(:preauthorization, [:status]))

    # Only one active or pending preauth per bot+user pair
    create(
      unique_index(:preauthorization, [:bot_user_id, :user_id],
        where: "status IN ('pending', 'active')",
        name: :preauthorization_bot_user_active_unique
      )
    )

    # Add preauthorization_id to existing request table
    alter table(:request) do
      add(:preauthorization_id, references(:preauthorization, on_delete: :nilify_all))
    end

    create(index(:request, [:preauthorization_id]))
  end
end
