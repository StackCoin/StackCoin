require "humanize_time"
require "./result.cr"

class StackCoin::Bank
  class Result < StackCoin::Result
    class TransferSuccess < Success
      property amount : Int32
      property from_id : UInt64
      property from_bal : Int32
      property to_id : UInt64
      property to_bal : Int32

      def initialize(message, @amount, @from_id, @from_bal, @to_id, @to_bal)
        super message
      end
    end

    class PreexistingAccount < Error
    end

    class NoSuchAccount < Error
    end

    class PrematureDole < Error
    end

    class TransferSelf < Error
    end

    class InvalidAmount < Error
    end

    class InsufficientFunds < Error
    end

    class BannedUser < Error
    end
  end

  @@dole_amount : Int32 = 10

  def initialize(@db : DB::Database, @notification : StackCoin::Notification, @banned : Banned)
  end

  def db
    @db
  end

  private def deposit(cnn : DB::Connection, user_id : UInt64, amount : Int32)
    cnn.exec "UPDATE balance SET bal = bal + ? WHERE user_id = ?", amount, user_id.to_s
  end

  private def withdraw(cnn : DB::Connection, user_id : UInt64, amount : Int32)
    cnn.exec "UPDATE balance SET bal = bal - ? WHERE user_id = ?", amount, user_id.to_s
  end

  def balance(cnn : DB::Connection, user_id : UInt64)
    cnn.query_one? "SELECT bal FROM balance WHERE user_id = ?", user_id.to_s, as: Int32
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

      expect_one = cnn.query_one "SELECT EXISTS(SELECT 1 FROM last_given_dole WHERE user_id = ?)", user_id.to_s, as: Int
      return Result::NoSuchAccount.new tx, "No account to deposit dole to" if expect_one == 0

      last_given = Database.parse_time cnn.query_one "SELECT time FROM last_given_dole WHERE user_id = ?", user_id.to_s, as: String

      if last_given.day == now.day
        time_till_rollver = HumanizeTime.distance_of_time_in_words(Time.utc.at_end_of_day - Time.utc, Time.utc)
        return Result::PrematureDole.new tx, "Dole already received today, rollover in #{time_till_rollver}"
      end

      self.deposit cnn, user_id, @@dole_amount
      cnn.exec "UPDATE last_given_dole SET time = ? WHERE user_id = ?", now, user_id.to_s
      bal = self.balance cnn, user_id

      args = [] of DB::Any
      args << user_id.to_s
      args << bal
      args << @@dole_amount
      args << now

      cnn.exec "INSERT INTO benefit(user_id, user_bal, amount, time) VALUES (?, ?, ?, ?)", args: args
    end

    Result::Success.new "#{@@dole_amount} StackCoin given, your balance is now #{bal}"
  end

  def has_account(user_id : UInt64)
    0 < @db.query_one "SELECT EXISTS(SELECT 1 FROM balance WHERE user_id = ?)", user_id.to_s, as: Int
  end

  def open_account(user_id : UInt64)
    initial_bal = 0

    @db.transaction do |tx|
      cnn = tx.connection

      expect_zero = cnn.query_one "SELECT EXISTS(SELECT 1 FROM balance WHERE user_id = ?)", user_id.to_s, as: Int
      if expect_zero > 0
        return Result::PreexistingAccount.new tx, "Account already open"
      end

      cnn.exec "INSERT INTO balance VALUES (?, ?)", user_id.to_s, initial_bal
      cnn.exec "INSERT INTO last_given_dole VALUES (?, ?)", user_id.to_s, EPOCH
    end

    Result::Success.new "Account created, initial balance is #{initial_bal}"
  end

  def transfer(from_id : UInt64, to_id : UInt64, amount : Int32)
    return Result::TransferSelf.new "Can't transfer money to self" if from_id == to_id
    return Result::InvalidAmount.new "Amount must be greater than zero" unless amount > 0
    return Result::InvalidAmount.new "Amount can't be greater than 10000" if amount > 10000

    if @banned.is_banned(from_id) || @banned.is_banned(to_id)
      return Result::BannedUser.new "Banned user mentioned in transaction"
    end

    bot_user_id = nil
    from_balance, to_balance = 0, 0
    @db.transaction do |tx|
      cnn = tx.connection

      from_balance = self.balance(cnn, from_id)

      if !from_balance.is_a? Int32
        return Result::NoSuchAccount.new tx, "You don't have an account yet"
      end

      to_balance = self.balance(cnn, to_id)
      if !to_balance.is_a? Int32
        return Result::NoSuchAccount.new tx, "User doesn't have an account yet"
      end

      return Result::InsufficientFunds.new tx, "Insufficient funds" if from_balance - amount < 0

      from_balance = from_balance - amount
      self.withdraw cnn, from_id, amount

      to_balance = to_balance + amount
      self.deposit cnn, to_id, amount

      bot_user_id = cnn.query_one? "SELECT * FROM token WHERE user_id = ?", to_id.to_s, as: String

      args = [] of DB::Any
      args << from_id.to_s
      args << from_balance
      args << to_id.to_s
      args << to_balance
      args << amount
      args << Time.utc
      cnn.exec "INSERT INTO ledger(
        from_id, from_bal, to_id, to_bal, amount, time
      ) VALUES (
        ?, ?, ?, ?, ?, ?
      )", args: args
    end

    result = Result::TransferSuccess.new "Transfer sucessful", amount, from_id, from_balance, to_id, to_balance

    if bot_user_id.is_a? String
      @notification.send bot_user_id.to_u64, result
    end

    result
  end
end
