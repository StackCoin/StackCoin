require "sqlite3"
require "db"

class StackCoin::Database
  def self.init(db : DB::Database)
    db.exec "CREATE TABLE IF NOT EXISTS balance (
      user_id TEXT PRIMARY KEY,
      bal INTERGER
    )"
    db.exec "CREATE TABLE IF NOT EXISTS ledger (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      from_id TEXT,
      from_bal INTERGER,
      to_id TEXT,
      to_bal INTERGER,
      amount INTERGER,
      time INTERGER
    )"
    db.exec "CREATE TABLE IF NOT EXISTS benefit (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id TEXT,
      user_bal INTERGER,
      amount INTERGER,
      time INTERGER
    )"

    db.exec "CREATE TABLE IF NOT EXISTS last_given_dole (
      user_id TEXT PRIMARY KEY,
      time INTERGER
    )"
  end

  def self.parse_time(time)
    Time.parse time, SQLite3::DATE_FORMAT, Time::Location::UTC
  end
end
