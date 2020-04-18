class StackCoin::Api
  class Auth < Route
    def initialize(context : Context)
      super context
      @routes = ["POST -> /auth"]
    end

    class AuthPostBody
      JSON.mapping(
        user_id: UInt64,
        token: String,
      )
    end

    def setup
      post "/auth" do |env|
        next unless env.request.body
        begin
          auth_post_body = AuthPostBody.from_json env.request.body.not_nil!
        rescue e : JSON::ParseException
          halt env, status_code: 403, response: json_error "Invalid JSON: #{e}"
        end

        auth_result = @auth.authenticate auth_post_body.user_id, auth_post_body.token
        env.response.status_code = 401 if !auth_result.is_a? StackCoin::Auth::Result::Authenticated

        auth_result.to_json
      end
    end
  end
end
