require "discordcr"
require "dotenv"
require "redis"
require "sqlite3"
require "db"

require "./coin"

Dotenv.load

prefix = ENV["STACKCOIN_PREFIX"]

discord_token = ENV["STACKCOIN_DISCORD_TOKEN"]
discord_channel_id = ENV["STACKCOIN_DISCORD_CLIENT_ID"].to_u64

discord_test_guild_snowflake = Discord::Snowflake.new ENV["STACKCOIN_TEST_GUILD_SNOWFLAKE"]

client = Discord::Client.new(token: "Bot #{discord_token}", client_id: discord_channel_id)
cache = Discord::Cache.new(client)
client.cache = cache

redis = Redis.new(host: ENV["STACKCOIN_REDIS_HOST"])

db = DB.open ENV["STACKCOIN_DATABASE_URL"]

init_sql = "CREATE TABLE IF NOT EXISTS ledger (
  guild_id string,
  author_id string,
  author_name string,
  author_bal interger,
  collector_id string,
  collector_name string,
  collector_bal interger,
  amount integer,
  time integer
)"
db.exec init_sql

coin = Coin.new(client, cache, redis, db, prefix)

client.on_message_create do |message|
  guild_id = message.guild_id
  if !guild_id.is_a? Nil && message.author.bot
    next if (guild_id <=> discord_test_guild_snowflake) != 0
  end

  msg = message.content

  begin
    next if !msg.starts_with? prefix

    coin.ledger message if msg.starts_with? "#{prefix}ledger"
    coin.send message if msg.starts_with? "#{prefix}send"
    coin.dole message if msg.compare("#{prefix}dole") == 0
    coin.bal message if msg.compare("#{prefix}bal") == 0

    client.create_message message.channel_id, "Pong!" if msg.starts_with? "#{prefix}ping"

    if msg.compare("#{prefix}key") == 0
      channel = cache.resolve_channel message.channel_id
      if channel.type.dm?
        client.create_message message.channel_id, "stub :)"
        next
      end
      client.create_message message.channel_id, "I only send out keys wihtin direct messages!"
      next
    end
  rescue ex
    puts ex.inspect_with_backtrace
    client.create_message message.channel_id, "```#{ex.inspect_with_backtrace}```"
  end
end

Signal::INT.trap do
  puts "stack coin killed .-."
  db.close
  exit
end

client.run
