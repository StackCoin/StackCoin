class StackCoin::Bot
  class Circulation < Command
    def initialize(context : Context)
      super context
      @trigger = "circulation"
      @desc = "See the STK currently in circulation"
    end

    def invoke(message)
      send_emb message, "", Discord::Embed.new(
        title: "_Total StackCoin in Circulation:_",
        fields: [Discord::EmbedField.new(
          name: "#{@stats.circulation} STK",
          value: "Since #{EPOCH}",
        )]
      )
    end
  end
end
