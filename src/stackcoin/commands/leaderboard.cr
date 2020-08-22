class StackCoin::Bot
  class Leaderboard < Command
    def initialize(context : Context)
      @trigger = "leaderboard"
      @aliases = ["scoreboard"]
      @desc = "See the highest-STK account"
      super(context)
    end

    def invoke(message)
      msg_parts = Bot.cleaned_message_content(@config.prefix, message.content)
      return Result::Error.new(@client, message, "Too many arguments in message, found #{msg_parts.size}") if msg_parts.size > 2

      if msg_parts.size == 2
        page = msg_parts.last.to_i?
        return Result::Error.new(@client, message, "Invalid page: #{msg_parts.last}") if page.is_a? Nil
      else
        page = 1
      end

      fields = [] of Discord::EmbedField

      limit = 5
      offset = limit * (page - 1)

      @stats.all_balances(limit, offset).each_with_index do |res, i|
        user = @cache.resolve_user(res[0])
        fields << Discord::EmbedField.new(
          name: "\##{offset + i + 1}: #{user.username}",
          value: "Balance: #{res[1]}"
        )
      end

      send_emb(message, Discord::Embed.new(
        title: "_Leaderboard:_",
        fields: fields
      ))
    end
  end
end
