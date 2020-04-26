require "uuid"

class StackCoin::Result
  class Base
    include JSON::Serializable

    property message : String
    property error : String?
    property success : String?
    property timestamp : Time
    property uuid : String

    def initialize(@message)
      @timestamp = Time.utc
      @uuid = UUID.random.to_s
    end

    def name
      self.class.name.split("::").last(1)[0]
    end
  end

  class Success < Base
    def initialize(message)
      super message
      @success = name
    end

    def initialize(db : DB::Transaction, @message)
      initialize @message
      db.commit
    end
  end

  class Error < Base
    def initialize(message)
      super message
      @error = name
    end

    def initialize(db : DB::Transaction, @message)
      initialize @message
      db.rollback
    end
  end
end
