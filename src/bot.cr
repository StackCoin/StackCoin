require "discordcr"
require "dotenv"
require "redis"
require "kemal"

require "./coin"

Dotenv.load
discord_token = ENV["STACKCOIN_DISCORD_TOKEN"]
discord_channel_id = ENV["STACKCOIN_DISCORD_CLIENT_ID"].to_u64

client = Discord::Client.new(token: "Bot #{discord_token}", client_id: discord_channel_id)
cache = Discord::Cache.new(client)
client.cache = cache

redis = Redis.new

client.on_message_create do |message|
  if message.author.bot
    next
  end

  msg = message.content

  begin
    if msg.starts_with? "s!"
      coin = Coin.new(client, cache, redis, message)

      if msg.starts_with? "s!send"
        coin.send
      end

      if msg.compare("s!dole") == 0
        coin.dole
      end

      if msg.compare("s!bal") == 0
        coin.bal
      end

      if msg.starts_with? "s!ping"
        client.create_message message.channel_id, "Pong!"
      end
    end
  rescue ex
    puts ex.inspect_with_backtrace
    client.create_message message.channel_id, "```#{ex.inspect_with_backtrace}```"
  end
end

get "/" do
  "Hello World!"
end

client.run
