module StackCoin
  class Bank
    class Success
      getter message : String

      def initialize(@message)
      end

      def initialize(db : DB::Transaction, @message)
        db.commit
      end
    end

    class TransferSuccess
      getter from_bal : Int32
      getter to_bal : Int32

      def initialize(@from_bal, @to_bal)
      end
    end

    @@dole_amount : Int32 = 10

    def initialize(db : DB::Database)
      @db = db
    end

    private def deposit(cnn : DB::Connection, user_id : UInt64, amount : Int32)
      cnn.exec "UPDATE balance SET bal = bal + ? WHERE id = ?", amount, user_id.to_s
    end

    private def withdraw(cnn : DB::Connection, user_id : UInt64, amount : Int32)
      cnn.exec "UPDATE balance SET bal = bal - ? WHERE id = ?", amount, user_id.to_s
    end

    def balance(cnn : DB::Connection, user_id : UInt64)
      cnn.query_one? "SELECT bal FROM balance WHERE id = ?", user_id.to_s, as: {Int32}
    end

    def balance(user_id : UInt64)
      @db.transaction do |tx|
        bal = self.balance tx.connection, user_id
        tx.commit
        return bal
      end
    end

    def deposit_dole(user_id : UInt64)
      bal = 0
      now = Time.utc

      @db.transaction do |tx|
        cnn = tx.connection

        expect_one = cnn.query_one "SELECT EXISTS(SELECT 1 FROM last_given_dole WHERE id = ?)", user_id.to_s, as: Int
        return Error.new tx, "No account to deposit dole to" if expect_one == 0

        last_given = Database.parse_time cnn.query_one "SELECT time FROM last_given_dole WHERE id = ?", user_id.to_s, as: String
        return Error.new tx, "Dole already received today" if last_given.day == now.day

        self.deposit cnn, user_id, @@dole_amount
        cnn.exec "UPDATE last_given_dole SET time = ? WHERE id = ?", now, user_id.to_s

        bal = self.balance cnn, user_id
      end

      Success.new "#{@@dole_amount} StackCoin given, your balance is now #{bal}"
    end

    def open_account(user_id : UInt64)
      initial_bal = 0

      @db.transaction do |tx|
        cnn = tx.connection

        expect_zero = cnn.query_one "SELECT EXISTS(SELECT 1 FROM balance WHERE id = ?)", user_id.to_s, as: Int
        if expect_zero > 0
          return Error.new tx, "Account already open"
        end

        cnn.exec "INSERT INTO balance VALUES (?, ?)", user_id.to_s, initial_bal
        cnn.exec "INSERT INTO last_given_dole VALUES (?, ?)", user_id.to_s, EPOCH
      end

      Success.new "Account created, initial balance is #{initial_bal}"
    end

    def transfer(from_id : UInt64, to_id : UInt64, amount : Int32)
      return Error.new "Can't transfer money to self" if from_id == to_id
      return Error.new "Amount can't be less than zero" if amount <= 0
      return Error.new "Amount can't be greater than 10000" if amount > 10000

      from_balance, to_balance = 0, 0
      @db.transaction do |tx|
        cnn = tx.connection

        from_balance = self.balance(cnn, from_id)

        if !from_balance.is_a? Int32
          return Error.new tx, "You don't have an account yet"
        end

        to_balance = self.balance(cnn, to_id)
        if !to_balance.is_a? Int32
          return Error.new tx, "User doesn't have an account yet"
        end

        return Error.new tx, "Insufficient funds" if from_balance - amount < 0

        from_balance = from_balance - amount
        self.withdraw cnn, from_id, amount

        to_balance = to_balance + amount
        self.deposit cnn, to_id, amount

        args = [] of DB::Any
        args << from_id.to_s
        args << from_balance
        args << to_id.to_s
        args << to_balance
        args << amount
        args << Time.utc
        cnn.exec "INSERT INTO ledger(
          author_id, author_bal, collector_id, collector_bal, amount, time
        ) VALUES (
          ?, ?, ?, ?, ?, ?
        )", args: args
      end

      TransferSuccess.new from_balance, to_balance
    end
  end
end
