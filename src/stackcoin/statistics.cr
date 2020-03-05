class StackCoin::Statistics < StackCoin::Bank
  class LedgerResult
    getter from_id : UInt64
    getter from_bal : Int32
    getter to_id : UInt64
    getter to_bal : Int32
    getter amount : Int32
    getter time : Time

    def initialize(from_id, @from_bal, to_id, @to_bal, @amount, time)
      @from_id = from_id.to_u64
      @to_id = from_id.to_u64
      @time = Database.parse_time time
    end
  end

  class Result < StackCoin::Result
    class LedgerResults
      getter date : Array(String)
      getter from_id : Array(UInt64)
      getter to_id : Array(UInt64)
      getter results : Array(LedgerResult)

      def initialize(@date, @from_id, @to_id, @results)
      end
    end
  end

  private def handle_balance_result_set(query, args)
    balances = [] of Tuple(UInt64, Int32)
    @db.query query, args: args do |rs|
      rs.each do
        res = rs.read String, Int32
        balances << Tuple.new(res[0].to_u64, res[1])
      end
    end
    balances
  end

  def all_balances
    self.handle_balance_result_set "SELECT user_id, bal FROM balance", nil
  end

  def leaderboard(limit)
    self.handle_balance_result_set "SELECT user_id, bal FROM balance ORDER BY bal DESC LIMIT ?", [limit]
  end

  def richest
    richest = self.leaderboard 1
    return nil if richest.size == 0
    richest[0]
  end

  macro optional_condition(obj, type, condition)
    if {{obj}}.is_a? {{type}}
      conditions << {{condition}}
      conditions << "AND"
      args << {{obj}}
    end
  end

  def ledger(dates : Array(String), from_ids, to_ids)
    args = [] of DB::Any
    conditions = [] of String
    conditions << "WHERE"

    dates.each do |date|
      optional_condition date, String, "date(time) = date(?)"
    end

    from_ids.each do |from_id|
      optional_condition from_id.to_s, String, "(from_id = ?)"
    end

    to_ids.each do |to_id|
      optional_condition to_id.to_s, String, "(to_id = ?)"
    end

    conditions.pop # either remove the WHERE or last AND

    conditions_flat = ""
    conditions.each do |condition|
      conditions_flat += " #{condition} "
    end

    ledger_query = "SELECT from_id, from_bal, to_id, to_bal, amount, time
    FROM ledger #{conditions_flat} ORDER BY time DESC LIMIT 5"

    results = [] of LedgerResult
    @db.query ledger_query, args: args do |rs|
      rs.each do
        results << LedgerResult.new(*rs.read String, Int32, String, Int32, Int32, String)
      end
    end

    Result::LedgerResults.new dates, from_ids, to_ids, results
  end
end
