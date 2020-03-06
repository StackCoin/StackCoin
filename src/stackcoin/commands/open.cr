class StackCoin::Bot
  class Open < Command
    def initialize(@client, @cache, @bank, @stats, @config)
      @trigger = "open"
      @usage = ""
      @desc = "Open an account"
    end

    def invoke(message)
      send_msg message, @bank.open_account(message.author.id.to_u64).message
    end
  end
end

