class StackCoin::Api
  class Auth < Route
    def setup()
      post "/auth" do |env|
        halt env, status_code: 403 if self.should_return_html env

        expect_key "token"
        expect_key "id"

        token = env.params.json["token"].as String
        id = env.params.json["id"].as Float64

        @auth.authenticate token, id.to_u64

        # TODO auth
        Hash(String, String).new.to_json
      end
    end
  end
end
