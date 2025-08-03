#!/usr/bin/env python3
"""
Migration script to transfer data from PostgreSQL to SQLite
Migrates from old schema (PostgreSQL) to new schema (SQLite)
"""

import psycopg2
import sqlite3
from datetime import datetime
import sys

# Database connections
PG_CONNECTION_STRING = "postgres://postgres:password@localhost:5432/stackcoin"
SQLITE_DB_PATH = "./data/stackcoin.db"


def connect_databases():
    """Connect to both PostgreSQL and SQLite databases"""
    try:
        pg_conn = psycopg2.connect(PG_CONNECTION_STRING)
        sqlite_conn = sqlite3.connect(SQLITE_DB_PATH)
        print("✓ Connected to both databases")
        return pg_conn, sqlite_conn
    except Exception as e:
        print(f"✗ Database connection failed: {e}")
        sys.exit(1)


def convert_timestamp(pg_timestamp):
    """Convert PostgreSQL timestamp to ISO string for SQLite"""
    if pg_timestamp is None:
        return None
    return pg_timestamp.isoformat()


def convert_boolean(pg_boolean):
    """Convert PostgreSQL boolean to SQLite integer"""
    return 1 if pg_boolean else 0


def migrate_users(pg_conn, sqlite_conn):
    """Migrate user table and return old_id -> new_id mapping"""
    print("Migrating users...")

    pg_cursor = pg_conn.cursor()
    sqlite_cursor = sqlite_conn.cursor()

    # Fetch all users from PostgreSQL
    pg_cursor.execute("""
        SELECT id, created_at, username, balance, last_given_dole, admin, banned
        FROM "user"
        ORDER BY id
    """)

    user_id_mapping = {}

    for (
        old_id,
        created_at,
        username,
        balance,
        last_given_dole,
        admin,
        banned,
    ) in pg_cursor.fetchall():
        # Convert data types
        inserted_at = convert_timestamp(created_at)
        updated_at = inserted_at  # Use created_at for both as requested
        last_given_dole_str = convert_timestamp(last_given_dole)
        admin_int = convert_boolean(admin)
        banned_int = convert_boolean(banned)

        # Insert into SQLite
        sqlite_cursor.execute(
            """
            INSERT INTO "user" (username, balance, last_given_dole, admin, banned, inserted_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
            (
                username,
                balance,
                last_given_dole_str,
                admin_int,
                banned_int,
                inserted_at,
                updated_at,
            ),
        )

        new_id = sqlite_cursor.lastrowid
        user_id_mapping[old_id] = new_id

    sqlite_conn.commit()
    print(f"✓ Migrated {len(user_id_mapping)} users")
    return user_id_mapping


def migrate_discord_guilds(pg_conn, sqlite_conn):
    """Migrate discord_guild table and return old_id -> new_id mapping"""
    print("Migrating discord guilds...")

    pg_cursor = pg_conn.cursor()
    sqlite_cursor = sqlite_conn.cursor()

    # Fetch all discord guilds from PostgreSQL
    pg_cursor.execute("""
        SELECT id, snowflake, name, designated_channel_snowflake, last_updated
        FROM "discord_guild"
        ORDER BY id
    """)

    guild_id_mapping = {}

    for (
        old_id,
        snowflake,
        name,
        designated_channel_snowflake,
        last_updated,
    ) in pg_cursor.fetchall():
        last_updated_str = convert_timestamp(last_updated)

        # Insert into SQLite
        sqlite_cursor.execute(
            """
            INSERT INTO "discord_guild" (snowflake, name, designated_channel_snowflake, last_updated)
            VALUES (?, ?, ?, ?)
        """,
            (snowflake, name, designated_channel_snowflake, last_updated_str),
        )

        new_id = sqlite_cursor.lastrowid
        guild_id_mapping[old_id] = new_id

    sqlite_conn.commit()
    print(f"✓ Migrated {len(guild_id_mapping)} discord guilds")
    return guild_id_mapping


def migrate_internal_users(pg_conn, sqlite_conn, user_id_mapping):
    """Migrate internal_user table using user ID mapping"""
    print("Migrating internal users...")

    pg_cursor = pg_conn.cursor()
    sqlite_cursor = sqlite_conn.cursor()

    # Fetch all internal users from PostgreSQL
    pg_cursor.execute("""
        SELECT id, identifier
        FROM "internal_user"
        ORDER BY id
    """)

    internal_user_id_mapping = {}

    for old_user_id, identifier in pg_cursor.fetchall():
        new_user_id = user_id_mapping[old_user_id]

        # Insert into SQLite
        sqlite_cursor.execute(
            """
            INSERT INTO "internal_user" (id, identifier)
            VALUES (?, ?)
        """,
            (new_user_id, identifier),
        )

        # Map old internal_user id to new user id for pump table
        internal_user_id_mapping[old_user_id] = new_user_id

    sqlite_conn.commit()
    print(f"✓ Migrated {len(internal_user_id_mapping)} internal users")
    return internal_user_id_mapping


def migrate_discord_users(pg_conn, sqlite_conn, user_id_mapping):
    """Migrate discord_user table using user ID mapping"""
    print("Migrating discord users...")

    pg_cursor = pg_conn.cursor()
    sqlite_cursor = sqlite_conn.cursor()

    # Fetch all discord users from PostgreSQL
    pg_cursor.execute("""
        SELECT id, snowflake, last_updated
        FROM "discord_user"
        ORDER BY id
    """)

    count = 0
    for old_user_id, snowflake, last_updated in pg_cursor.fetchall():
        new_user_id = user_id_mapping[old_user_id]
        last_updated_str = convert_timestamp(last_updated)

        # Insert into SQLite
        sqlite_cursor.execute(
            """
            INSERT INTO "discord_user" (id, snowflake, last_updated)
            VALUES (?, ?, ?)
        """,
            (new_user_id, snowflake, last_updated_str),
        )
        count += 1

    sqlite_conn.commit()
    print(f"✓ Migrated {count} discord users")


def migrate_transactions(pg_conn, sqlite_conn, user_id_mapping):
    """Migrate transaction table using user ID mapping"""
    print("Migrating transactions...")

    pg_cursor = pg_conn.cursor()
    sqlite_cursor = sqlite_conn.cursor()

    # Fetch all transactions from PostgreSQL
    pg_cursor.execute("""
        SELECT id, from_id, from_new_balance, to_id, to_new_balance, amount, time, label
        FROM "transaction"
        ORDER BY id
    """)

    count = 0
    for (
        old_id,
        from_id,
        from_new_balance,
        to_id,
        to_new_balance,
        amount,
        time,
        label,
    ) in pg_cursor.fetchall():
        new_from_id = user_id_mapping[from_id]
        new_to_id = user_id_mapping[to_id]
        time_str = convert_timestamp(time)

        # Insert into SQLite
        sqlite_cursor.execute(
            """
            INSERT INTO "transaction" (from_id, from_new_balance, to_id, to_new_balance, amount, time, label)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
            (
                new_from_id,
                from_new_balance,
                new_to_id,
                to_new_balance,
                amount,
                time_str,
                label,
            ),
        )
        count += 1

    sqlite_conn.commit()
    print(f"✓ Migrated {count} transactions")


def migrate_pumps(pg_conn, sqlite_conn, user_id_mapping, internal_user_id_mapping):
    """Migrate pump table using user and internal_user ID mappings"""
    print("Migrating pumps...")

    pg_cursor = pg_conn.cursor()
    sqlite_cursor = sqlite_conn.cursor()

    # Fetch all pumps from PostgreSQL
    pg_cursor.execute("""
        SELECT id, signee_id, to_id, to_new_balance, amount, time, label
        FROM "pump"
        ORDER BY id
    """)

    count = 0
    for (
        old_id,
        signee_id,
        to_id,
        to_new_balance,
        amount,
        time,
        label,
    ) in pg_cursor.fetchall():
        new_signee_id = user_id_mapping[signee_id]
        new_to_id = internal_user_id_mapping[to_id]
        time_str = convert_timestamp(time)

        # Insert into SQLite
        sqlite_cursor.execute(
            """
            INSERT INTO "pump" (signee_id, to_id, to_new_balance, amount, time, label)
            VALUES (?, ?, ?, ?, ?, ?)
        """,
            (new_signee_id, new_to_id, to_new_balance, amount, time_str, label),
        )
        count += 1

    sqlite_conn.commit()
    print(f"✓ Migrated {count} pumps")


def main():
    """Main migration function"""
    print("Starting migration from PostgreSQL to SQLite...")
    print(f"Source: {PG_CONNECTION_STRING}")
    print(f"Target: {SQLITE_DB_PATH}")
    print()

    # Connect to databases
    pg_conn, sqlite_conn = connect_databases()

    try:
        # Migrate in dependency order
        user_id_mapping = migrate_users(pg_conn, sqlite_conn)
        guild_id_mapping = migrate_discord_guilds(pg_conn, sqlite_conn)
        internal_user_id_mapping = migrate_internal_users(
            pg_conn, sqlite_conn, user_id_mapping
        )
        migrate_discord_users(pg_conn, sqlite_conn, user_id_mapping)
        migrate_transactions(pg_conn, sqlite_conn, user_id_mapping)
        migrate_pumps(pg_conn, sqlite_conn, user_id_mapping, internal_user_id_mapping)

        print()
        print("✓ Migration completed successfully!")
        print(f"  - {len(user_id_mapping)} users migrated")
        print(f"  - {len(guild_id_mapping)} discord guilds migrated")
        print(f"  - {len(internal_user_id_mapping)} internal users migrated")

    except Exception as e:
        print(f"✗ Migration failed: {e}")
        sqlite_conn.rollback()
        sys.exit(1)

    finally:
        pg_conn.close()
        sqlite_conn.close()
        print("Database connections closed.")


if __name__ == "__main__":
    main()
