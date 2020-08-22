class Users < Application
  BASE = "/users/"
  base "/users/"

  PAGINATION_LIMIT = 15

  def formatted_user(user, balance)
    {
      id:       user.id,
      username: user.username,
      avatar:   user.avatar_url,
      balance: balance,
    }
  end

  def index
    limit = (params["limit"]? || PAGINATION_LIMIT).to_i32
    offset = (params["offset"]? || 0).to_i32

    head :bad_request if limit > PAGINATION_LIMIT || limit < 0 || offset < 0

    users = [] of NamedTuple(
      id: Discord::Snowflake,
      username: String,
      avatar: String,
      balance: Int32
    )

    stats.all_balances(limit, offset).each do |id, balance|
      user = bot.cache.resolve_user(id)
      users << formatted_user(user, balance)
    end

    respond_with do
      json(users)
      html template("users.ecr")
    end
  end

  def show
    id = params["id"].to_u64

    balance = bank.balance(id)

    head :not_found if balance.nil?

    user = formatted_user(bot.cache.resolve_user(id), balance)

    respond_with do
      json(user)
      html template("user.ecr")
    end
  end
end
