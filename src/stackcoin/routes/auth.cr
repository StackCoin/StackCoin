class StackCoin::Api
  class Auth < Route
    def setup
      post "/auth" do |env|
        expect_json
        expect_keys ["token", "id"]

        token = env.params.json["token"]
        expect_value_to_be String, token
        token = token.as String

        id = env.params.json["id"]
        expect_value_to_be Int64, id
        id = id.as Int64

        auth_result = @auth.authenticate id.to_u64, token
        env.response.status_code = 401 if !auth_result.is_a? StackCoin::Auth::Result::Authenticated

        auth_result.to_json
      end
    end
  end
end
