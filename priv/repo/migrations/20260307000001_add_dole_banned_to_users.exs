defmodule StackCoin.Repo.Migrations.AddDoleBannedToUsers do
  use Ecto.Migration

  def change do
    alter table(:user) do
      add(:dole_banned, :boolean, default: false, null: false)
    end
  end
end
