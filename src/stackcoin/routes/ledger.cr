class StackCoin::Api
  class Ledger < Route
    def initialize(context : Context)
      super(context)
      @routes = ["POST -> /ledger"]
      @requires_auth = ["POST -> /ledger"]
    end

    class LedgerPostBody
      include JSON::Serializable
      property to_id : UInt64
      property amount : Int32
    end

    def setup
      get "/ledger/" do |env|
        ledger = @stats.ledger
        next render("src/views/ledger.ecr") if should_return_html(env)
        ledger.to_json
      end

      post "/ledger" do |env|
        next unless env.request.body
        begin
          ledger_post_body = LedgerPostBody.from_json(env.request.body.not_nil!)
        rescue e : JSON::ParseException
          halt(env, status_code: 403, response: json_error "Invalid JSON: #{e}")
        end

        access_token_valid = @auth.validate_access_token(env.request.headers["X-Access-Token"])
        if !access_token_valid.is_a?(StackCoin::Auth::Result::ValidAccessToken)
          halt(env, status_code: 401, response: access_token_valid.to_json)
        end
        from_id = access_token_valid.user_id

        result = @bank.transfer(from_id, ledger_post_body.to_id, ledger_post_body.amount)
        env.response.status_code = 403 if !result.is_a?(Bank::Result::TransferSuccess)

        result.to_json
      end
    end
  end
end
