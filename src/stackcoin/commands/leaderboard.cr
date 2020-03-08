class StackCoin::Bot
  class Leaderboard < Command
    def initialize(context : Context)
      @trigger = "leaderboard"
      @desc = "See the highest-STK account"
      super context
    end

    def invoke(message)
      fields = [] of Discord::EmbedField

      @stats.leaderboard.each_with_index do |res, i|
        user = @cache.resolve_user res[0]
        fields << Discord::EmbedField.new(
          name: "\##{i + 1}: #{user.username}",
          value: "Balance: #{res[1]}"
        )
      end

      send_emb message, "", Discord::Embed.new title: "_Leaderboard:_", fields: fields
    end
  end
end
