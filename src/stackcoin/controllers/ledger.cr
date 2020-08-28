class Ledger < Application
  getter pagination_base = "/ledger/"
  base "/ledger/"

  PAGINATION_LIMIT = 3

  def formatted_user(user, balance)
    {
      id:       user.id,
      username: user.username,
      avatar:   user.avatar_url,
      balance: balance,
    }
  end

  def formatted_transaction(transaction)
    from_user = bot.cache.resolve_user(transaction.from_id)
    to_user = bot.cache.resolve_user(transaction.to_id)

    {
      id: transaction.id,
      from: formatted_user(from_user, transaction.from_bal),
      to: formatted_user(to_user, transaction.to_bal),
      amount: transaction.amount,
      time: transaction.time,
    }
  end

  def process_report(report)
    transactions = [] of NamedTuple(
      id: Int64,
      from: NamedTuple(
        id: Discord::Snowflake,
        username: String,
        avatar: String,
        balance: Int32,
      ),
      to: NamedTuple(
        id: Discord::Snowflake,
        username: String,
        avatar: String,
        balance: Int32,
      ),
      amount: Int32,
      time: Time,
    )

    report.results.each do |transaction|
      transactions << formatted_transaction(transaction)
    end

    transactions
  end

  def index
    limit, offset = pagination(PAGINATION_LIMIT)
    head :bad_request if !valid_pagination(PAGINATION_LIMIT, limit, offset)

    to_ids = [] of UInt64
    from_ids = [] of UInt64

    user_id = params["user_id"]?

    if user_id
      user_id = user_id.to_u64
      to_ids << user_id
      from_ids << user_id
    end

    report = stats.ledger(limit: limit, offset: offset, to_ids: to_ids, from_ids: from_ids)

    # TODO same json for report and html
    respond_with do
      json(report)
      html do
        transactions = process_report(report)
        has_previous = offset != 0
        is_empty = transactions.size == 0
        has_next = !is_empty && transactions.size == limit
        template("ledger.ecr")
      end
    end
  end

  def show
    id = params["id"].to_u64

    transaction = formatted_transaction(stats.transaction(id))

    respond_with do
      json(transaction)
      html template("transaction.ecr")
    end
  end

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
