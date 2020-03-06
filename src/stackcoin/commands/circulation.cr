class StackCoin::Bot
  class Circulation < Command
    def initialize(@client, @cache, @bank, @stats, @config)
      @trigger = "circulation"
      @usage = "" # TODO make usage nillable?
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
