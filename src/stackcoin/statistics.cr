class StackCoin::Statistics < StackCoin::Bank
  private def handle_balance_result_set(query, args)
    balances = [] of Tuple(Int64, Int32)
    @db.query query, args: args do |rs|
      rs.each do
        balances << rs.read Int64, Int32
      end
    end
    balances
  end

  def all_balances
    self.handle_balance_result_set "SELECT * FROM balance", nil
  end

  def leaderboard(limit)
    self.handle_balance_result_set "SELECT * FROM balance ORDER BY bal DESC LIMIT ?", [limit]
  end

  def richest
    richest = self.leaderboard 1
    return nil if richest.size == 0
    richest[0]
  end
end
