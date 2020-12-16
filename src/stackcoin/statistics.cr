require "uuid"

class StackCoin::Statistics < StackCoin::Bank
  class Result
    class Base
      def initialize(client, message, content)
        client.create_message(message.channel_id, content)
      end
    end

    class Error < Base
    end

    class Graph
      class Success
        getter file : File

        def initialize(@file)
        end
      end

      class Error
        getter message : String

        def initialize(@message)
        end
      end
    end

    class Report
      class Transaction
        getter from_id : UInt64
        getter from_bal : Int32
        getter to_id : UInt64
        getter to_bal : Int32
        getter amount : Int32
        getter time : Time

        def initialize(from_id, @from_bal, to_id, @to_bal, @amount, time)
          @from_id = from_id.to_u64
          @to_id = to_id.to_u64
          @time = Database.parse_time(time)
        end
      end

      getter date : Array(String)
      getter from_id : Array(UInt64)
      getter to_id : Array(UInt64)
      getter results : Array(Transaction)

      def initialize(@date, @from_id, @to_id, @results)
      end
    end
  end

  private def handle_balance_result_set(query, args)
    balances = {} of UInt64 => Int32
    @db.query(query, args: args) do |rs|
      rs.each do
        res = rs.read(String, Int32)
        balances[res[0].to_u64] = res[1]
      end
    end
    balances
  end

  def ledger
    @db.query_all(<<-SQL, as: {id : Int32, from_id : String, from_bal : Int32, to_id : String, to_bal : Int32, amount : Int32, time : Time})
      SELECT id, from_id, from_bal, to_id, to_bal, amount, time FROM ledger
    SQL
  end

  def all_balances
    @db.query_all(<<-SQL, as: {id: Int32, user_id: String, bal: Int32})
      SELECT id, user_id, bal FROM balance
    SQL
  end

  def all_benefits
    @db.query_all(<<-SQL, as: {id: Int32, user_id: String, user_bal: Int32, amount: Int32, time: Time})
      SELECT id, user_id, user_bal, amount, time FROM benefit
    SQL
  end

  def leaderboard(limit = 5)
    self.handle_balance_result_set(<<-SQL, [limit])
      SELECT user_id, bal FROM balance ORDER BY bal DESC LIMIT ?
      SQL
  end

  def graph(id)
    query = <<-SQL
      SELECT time, to_bal, amount FROM ledger
      WHERE to_id = ?
      UNION
      SELECT time, user_bal, amount FROM benefit
      WHERE user_id = ?
      ORDER BY time
      SQL

    id = id.to_s

    datapoints = 0
    reader, writer = IO.pipe
    @db.query query, args: [id, id] do |rs|
      rs.each do
        datapoints += 1
        time = rs.read(String)
        bal = rs.read(Int32)
        amount = rs.read(Int32)

        writer.puts("#{time},#{bal},#{amount}")
      end
    end
    writer.close

    if datapoints <= 1
      return Result::Graph::Error.new("Not enough datapoints!")
    end

    random = UUID.random
    image_filename = "/tmp/stackcoin/graph_#{id}_#{random}.png"
    title = "#{id} - #{Time.utc}"
    process = Process.new(
      "gnuplot",
      ["-e", "imagefilename='#{image_filename}';customtitle='#{title}'", "./src/gnuplot/graph.plt"],
      input: reader,
      output: Process::Redirect::Pipe,
      error: Process::Redirect::Pipe
    )

    stdout = process.output.gets_to_end
    stderr = process.error.gets_to_end

    if stderr != ""
      raise stderr
    end

    Result::Graph::Success.new(File.open(image_filename))
  end

  def richest
    richest = self.leaderboard(1)
    return nil if richest.size == 0
    richest[0]
  end

  def circulation
    @db.query_one(<<-SQL, as: Int64)
      SELECT SUM(bal) FROM balance
      SQL
  end

  macro optional_conditions(objs, type, condition, final = "AND")
    if {{objs}}.size != 0
      conditions << "("
      {{objs}}.each do |obj|
        if obj.is_a?({{type}})
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
    Log.debug { "Ledger arguments: #{dates}, #{from_ids}, #{to_ids}, #{limit}" }

    args = [] of DB::Any
    conditions = [] of String
    conditions << "WHERE"

    optional_conditions(dates, String, "date(time) = date(?)")

    if from_ids.size != 0 || to_ids.size != 0
      condition = "AND"
      if from_ids.size == 1 || to_ids.size == 1
        condition = "OR"
      end

      conditions << "("
      optional_conditions(from_ids, UInt64, "from_id = ?", condition)
      optional_conditions(to_ids, UInt64, "to_id = ?", condition)
      conditions.pop
      conditions << ")"
      conditions << "AND"
    end

    conditions.pop # either remove the WHERE or last AND

    conditions_flat = ""
    conditions.each do |condition|
      conditions_flat += " #{condition} "
    end

    ledger_query = <<-SQL
      SELECT from_id, from_bal, to_id, to_bal, amount, time
      FROM ledger #{conditions_flat} ORDER BY time DESC LIMIT ?
      SQL

    args << limit
    Log.debug { "Ledger query: #{ledger_query} - #{args}" }

    results = [] of Result::Report::Transaction

    @db.query(ledger_query, args: args) do |rs|
      rs.each do
        results << Result::Report::Transaction.new(*rs.read(String, Int32, String, Int32, Int32, String))
      end
    end

    Result::Report.new(dates, from_ids, to_ids, results)
  end
end
