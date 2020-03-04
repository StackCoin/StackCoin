class StackCoin::Result
  class Base
    getter message : String

    def initialize(@message)
    end
  end

  class Success < Base
    def initialize(@message)
    end

    def initialize(db : DB::Transaction, @message)
      db.commit
    end
  end

  class Error < Base
    def initialize(@message)
    end

    def initialize(db : DB::Transaction, @message)
      db.rollback
    end
  end
end
