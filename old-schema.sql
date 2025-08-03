CREATE TABLE "user" (
  "id" serial PRIMARY KEY,
  "created_at" timestamp without time zone not null,
  "username" text not null,
  "balance" integer not null CHECK ("balance" >= 0),
  "last_given_dole" timestamp without time zone,
  "admin" boolean not null,
  "banned" boolean not null
);

CREATE TABLE "internal_user" (
  "id" integer PRIMARY KEY references "user"(id),
  "identifier" text not null UNIQUE
);

CREATE TABLE "discord_user" (
  "id" integer PRIMARY KEY references "user"(id),
  "snowflake" text not null UNIQUE,
  "last_updated" timestamp without time zone not null
);

CREATE TABLE "discord_guild" (
  "id" serial PRIMARY KEY,
  "snowflake" text not null UNIQUE,
  "name" text not null,
  "designated_channel_snowflake" text not null UNIQUE,
  "last_updated" timestamp without time zone not null
);

CREATE TABLE "transaction" (
  "id" serial PRIMARY KEY,
  "from_id" integer not null references "user"(id),
  "from_new_balance" integer not null CHECK ("from_new_balance" >= 0),
  "to_id" integer not null references "user"(id),
  "to_new_balance" integer not null CHECK ("to_new_balance" >= 0),
  "amount" integer not null CHECK ("amount" >= 1),
  "time" timestamp not null,
  "label" text,
  CHECK ("from_id" <> "to_id")
);

CREATE TABLE "pump" (
  "id" serial PRIMARY KEY,
  "signee_id" integer not null references "user"(id),
  "to_id" integer not null references "internal_user"(id),
  "to_new_balance" integer not null CHECK ("to_new_balance" >= 0),
  "amount" integer not null CHECK ("amount" >= 1),
  "time" timestamp not null,
  "label" text not null,
  CHECK ("signee_id" <> "to_id")
);
