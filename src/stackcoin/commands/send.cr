class StackCoin::Bot
  class Send < Command
    def initialize(context : Context)
      @trigger = "send"
      @aliases = ["transfer"]
      @usage = "<@user> <#amount>"
      @desc = "Send your STK to others"
      super(context)
    end

    def invoke(message)
      mentions = Discord::Mention.parse(message.content)
      return Result::Error.new(@client, message, "Too many/little mentions in your message; max is one") if mentions.size != 1

      mention = mentions[0]
      return Result::Error.new(@client, message, "Mentioned a non-user entity in your message") if !mention.is_a? Discord::Mention::User

      msg_parts = Bot.cleaned_message_content(@config.prefix, message.content)
      return Result::Error.new(@client, message, "Too many arguments in message, found #{msg_parts.size}") if msg_parts.size > 3

      amount = msg_parts.last.to_i?
      return Result::Error.new(@client, message, "Invalid amount: #{msg_parts.last}") if amount.is_a? Nil

      result = @bank.transfer(message.author.id.to_u64, mention.id, amount)

      if result.is_a? Bank::Result::TransferSuccess
        to = @cache.resolve_user(mention.id)
        send_emb(message, Discord::Embed.new(
          title: "_Transaction complete_:",
          fields: [
            Discord::EmbedField.new(
              name: "#{message.author.username}",
              value: "New bal: #{result.from_bal}",
            ),
            Discord::EmbedField.new(
              name: "#{to.username}",
              value: "New bal: #{result.to_bal}",
            ),
          ],
        ))
      else
        Result::Error.new(@client, message, result.message)
      end
    end
  end
end
