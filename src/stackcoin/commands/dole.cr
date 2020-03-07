class StackCoin::Bot
  class Dole < Command
    def initialize(context : Context)
      super context
      @trigger = "dole"
      @desc = "Get some STK, daily"
    end

    def invoke(message)
      send_msg message, @bank.deposit_dole(message.author.id.to_u64).message
    end
  end
end
