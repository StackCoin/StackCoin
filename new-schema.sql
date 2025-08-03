CREATE TABLE IF NOT EXISTS "user" (
    "id" INTEGER PRIMARY KEY AUTOINCREMENT,
    "username" TEXT NOT NULL,
    "balance" INTEGER NOT NULL CONSTRAINT balance_non_negative CHECK (balance >= 0),
    "last_given_dole" TEXT,
    "admin" INTEGER NOT NULL,
    "banned" INTEGER NOT NULL,
    "inserted_at" TEXT NOT NULL,
    "updated_at" TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS "internal_user" (
    "id" INTEGER PRIMARY KEY AUTOINCREMENT CONSTRAINT "internal_user_id_fkey" REFERENCES "user"("id") ON DELETE CASCADE,
    "identifier" TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS "discord_user" (
    "id" INTEGER PRIMARY KEY AUTOINCREMENT CONSTRAINT "discord_user_id_fkey" REFERENCES "user"("id") ON DELETE CASCADE,
    "snowflake" TEXT NOT NULL,
    "last_updated" TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS "discord_guild" (
    "id" INTEGER PRIMARY KEY AUTOINCREMENT,
    "snowflake" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "designated_channel_snowflake" TEXT NOT NULL,
    "last_updated" TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS "transaction" (
    "id" INTEGER PRIMARY KEY AUTOINCREMENT,
    "from_id" INTEGER NOT NULL CONSTRAINT "transaction_from_id_fkey" REFERENCES "user"("id") ON DELETE RESTRICT,
    "from_new_balance" INTEGER NOT NULL CONSTRAINT from_balance_non_negative CHECK (from_new_balance >= 0),
    "to_id" INTEGER NOT NULL CONSTRAINT "transaction_to_id_fkey" REFERENCES "user"("id") ON DELETE RESTRICT,
    "to_new_balance" INTEGER NOT NULL CONSTRAINT to_balance_non_negative CHECK (to_new_balance >= 0),
    "amount" INTEGER NOT NULL CONSTRAINT amount_positive CHECK (amount >= 1),
    "time" TEXT NOT NULL,
    "label" TEXT
);

CREATE TABLE IF NOT EXISTS "pump" (
    "id" INTEGER PRIMARY KEY AUTOINCREMENT,
    "signee_id" INTEGER NOT NULL CONSTRAINT "pump_signee_id_fkey" REFERENCES "user"("id") ON DELETE RESTRICT,
    "to_id" INTEGER NOT NULL CONSTRAINT "pump_to_id_fkey" REFERENCES "internal_user"("id") ON DELETE RESTRICT,
    "to_new_balance" INTEGER NOT NULL CONSTRAINT pump_balance_non_negative CHECK (to_new_balance >= 0),
    "amount" INTEGER NOT NULL CONSTRAINT pump_amount_positive CHECK (amount >= 1),
    "time" TEXT NOT NULL,
    "label" TEXT NOT NULL
);
