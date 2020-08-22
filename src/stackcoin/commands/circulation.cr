class StackCoin::Bot
  class Circulation < Command
    def initialize(context : Context)
      @trigger = "circulation"
      @aliases = ["total"]
      @desc = "See the STK currently in circulation"
      super(context)
    end

    def invoke(message)
      send_emb(message, Discord::Embed.new(
        title: "_Total StackCoin in Circulation:_",
        fields: [Discord::EmbedField.new(
          name: "#{@stats.circulation} STK",
          value: "Since #{EPOCH}",
        )]
      ))
    end
  end
end
