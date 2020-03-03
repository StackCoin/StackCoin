module StackCoin
  class Bank
    def initialize(db : DB::Database)
      @db = db
    end

    def open_account(user_id : UInt64)
      begin
        return @db.exec "INSERT INTO balance VALUES (?, ?)", user_id.to_s, 0
      rescue e
        return Error.new("Account already open")
      end
    end

    def balance(user_id : UInt64)
      @db.query_one? "SELECT bal FROM balance WHERE id = ?", user_id.to_s, as: { Int32 }
    end
  end
end
