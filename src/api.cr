require "dotenv"
require "redis"
require "kemal"

Dotenv.load

redis = Redis.new

get "/user/:id" do |env|
    id = env.params.url["id"]
    redis.get("#{id}:bal")
end

Kemal.run
