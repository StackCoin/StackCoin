require "discordcr"
require "dotenv"
require "redis"

require "./coin"

Dotenv.load
discord_token = ENV["STACKCOIN_DISCORD_TOKEN"]
discord_channel_id = ENV["STACKCOIN_DISCORD_CLIENT_ID"].to_u64

client = Discord::Client.new(token: "Bot #{discord_token}", client_id: discord_channel_id)
cache = Discord::Cache.new(client)
client.cache = cache

redis = Redis.new(host: ENV["STACKCOIN_REDIS_HOST"])

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
        next
      end

      if msg.compare("s!dole") == 0
        coin.dole
        next
      end

      if msg.compare("s!bal") == 0
        coin.bal
        next
      end

      if msg.compare("s!key") == 0
        channel = cache.resolve_channel message.channel_id
        if channel.type.dm?
          client.create_message message.channel_id, "stub :)"
          next
        end
        client.create_message message.channel_id, "I only send out keys wihtin direct messages!"
        next
      end

      if msg.starts_with? "s!ping"
        client.create_message message.channel_id, "Pong!"
        next
      end
    end
  rescue ex
    puts ex.inspect_with_backtrace
    client.create_message message.channel_id, "```#{ex.inspect_with_backtrace}```"
  end
end

client.run
