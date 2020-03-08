require "dotenv"
require "./stackcoin/*"

begin
  Dotenv.load
end

config = StackCoin::Config.from_env

db = DB.open config.database_url
database = StackCoin::Database.new config, db

bank = StackCoin::Bank.new db
stats = StackCoin::Statistics.new db

bot = StackCoin::Bot.new config, bank, stats
api = StackCoin::Api.new config, bank, stats

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
