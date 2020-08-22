class StackCoin::Bot
  class Unban < Command
    def initialize(context : Context)
      @trigger = "unban"
      @aliases = ["pardon"]
      @usage = "<@user>"
      @desc = "Allows a banned account to use the bot again"
      super(context)
    end

    def invoke(message)
      return Result::Error.new(@client, message, "Command only for use by bots owner!") if message.author.id != @config.owner_id

      mentions = Discord::Mention.parse(message.content)
      return Result::Error.new(@client, message, "Too many/little mentions in your message; one is expected") if mentions.size != 1

      user_mention = mentions[0]
      return Result::Error.new(@client, message, "Mentioned a non-user entity in your message: #{user_mention}") if !user_mention.is_a? Discord::Mention::User
      user_id = user_mention.id.to_u64

      is_banned = @banned.is_banned(user_id)
      return Result::Error.new(@client, message, "User <@#{user_mention.id}> is not banned") if !is_banned

      @banned.unban(user_id)
      send_msg(message, "👌 User <@#{user_mention.id}> unbanned 👌")
    end
  end
end
