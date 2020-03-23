require "./result.cr"

class StackCoin::Auth
  class Result < StackCoin::Result
  end

  def initialize(db : DB::Database)
    @db = db
  end

  def authenticate(token : String, id : UInt64)
    # p token
    # p id
  end
end
