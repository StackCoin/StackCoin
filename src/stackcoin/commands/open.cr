class StackCoin::Bot
  class Open < Command
    def initialize(context : Context)
      super context
      @trigger = "open"
      @desc = "Open an account"
    end

    def invoke(message)
      send_msg message, @bank.open_account(message.author.id.to_u64).message
    end
  end
end
