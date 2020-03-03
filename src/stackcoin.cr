require "dotenv"
require "./stackcoin/*"

Signal::INT.trap do
  # TODO cleanup any open db connections
  puts "bye!"
  exit
end

begin
  Dotenv.load
end

config = StackCoin::Config.from_env

api = StackCoin::Api.new
spawn (
  api.run!
)

bot = StackCoin::Bot.new(config)
spawn (
  bot.run!
)

loop do
  # #20 TODO check if UTC rolled over, message #stackexchange if so
  # #11 TODO backup entire sqlite databaes every day here
  sleep 60
end
