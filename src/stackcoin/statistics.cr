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
      @to_id = to_id.to_u64
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

  def leaderboard(limit = 5)
    self.handle_balance_result_set "SELECT user_id, bal FROM balance ORDER BY bal DESC LIMIT ?", [limit]
  end

  def richest
    richest = self.leaderboard 1
    return nil if richest.size == 0
    richest[0]
  end

  macro optional_conditions(objs, type, condition, final = "AND")
    if {{objs}}.size != 0
      conditions << "("
      {{objs}}.each do |obj|
        if obj.is_a? {{type}}
          conditions << {{condition}}
          conditions << "OR"
          args << obj.to_s
        end
      end
      conditions.pop
      conditions << ")"
      conditions << {{final}}
    end
  end

  def ledger(dates, from_ids, to_ids, limit = 5)
    args = [] of DB::Any
    conditions = [] of String
    conditions << "WHERE"

    optional_conditions dates, String, "date(time) = date(?)"

    if from_ids.size != 0 || to_ids.size != 0
      conditions << "("
      optional_conditions from_ids, UInt64, "from_id = ?", "OR"
      optional_conditions to_ids, UInt64, "to_id = ?", "OR"
      conditions.pop
      conditions << ")"
      conditions << "AND"
    end

    conditions.pop # either remove the WHERE or last AND

    conditions_flat = ""
    conditions.each do |condition|
      conditions_flat += " #{condition} "
    end

    ledger_query = "SELECT from_id, from_bal, to_id, to_bal, amount, time
    FROM ledger #{conditions_flat} ORDER BY time DESC LIMIT ?"
    args << limit

    results = [] of LedgerResult
    @db.query ledger_query, args: args do |rs|
      rs.each do
        results << LedgerResult.new(*rs.read String, Int32, String, Int32, Int32, String)
      end
    end

    Result::LedgerResults.new dates, from_ids, to_ids, results
  end
end
