module StackCoin
  class Error
    getter message : String
    def initialize(@message)
    end

    def initialize(db : DB::Transaction, @message)
      db.rollback
    end
  end
end
