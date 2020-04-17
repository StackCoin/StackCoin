class StackCoin::Api
  class Ledger < Route
    def setup
      post "/ledger" do |env|
        expect_json
        expect_access_token
        expect_keys ["to_id", "amount"]

        to_id = env.params.json["to_id"]
        expect_value_to_be Int64, to_id
        to_id = to_id.as(Int64).to_u64

        amount = env.params.json["amount"]
        expect_value_to_be Int64, amount
        amount = amount.as(Int64).to_i32

        access_token_valid = @auth.validate_access_token env.request.headers["X-Access-Token"]
        if !access_token_valid.is_a? StackCoin::Auth::Result::ValidAccessToken
          halt env, status_code: 401, response: access_token_valid.to_json
        end
        from_id = access_token_valid.user_id

        result = @bank.transfer from_id, to_id, amount
        env.response.status_code = 403 if !result.is_a? Bank::Result::TransferSuccess

        result.to_json
      end
    end
  end
end
