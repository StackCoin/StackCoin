require "sqlite3"
require "db"
require "file_utils"
require "compress/gzip"

class StackCoin::Database
  def initialize(@config : Config, @db : DB::Database)
    populate_tables
  end

  def populate_tables
    @db.exec(<<-SQL)
      CREATE TABLE IF NOT EXISTS balance (
        user_id TEXT PRIMARY KEY,
        bal INTERGER
      );

      CREATE TABLE IF NOT EXISTS banned (
        user_id TEXT PRIMARY KEY
      );

      CREATE TABLE IF NOT EXISTS token (
        user_id TEXT PRIMARY KEY,
        token TEXT
      )

      CREATE TABLE IF NOT EXISTS ledger (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        from_id TEXT,
        from_bal INTERGER,
        to_id TEXT,
        to_bal INTERGER,
        amount INTERGER,
        time INTERGER
      );

      CREATE TABLE IF NOT EXISTS benefit (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT,
        user_bal INTERGER,
        amount INTERGER,
        time INTERGER
      );

      CREATE TABLE IF NOT EXISTS last_given_dole (
        user_id TEXT PRIMARY KEY,
        time INTERGER
      );
      SQL
  end

  def backup
    db_file = @config.database_url.lchop("sqlite3://")
    backup_file = "#{db_file}.backup.#{Time.utc}.gz"
    Log.info { "gzipping #{db_file} to #{backup_file}..." }

    File.open(db_file, "r") do |database_file|
      File.open(backup_file, "w") do |backup_file|
        Compress::Gzip::Writer.open(backup_file) do |gzip|
          IO.copy(database_file, gzip)
        end
      end
    end

    Log.info { "backup complete!" }
  end

  def self.parse_time(time)
    Time.parse(time, SQLite3::DATE_FORMAT, Time::Location::UTC)
  end
end
