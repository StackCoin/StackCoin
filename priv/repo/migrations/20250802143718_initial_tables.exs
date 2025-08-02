defmodule StackCoin.Repo.Migrations.InitialTables do
  use Ecto.Migration

  def change do
    create table(:user) do
      add(:username, :text, null: false)

      add(:balance, :integer,
        null: false,
        check: %{name: "balance_non_negative", expr: "balance >= 0"}
      )

      add(:last_given_dole, :naive_datetime)
      add(:admin, :boolean, null: false)
      add(:banned, :boolean, null: false)

      timestamps(inserted_at: :created_at, updated_at: false)
    end

    create table(:internal_user, primary_key: false) do
      add(:id, references(:user, on_delete: :delete_all), primary_key: true)
      add(:identifier, :text, null: false)
    end

    create(unique_index(:internal_user, [:identifier]))

    create table(:discord_user, primary_key: false) do
      add(:id, references(:user, on_delete: :delete_all), primary_key: true)
      add(:snowflake, :text, null: false)
      add(:last_updated, :naive_datetime, null: false)
    end

    create(unique_index(:discord_user, [:snowflake]))

    create table(:discord_guild) do
      add(:snowflake, :text, null: false)
      add(:name, :text, null: false)
      add(:designated_channel_snowflake, :text, null: false)
      add(:last_updated, :naive_datetime, null: false)
    end

    create(unique_index(:discord_guild, [:snowflake]))
    create(unique_index(:discord_guild, [:designated_channel_snowflake]))

    create table(:transaction) do
      add(:from_id, references(:user, on_delete: :restrict), null: false)

      add(:from_new_balance, :integer,
        null: false,
        check: %{name: "from_balance_non_negative", expr: "from_new_balance >= 0"}
      )

      add(:to_id, references(:user, on_delete: :restrict), null: false)

      add(:to_new_balance, :integer,
        null: false,
        check: %{name: "to_balance_non_negative", expr: "to_new_balance >= 0"}
      )

      add(:amount, :integer, null: false, check: %{name: "amount_positive", expr: "amount >= 1"})
      add(:time, :naive_datetime, null: false)
      add(:label, :text)
    end

    create table(:pump) do
      add(:signee_id, references(:user, on_delete: :restrict), null: false)
      add(:to_id, references(:internal_user, column: :id, on_delete: :restrict), null: false)

      add(:to_new_balance, :integer,
        null: false,
        check: %{name: "pump_balance_non_negative", expr: "to_new_balance >= 0"}
      )

      add(:amount, :integer,
        null: false,
        check: %{name: "pump_amount_positive", expr: "amount >= 1"}
      )

      add(:time, :naive_datetime, null: false)
      add(:label, :text, null: false)
    end

    execute(
      """
      INSERT INTO "user"
        (
          id,
          created_at,
          username,
          balance,
          last_given_dole,
          admin,
          banned
        )
      VALUES
        (
          1,
          datetime('now'),
          'StackCoin Reserve System',
          0,
          null,
          0,
          0
        );
      """,
      """
      DELETE FROM "user" WHERE id = 1;
      """
    )

    execute(
      """
      INSERT INTO "internal_user" (id, identifier) VALUES (1, 'StackCoin Reserve System');
      """,
      """
      DELETE FROM "internal_user" WHERE id = 1;
      """
    )
  end
end
