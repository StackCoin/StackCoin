class StackCoin::Api
  class User < Route
    def initialize(context : Context)
      super(context)
      @routes = ["GET -> /user/", "GET -> /user/:id"]
    end

    def setup
      get "/user/:id" do |env|
        id = env.params.url["id"].to_u64?
        halt env, status_code: 403 if id.is_a?(Nil)

        bal = @bank.balance(id)
        halt env, status_code: 404 if bal.is_a?(Nil)

        user = Hash(String, String | Int32).new
        user["id"] = id.to_s
        user["bal"] = bal.to_s

        next template("src/views/user.ecr") if should_return_html(env)
        user.to_json
      end

      get "/user/" do |env|
        users = Hash(String, Hash(String, UInt64 | Int32)).new
        @stats.all_balances.each do |id, balance|
          users[id.to_s] = Hash(String, UInt64 | Int32).new
          users[id.to_s]["id"] = id
          users[id.to_s]["bal"] = balance
        end

        next template("src/views/users.ecr") if should_return_html(env)
        users.to_json
      end
    end
  end
end
