require "../src/stackcoin/*"

# some text in code for _context_
# started this project in redis, since it was only two attributes; the bal and the last_given_dole
# sqlite came later, and then i realized it'd be so much better to just have a single source of truth,
# makes backups easy too!

#  redis:
#    github: stefanwille/crystal-redis
#    version: ~> 2.3.0

require "redis"

redis = Redis.new

db = DB.open("sqlite3://./data/stackcoin.db")
database = StackCoin::Database.new(StackCoin::Config.new, db)
stats = StackCoin::Statistics.new(db)

olddb = DB.open("sqlite3://./data/legacy.db")

redis.keys("*:bal").each do |bal_key|
  usr_id = bal_key.to_s.split(":")[0].to_u64
  bal = redis.get(bal_key)
  last_given_dole = redis.get "#{usr_id}:dole_date"
  if last_given_dole.is_a?(String)
    db.exec "INSERT INTO balance VALUES (?, ?)", usr_id.to_s, bal
    db.exec "INSERT INTO last_given_dole VALUES (?, ?)", usr_id.to_s, Time.unix last_given_dole.to_i64
  end
end

olddb.query("SELECT * FROM ledger") do |rs|
  rs.each do
    message_id = rs.read(Int64)
    guild_id = rs.read(Int64)
    author_id = rs.read(Int64)
    author_name = rs.read(String)
    author_bal = rs.read(Int64)
    collector_id = rs.read(Int64)
    collector_name = rs.read(String)
    collector_bal = rs.read(Int64)
    amount = rs.read(Int64)
    time = rs.read(String)

    args = [] of DB::Any
    args << author_id.to_s
    args << author_bal
    args << collector_id.to_s
    args << collector_bal
    args << amount
    args << time
    db.exec "INSERT INTO ledger(
      from_id, from_bal, to_id, to_bal, amount, time
    ) VALUES (
      ?, ?, ?, ?, ?, ?
    )", args: args
  end
end

olddb.query "SELECT * FROM benefits" do |rs|
  rs.each do
    message_id = rs.read(Int64)
    guild_id = rs.read(Int64)
    needy_id = rs.read(Int64)
    needy_name = rs.read(String)
    needy_bal = rs.read(Int64)
    amount = rs.read(Int64)
    time = rs.read(String)

    args = [] of DB::Any
    args << needy_id.to_s
    args << needy_bal
    args << amount
    args << time
    db.exec "INSERT INTO benefit(user_id, user_bal, amount, time) VALUES (?, ?, ?, ?)", args: args
  end
end
