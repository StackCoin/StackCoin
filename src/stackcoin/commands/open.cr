class StackCoin::Bot
  class Open < Command
    def initialize(context : Context)
      @trigger = "open"
      @aliases = ["create"]
      @desc = "Open an account"
      super(context)
    end

    def invoke(message)
      send_msg(message, @bank.open_account(message.author.id.to_u64).message)
    end
  end
end
