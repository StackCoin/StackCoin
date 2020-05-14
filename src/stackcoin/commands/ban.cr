class StackCoin::Bot
  class Ban < Command
    def initialize(context : Context)
      @trigger = "ban"
      @usage = "<@user>"
      @desc = "Bans an account from using the bot"
      super context
    end

    def invoke(message)
      return Result::Error.new(@client, message, "Command only for use by bots owner!") if message.author.id != @config.owner_id

      mentions = Discord::Mention.parse message.content
      return Result::Error.new(@client, message, "Too many/little mentions in your message; one is expected") if mentions.size != 1

      user_mention = mentions[0]
      return Result::Error.new(@client, message, "Mentioned a non-user entity in your message: #{user_mention}") if !user_mention.is_a? Discord::Mention::User

      @banned.ban user_mention.id.to_u64
      send_msg message, "❌ User <@#{user_mention.id}> banned ❌"
    end
  end
end
