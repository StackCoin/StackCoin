require "sqlite3"
require "db"

module StackCoin
  class Database
    def self.init(db : DB::Database)
      db.exec "CREATE TABLE IF NOT EXISTS balance (
        id INTEGER PRIMARY KEY,
        bal interger
      )"
      db.exec "CREATE TABLE IF NOT EXISTS ledger (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        author_id string,
        author_bal interger,
        collector_id string,
        collector_bal interger,
        amount integer,
        time integer
      )"
      db.exec "CREATE TABLE IF NOT EXISTS benefits (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        needy_id string,
        needy_bal interger,
        amount integer,
        time integer
      )"
    end
  end
end
