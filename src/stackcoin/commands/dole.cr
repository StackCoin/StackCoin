class StackCoin::Bot
  class Dole < Command
    def initialize(context : Context)
      @trigger = "dole"
      @desc = "Get some STK, daily"
      super context
    end

    def invoke(message)
      if message.author.id.to_u64 == 134337759446958081_u64
        send_msg message, "https://i.imgur.com/UbISwFX.jpg"
        sleep 5.seconds
      end

      send_msg message, @bank.deposit_dole(message.author.id.to_u64).message
    end
  end
end
