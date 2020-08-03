class Ledger < Application
  base "/ledger/"

  class LedgerPost
    include JSON::Serializable
    property to_id : UInt64
    property amount : Int32
  end

  def create
    ensure_json
    ledger_post = LedgerPost.from_json(request.body.not_nil!)

    access_token_valid = auth.validate_access_token(request.headers["X-Access-Token"])

    if !access_token_valid.is_a?(StackCoin::Auth::Result::ValidAccessToken)
      unauthorized
    end

    from_id = access_token_valid.user_id

    result = bank.transfer(from_id, ledger_post.to_id, ledger_post.amount)

    if !result.is_a?(StackCoin::Bank::Result::TransferSuccess)
      unprocessable_entity
    end

    respond_with do
      json(result)
    end
  end
end
