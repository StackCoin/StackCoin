require "db"
require "sqlite3"

db = DB.open "sqlite3://./data/stackcoin.db"

puts "goodbye user"

db.exec "DELETE FROM balance WHERE user_id = ?", "123"
db.exec "DELETE FROM token WHERE user_id = ?", "123"

db.exec "INSERT INTO balance VALUES (?, ?)", "123", 100
db.exec "INSERT INTO token VALUES (?, ?)", "123", "abc"

puts "hello user"
