require "log"

require "json_mapping" # TODO remove once deps no longer have usages of JSON.mapping

require "dotenv"

require "./stackcoin/*"

StackCoin::Log.info { "Loading .env" }
begin
  Dotenv.load
end

StackCoin::Log.info { "Creating /tmp/stackcoin" }
Dir.mkdir_p("/tmp/stackcoin/")

config = StackCoin::Config.from_env

StackCoin::Log.info { "Opening database" }
db = DB.open(config.database_url)
database = StackCoin::Database.new(config, db)

StackCoin::Log.info { "Initializing modules" }
banned = StackCoin::Banned.new(db)

bank = StackCoin::Bank.new(db, banned)
stats = StackCoin::Statistics.new(db, banned)
auth = StackCoin::Auth.new(db, bank, config.jwt_secret_key)

bot = StackCoin::Bot.new(config, bank, stats, auth, banned)
api = StackCoin::Api.new

StackCoin::Log.info { "Spawning API" }
spawn (api.run!)

StackCoin::Log.info { "Spawning Bot" }
# spawn (bot.run!)

{Signal::INT, Signal::TERM}.each &.trap do
  StackCoin::Log.info { "Got signal to die" }
  db.close
  spawn (api.close)
  puts("bye!")
  exit
end

loop do
  sleep 1.day
  database.backup
end
