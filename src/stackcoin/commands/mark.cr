class StackCoin::Bot
  class Mark < Command
    def initialize(context : Context)
      @trigger = "mark"
      @desc = "Marks an channel as the designated channel for messages to do with the bot"
      super(context)
    end

    def invoke(message)
      return Result::Error.new(@client, message, "Command only for use by bots owner!") if message.author.id != @config.owner_id

      guild_id = message.guild_id.not_nil!
      channel_id = message.channel_id

      @designated_channel.mark(guild_id, channel_id)

      send_msg(message, "Channel <##{channel_id}> marked as the designated channel in this guild")
    end
  end
end
