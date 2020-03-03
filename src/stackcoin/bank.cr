module StackCoin
  class Bank
    class Success
      getter message : String
      def initialize(db : DB::Transaction, @message)
        db.commit
      end
    end

    class TransferSuccess
      getter from_bal : Int32
      getter to_bal : Int32
      def initialize(db : DB::Transaction, @from_bal, @to_bal)
        db.commit
      end
    end

    @@initial_bal : Int32 = 20
    @@dole_amount : Int32 = 10

    def initialize(db : DB::Database)
      @db = db
    end

    def open_account(user_id : UInt64)
      @db.transaction do |tx|
        cnn = tx.connection
        expect_zero = cnn.query_one "SELECT EXISTS(SELECT 1 FROM balance WHERE id = ?)", user_id.to_s, as: Int

        if expect_zero > 0
          return Error.new(tx, "Account already open")
        end

        cnn.exec "INSERT INTO balance VALUES (?, ?)", user_id.to_s, @@initial_bal
        return Success.new(tx, "Account created, initial balance is #{@@initial_bal}")
      end
    end

    def balance(cnn : DB::Connection, user_id : UInt64)
      cnn.query_one? "SELECT bal FROM balance WHERE id = ?", user_id.to_s, as: { Int32 }
    end

    def balance(user_id : UInt64)
      @db.transaction do |tx|
        bal = self.balance tx.connection, user_id
        tx.commit
        return bal
      end
    end

    def transfer(from_id : UInt64, to_id : UInt64, amount : Int32)
      return Error.new("Amount can't be less than zero") if amount <= 0
      return Error.new("Amount can't be greater than 10000") if amount > 10000

      @db.transaction do |tx|
        cnn = tx.connection

        from_balance = self.balance(cnn, from_id)

        if !from_balance.is_a? Int32
          return Error.new(tx, "You don't have an account yet")
        end

        to_balance = self.balance(cnn, to_id)
        if !to_balance.is_a? Int32
          return Error.new(tx, "User doesn't have an account yet")
        end

        if from_balance - amount < 0
          return Error.new(tx, "Insufficient funds")
        end

        return TransferSuccess.new(tx, from_balance, to_balance)
      end
    end
  end
end
