class StackCoin::Bot
  class Graph < Command
    def initialize(context : Context)
      @trigger = "graph"
      @aliases = ["chart"]
      @desc = "Graph different data points."
      super(context)
    end

    def invoke(message)
      mentions = Discord::Mention.parse(message.content)
      return Result::Error.new(@client, message, "Too many mentions in your message; max is one") if mentions.size > 1

      prefix = "You don't"
      id = message.author.id
      user = message.author

      if mentions.size > 0
        mention = mentions[0]
        if !mention.is_a? Discord::Mention::User
          return Result::Error.new(@client, message, "Mentioned entity isn't a user!")
        end
        id = mention.id
        user = @cache.resolve_user(mention.id)
        prefix = "User doesn't" if mention.id != message.author.id
      end

      id = id.to_u64
      if !@bank.has_account id
        return Result::Error.new(@client, message, "#{prefix} have an account to see a graph of!")
      end

      result = @stats.graph(id)
      if result.is_a? Statistics::Result::Graph::Success
        @client.upload_file(
          channel_id: message.channel_id,
          content: "#{user.username}'s STK balance over time",
          file: result.file
        )

        result.file.delete
      else
        client.create_message(message.channel_id, result.message)
      end
    end
  end
end
