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

redis = Redis.new

get "/user/:id" do |env|
    id = env.params.url["id"]
    redis.get("#{id}:bal")
end

get "/user/" do |env|
    include_usernames = env.params.query.has_key? "usernames"

    bals = Hash(String, Hash(String, String)).new
    redis.keys("*:bal").each do |bal_key|
        if bal_key.is_a? String
            bal = redis.get bal_key
            if bal.is_a? String
                id = bal_key.split(":").first
                bals[id] = Hash(String, String).new
                if include_usernames
                    bals[id]["username"] = cache.resolve_user(id.to_u64).username
                end
                bals[id]["bal"] = bal
            end
        end
    end

    head = env.request.headers
    if head.has_key? "Accept"
        if head["Accept"].split(',').includes? "text/html"
            next render "src/views/user.ecr"
        end
    end

    bals.to_json
end

Kemal.run
