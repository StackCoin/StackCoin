require "kemal"

class StackCoin::Api
  def should_return_html(env)
    headers = env.request.headers
    if headers.has_key? "Accept"
      return headers["Accept"].split(',').includes? "text/html"
    end
    false
  end

  def should_include_usernames(env)
    env.params.query.has_key? "usernames"
  end

  def initialize(config : Config, bank : Bank, stats : Statistics, bot : Bot)
    get "/" do |env|
      next render "src/views/home.ecr" if self.should_return_html env
      Hash(String, String).new.to_json
    end

    get "/user/:id" do |env|
      include_usernames = should_include_usernames env

      id = env.params.url["id"].to_u64?

      halt env, status_code: 403 if id.is_a? Nil

      user = Hash(String, Union(String, Int32)).new
      user["id"] = id.to_s

      bal = bank.balance id
      halt env, status_code: 404 if bal.is_a? Nil
      user["bal"] = 5

      user["username"] = bot.cache.resolve_user(id).username if include_usernames

      next render "src/views/user.ecr" if should_return_html env
      user.to_json
    end

    get "/user/" do |env|
      include_usernames = should_include_usernames env

      users = Hash(String, Hash(String,Union(String, Int32))).new

      stats.all_balances.each do |balance|
        id = balance[0].to_s
        users[id] = Hash(String, Union(String, Int32)).new
        users[id]["username"] = bot.cache.resolve_user(balance[0]).username if include_usernames
        users[id]["bal"] = balance[1]
      end

      next render "src/views/users.ecr" if should_return_html env
      users.to_json
    end
  end

  def run!
    Kemal.run
  end
end
