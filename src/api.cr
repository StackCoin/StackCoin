require "discordcr"
require "dotenv"
require "redis"
require "kemal"

Dotenv.load
discord_token = ENV["STACKCOIN_DISCORD_TOKEN"]
discord_channel_id = ENV["STACKCOIN_DISCORD_CLIENT_ID"].to_u64

client = Discord::Client.new(token: "Bot #{discord_token}", client_id: discord_channel_id)
cache = Discord::Cache.new(client)
client.cache = cache

redis = Redis.new(host: ENV["STACKCOIN_REDIS_HOST"])

def should_return_html(env)
  headers = env.request.headers
  return headers["Accept"].split(',').includes? "text/html" if headers.has_key? "Accept"
  false
end

def should_include_usernames(env)
  env.params.query.has_key? "usernames"
end

get "/" do |env|
  next render "src/views/home.ecr" if should_return_html env
  Hash(String, String).new.to_json
end

get "/user/:id" do |env|
  include_usernames = should_include_usernames env
  id = env.params.url["id"]

  user = Hash(String, Union(String, Nil)).new
  user["id"] = id
  user["bal"] = redis.get("#{id}:bal")
  if include_usernames
    user["username"] = cache.resolve_user(id.to_u64).username
  end

  next render "src/views/user.ecr" if should_return_html env
  user.to_json
end

get "/user/" do |env|
  include_usernames = should_include_usernames env

  users = Hash(String, Hash(String, String)).new
  redis.keys("*:bal").each do |bal_key|
    if bal_key.is_a? String
      bal = redis.get bal_key
      if bal.is_a? String
        id = bal_key.split(":").first
        users[id] = Hash(String, String).new
        if include_usernames
          users[id]["username"] = cache.resolve_user(id.to_u64).username
        end
        users[id]["bal"] = bal
      end
    end
  end

  next render "src/views/users.ecr" if should_return_html env
  users.to_json
end

Kemal.run
