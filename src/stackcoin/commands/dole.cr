class StackCoin::Bot
  class Dole < Command
    def initialize(context : Context)
      @trigger = "dole"
      @desc = "Get some STK, daily"
      super context
    end

    def invoke(message)
      send_msg message, @bank.deposit_dole(message.author.id.to_u64).message
    end
  end
end
