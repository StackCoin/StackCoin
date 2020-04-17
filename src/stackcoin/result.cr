class StackCoin::Result
  class Base
    JSON.mapping(
      message: String,
      error: String?,
      success: String?,
    )

    def initialize(@message)
    end

    def name
      self.class.name.split("::").last(1)[0]
    end
  end

  class Success < Base
    def initialize(@message)
      @success = name
    end

    def initialize(db : DB::Transaction, @message)
      initialize @message
      db.commit
    end
  end

  class Error < Base
    def initialize(@message)
      @error = name
    end

    def initialize(db : DB::Transaction, @message)
      initialize @message
      db.rollback
    end
  end
end
