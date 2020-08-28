class Users < Application
  getter pagination_base = "/users/"
  base "/users/"

  PAGINATION_LIMIT = 3

  def formatted_user(user, balance)
    {
      id:       user.id,
      username: user.username,
      avatar:   user.avatar_url,
      balance:  balance,
    }
  end

  def index
    limit, offset = pagination(PAGINATION_LIMIT)
    head :bad_request if !valid_pagination(PAGINATION_LIMIT, limit, offset)

    users = [] of NamedTuple(
      id: Discord::Snowflake,
      username: String,
      avatar: String,
      balance: Int32)

    stats.all_balances(limit, offset).each do |id, balance|
      user = bot.cache.resolve_user(id)
      users << formatted_user(user, balance)
    end

    respond_with do
      json(users)
      html do
        has_previous = offset != 0
        is_empty = users.size == 0
        has_next = !is_empty && users.size == limit
        template("users.ecr")
      end
    end
  end

  def show
    id = params["id"].to_u64

    balance = bank.balance(id)

    head :not_found if balance.nil?

    user = formatted_user(bot.cache.resolve_user(id), balance)

    limit, offset = pagination(PAGINATION_LIMIT)

    respond_with do
      json(user)
      html template("user.ecr")
    end
  end
end
