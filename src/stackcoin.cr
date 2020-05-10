require "log"

require "dotenv"

require "./stackcoin/*"

backend = Log::IOBackend.new
Log.builder.bind "*", :info, backend

begin
  Dotenv.load
end

Dir.mkdir_p "/tmp/stackcoin/"

config = StackCoin::Config.from_env

db = DB.open config.database_url
database = StackCoin::Database.new config, db

banned = StackCoin::Banned.new db

bank = StackCoin::Bank.new db, banned
stats = StackCoin::Statistics.new db, banned
auth = StackCoin::Auth.new db, bank, config.jwt_secret_key

bot = StackCoin::Bot.new config, bank, stats, auth, banned
api = StackCoin::Api.new config, bank, stats, auth

spawn (api.run!)
spawn (bot.run!)

Signal::INT.trap do
  db.close
  puts "bye!"
  exit
end

loop do
  sleep 1.day
  database.backup
end
