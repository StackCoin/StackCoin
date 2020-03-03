require "dotenv"
require "./stackcoin/*"

begin
  Dotenv.load
end

config = StackCoin::Config.from_env

db = DB.open config.database_url
StackCoin::Database.init(db)

bank = StackCoin::Bank.new(db)

spawn (
  StackCoin::Api.run!
)

spawn (
  StackCoin::Bot.new(config).run!
)

Signal::INT.trap do
  db.close
  puts "bye!"
  exit
end

loop do
  # #20 TODO check if UTC rolled over, message #stackexchange if so
  # #11 TODO backup entire sqlite databaes every day here
  sleep 60
end
