class StackCoin::Api
  class User < Route
    def setup
      get "/user/:id" do |env|
        id = env.params.url["id"].to_u64?

        halt env, status_code: 403 if id.is_a? Nil

        user = Hash(String, String | Int32).new
        user["id"] = id.to_s

        bal = @bank.balance id
        halt env, status_code: 404 if bal.is_a? Nil
        user["bal"] = 5

        next render "src/views/user.ecr" if should_return_html env
        user.to_json
      end

      get "/user/" do |env|
        users = Hash(String, Hash(String, Int32)).new

        @stats.all_balances.each do |id, balance|
          users[id.to_s] = Hash(String, Int32).new
          users[id.to_s]["bal"] = balance
        end

        next render "src/views/users.ecr" if should_return_html env
        users.to_json
      end
    end
  end
end
