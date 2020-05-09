require "sqlite3"
require "db"
require "file_utils"

class StackCoin::Database
  def initialize(@config : Config, @db : DB::Database)
    @db.exec "CREATE TABLE IF NOT EXISTS balance (
      user_id TEXT PRIMARY KEY,
      bal INTERGER
    )"

    @db.exec "CREATE TABLE IF NOT EXISTS banned (
      user_id TEXT PRIMARY KEY
    )"

    @db.exec "CREATE TABLE IF NOT EXISTS token (
      user_id TEXT PRIMARY KEY,
      token TEXT
    )"

    @db.exec "CREATE TABLE IF NOT EXISTS ledger (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      from_id TEXT,
      from_bal INTERGER,
      to_id TEXT,
      to_bal INTERGER,
      amount INTERGER,
      time INTERGER
    )"

    @db.exec "CREATE TABLE IF NOT EXISTS benefit (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id TEXT,
      user_bal INTERGER,
      amount INTERGER,
      time INTERGER
    )"

    @db.exec "CREATE TABLE IF NOT EXISTS last_given_dole (
      user_id TEXT PRIMARY KEY,
      time INTERGER
    )"
  end

  def backup
    db_file = @config.database_url.lchop "sqlite3://"
    backup_file = "#{db_file}.backup.#{Time.utc}.gz"
    puts "gzipping #{db_file} to #{backup_file}..."

    File.open(db_file, "r") do |database_file|
      File.open(backup_file, "w") do |backup_file|
        Gzip::Writer.open(backup_file) do |gzip|
          IO.copy(database_file, gzip)
        end
      end
    end

    puts "backup complete!"
  end

  def self.parse_time(time)
    Time.parse time, SQLite3::DATE_FORMAT, Time::Location::UTC
  end
end
