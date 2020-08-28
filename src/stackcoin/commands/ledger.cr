class StackCoin::Bot
  class Ledger < Command
    def initialize(context : Context)
      @trigger = "ledger"
      @aliases = ["transactions"]
      @usage = "?<date> ?<@user-a> ?<@user-b>"
      @desc = "View/search previous transactions"
      super(context)
    end

    def invoke(message)
      dates = [] of String
      from_ids = [] of UInt64
      to_ids = [] of UInt64

      fields = [] of Discord::EmbedField
      condition_context = [] of String

      yyy_mm_dd_regex = /([12]\d{3}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01]))/
      matches = message.content.scan(yyy_mm_dd_regex)
      return Result::Error.new(@client, message, "Too many yyyy-mm-dd string in your message; max is one") if matches.size > 1
      if matches.size > 0
        date = matches[0][1]
        dates << date
        condition_context << "Occured on #{date}"
      end

      mentions = Discord::Mention.parse(message.content)
      return Result::Error.new(@client, message, "Too many mentions in your message; max is two") if mentions.size > 2
      mentions.each do |mentioned|
        if !mentioned.is_a? Discord::Mention::User
          return Result::Error.new(@client, message, "Mentioned a non-user entity in your message")
        else
          # TODO allow to specify from / to
          from_ids << mentioned.id
          to_ids << mentioned.id
          condition_context << "Mentions #{@cache.resolve_user(mentioned.id).username}"
        end
      end

      report = @stats.ledger(dates: dates, from_ids: from_ids, to_ids: to_ids)

      report.results.each_with_index do |result, i|
        begin
          from = @cache.resolve_user(result.from_id).username
        rescue Discord::CodeException
          from = "(?)"
        end

        begin
          to = @cache.resolve_user(result.to_id).username
        rescue Discord::CodeException
          to = "(?)"
        end

        fields << Discord::EmbedField.new(
          name: "#{i + 1} - #{result.time}",
          value: "#{from} (#{result.from_bal}) ⟶ #{to} (#{result.to_bal}) - #{result.amount} STK"
        )
      end

      condition_context << "Most recent" if condition_context.size == 0

      fields << Discord::EmbedField.new(
        name: "*crickets*",
        value: "Seems like no transactions were found in the ledger :("
      ) if fields.size == 0

      title = "_Searching ledger by_:"
      condition_context.each do |cond|
        title += "\n- #{cond}"
      end

      send_emb(message, Discord::Embed.new(title: title, fields: fields))
    end
  end
end
