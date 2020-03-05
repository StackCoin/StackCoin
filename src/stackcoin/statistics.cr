class StackCoin::Statistics < StackCoin::Bank
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
end
