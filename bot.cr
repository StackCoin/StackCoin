require "discordcr"
require "dotenv"
require "redis"
require "./coin"

Dotenv.load
discord_token = ENV["STACKCOIN_DISCORD_TOKEN"]
discord_channel_id = ENV["STACKCOIN_DISCORD_CLIENT_ID"].to_u64

client = Discord::Client.new(token: "Bot #{discord_token}", client_id: discord_channel_id)
redis = Redis.new

coin = Coin.new(client, redis)

def give_dole(client, redis, payload)
  client.create_message(payload.channel_id, "dole out")
end

client.on_message_create do |payload|
  msg = payload.content

  if msg.compare("s!dole") == 0
    coin.dole(payload)
  end

  if msg.compare("s!bal") == 0
    coin.bal(payload)
  end

  if msg.starts_with? "s!ping"
    client.create_message(payload.channel_id, "Pong!")
  end
end

client.run
