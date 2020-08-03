class Users < Application
  base "/users/"

  def index
    users = Hash(String, Hash(String, UInt64 | Int32)).new

    stats.all_balances.each do |id, balance|
      users[id.to_s] = Hash(String, UInt64 | Int32).new
      users[id.to_s]["id"] = id
      users[id.to_s]["bal"] = balance
    end

    respond_with do
      json(users)
      html template("users.ecr")
    end
  end

  def show
    id = params["id"].to_u64

    bal = bank.balance(id)

    head :not_found if bal.nil?

    user = Hash(String, String | Int32).new
    user["id"] = id.to_s
    user["bal"] = bal.to_s

    respond_with do
      json(user)
      html template("user.ecr")
    end
  end
end
