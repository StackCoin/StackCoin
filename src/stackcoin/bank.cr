require "humanize_time"
require "./result.cr"

class StackCoin::Bank
  class Result < StackCoin::Result
    class TransferSuccess < Success
      property from_bal : Int32
      property to_bal : Int32

      def initialize(@message, @from_bal, @to_bal)
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

  @@instance : self? = nil

  def self.get
    @@instance.not_nil!
  end

  def initialize(@db : DB::Database, @banned : Banned)
    @@instance = self
  end

  def db
    @db
  end

  private def deposit(cnn : DB::Connection, user_id : UInt64, amount : Int32)
    cnn.exec(<<-SQL, amount, user_id.to_s)
      UPDATE balance SET bal = bal + ? WHERE user_id = ?
      SQL
  end

  private def withdraw(cnn : DB::Connection, user_id : UInt64, amount : Int32)
    cnn.exec(<<-SQL, amount, user_id.to_s)
      UPDATE balance SET bal = bal - ? WHERE user_id = ?
      SQL
  end

  def balance(cnn : DB::Connection, user_id : UInt64)
    cnn.query_one?(<<-SQL, user_id.to_s, as: Int32)
      SELECT bal FROM balance WHERE user_id = ?
      SQL
  end

  def balance(user_id : UInt64)
    @db.transaction do |tx|
      bal = self.balance(tx.connection, user_id)
      tx.commit
      return bal
    end
  end

  def deposit_dole(user_id : UInt64)
    bal = 0
    now = Time.utc

    @db.transaction do |tx|
      cnn = tx.connection

      expect_one = cnn.query_one(<<-SQL, user_id.to_s, as: Int)
        SELECT EXISTS(SELECT 1 FROM last_given_dole WHERE user_id = ?)
        SQL

      if expect_one == 0
        return Result::NoSuchAccount.new(tx, "No account to deposit dole to")
      end

      last_given = Database.parse_time(cnn.query_one <<-SQL, user_id.to_s, as: String)
        SELECT time FROM last_given_dole WHERE user_id = ?
        SQL

      if last_given.day == now.day
        time_till_rollver = HumanizeTime.distance_of_time_in_words(Time.utc.at_end_of_day - Time.utc, Time.utc)
        return Result::PrematureDole.new(tx, "Dole already received today, rollover in #{time_till_rollver}")
      end

      self.deposit(cnn, user_id, @@dole_amount)

      cnn.exec(<<-SQL, now, user_id.to_s)
        UPDATE last_given_dole SET time = ? WHERE user_id = ?
        SQL

      bal = self.balance(cnn, user_id)

      args = [] of DB::Any
      args << user_id.to_s
      args << bal
      args << @@dole_amount
      args << now

      cnn.exec(<<-SQL, args: args)
        INSERT INTO benefit(user_id, user_bal, amount, time) VALUES (?, ?, ?, ?)
        SQL
    end

    Result::Success.new("#{@@dole_amount} StackCoin given, your balance is now #{bal}")
  end

  def has_account(user_id : UInt64)
    0 < @db.query_one(<<-SQL, user_id.to_s, as: Int)
      SELECT EXISTS(SELECT 1 FROM balance WHERE user_id = ?)
      SQL
  end

  def open_account(user_id : UInt64)
    initial_bal = 0

    @db.transaction do |tx|
      cnn = tx.connection

      expect_zero = cnn.query_one(<<-SQL, user_id.to_s, as: Int)
        SELECT EXISTS(SELECT 1 FROM balance WHERE user_id = ?)
        SQL

      if expect_zero > 0
        return Result::PreexistingAccount.new(tx, "Account already open")
      end

      cnn.exec(<<-SQL, user_id.to_s, initial_bal)
        INSERT INTO balance VALUES (?, ?)
        SQL

      cnn.exec(<<-SQL, user_id.to_s, EPOCH)
        INSERT INTO last_given_dole VALUES (?, ?)
        SQL
    end

    Result::Success.new("Account created, initial balance is #{initial_bal}")
  end

  def transfer(from_id : UInt64, to_id : UInt64, amount : Int32)
    return Result::TransferSelf.new("Can't transfer money to self") if from_id == to_id
    return Result::InvalidAmount.new("Amount must be greater than zero") unless amount > 0
    return Result::InvalidAmount.new("Amount can't be greater than 100000") if amount > 100000

    if @banned.is_banned(from_id) || @banned.is_banned(to_id)
      return Result::BannedUser.new("Banned user mentioned in transaction")
    end

    from_balance, to_balance = 0, 0
    @db.transaction do |tx|
      cnn = tx.connection

      from_balance = self.balance(cnn, from_id)

      if !from_balance.is_a?(Int32)
        return Result::NoSuchAccount.new(tx, "You don't have an account yet")
      end

      to_balance = self.balance(cnn, to_id)
      if !to_balance.is_a?(Int32)
        return Result::NoSuchAccount.new(tx, "User doesn't have an account yet")
      end

      return Result::InsufficientFunds.new(tx, "Insufficient funds") if from_balance - amount < 0

      from_balance = from_balance - amount
      self.withdraw(cnn, from_id, amount)

      to_balance = to_balance + amount
      self.deposit(cnn, to_id, amount)

      args = [] of DB::Any
      args << from_id.to_s
      args << from_balance
      args << to_id.to_s
      args << to_balance
      args << amount
      args << Time.utc

      cnn.exec(<<-SQL, args: args)
        INSERT INTO ledger(
          from_id, from_bal, to_id, to_bal, amount, time
        ) VALUES (
          ?, ?, ?, ?, ?, ?
        )
        SQL
    end

    Result::TransferSuccess.new("Transfer sucessful", from_balance, to_balance)
  end
end
