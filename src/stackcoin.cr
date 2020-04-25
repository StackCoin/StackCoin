require "log"

require "dotenv"

require "./stackcoin/*"

stdout_backend = Log::IOBackend.new
Log.builder.bind "*", :info, stdout_backend
Log.builder.bind "stackcoin", :debug, stdout_backend

StackCoin::Log.info { "Loading .env" }
begin
  Dotenv.load
end

StackCoin::Log.info { "Creaitng /tmp/stackcoin" }
Dir.mkdir_p "/tmp/stackcoin/"

config = StackCoin::Config.from_env

StackCoin::Log.info { "Opening database" }
db = DB.open config.database_url
database = StackCoin::Database.new config, db

notification = StackCoin::Notification.new db

StackCoin::Log.info { "Initializing modules" }
banned = StackCoin::Banned.new db

bank = StackCoin::Bank.new db, notification, banned
stats = StackCoin::Statistics.new db, notification, banned
auth = StackCoin::Auth.new db, bank, config.jwt_secret_key

notification.inject auth

bot = StackCoin::Bot.new config, bank, stats, auth, banned
api = StackCoin::Api.new config, bank, stats, auth

StackCoin::Log.info { "Spawning API" }
spawn (api.run!)

StackCoin::Log.info { "Spawning Notification" }
spawn (notification.run!)

StackCoin::Log.info { "Spawning Bot" }
spawn (bot.run!)

{Signal::INT, Signal::TERM}.each &.trap do
  StackCoin::Log.info { "Got signal to die" }
  db.close
  puts "bye"
  exit
end

loop do
  sleep 1.day
  database.backup
end
