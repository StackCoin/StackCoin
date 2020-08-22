class StackCoin::Bot
  class Bal < Command
    def initialize(context : Context)
      @trigger = "balance"
      @aliases = ["bal"]
      @usage = "?<@user>"
      @desc = "See the STK of yourself, or another user"
      super(context)
    end

    def invoke(message)
      mentions = Discord::Mention.parse(message.content)
      return Result::Error.new(@client, message, "Too many mentions in your message; max is one") if mentions.size > 1

      prefix = "You don't"
      user = message.author
      bal = nil

      if mentions.size > 0
        mention = mentions[0]
        if !mention.is_a?(Discord::Mention::User)
          return Result::Error.new(@client, message, "Mentioned entity isn't a user!")
        end
        user = @cache.resolve_user(mention.id)
        bal = @bank.balance(mention.id.to_u64)
        prefix = "User doesn't" if mention.id != message.author.id
      else
        bal = @bank.balance(message.author.id.to_u64)
      end

      if bal.is_a?(Nil)
        return Result::Error.new(@client, message, "#{prefix} have an account, run #{@config.prefix}open to create an account")
      end

      send_emb(message, Discord::Embed.new(
        title: "_Balance:_",
        fields: [Discord::EmbedField.new(
          name: "#{user.username}",
          value: "#{bal}",
        )]
      ))
    end
  end
end
