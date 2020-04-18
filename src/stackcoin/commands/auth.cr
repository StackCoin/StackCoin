class StackCoin::Bot
  class Auth < Command
    def initialize(context : Context)
      @trigger = "auth"
      @usage = "<@bot_user> <@bot_users_owner>"
      @desc = "Grant bots accounts accessible via the api"
      super context
    end

    def invoke(message)
      return Result::Error.new(@client, message, "Command only for use by bots owner!") if message.author.id != @config.owner_id

      mentions = Discord::Mention.parse message.content
      return Result::Error.new(@client, message, "Too many/little mentions in your message; two is expected") if mentions.size != 2

      bot_user_mention = mentions[0]
      return Result::Error.new(@client, message, "Mentioned a non-user entity in your message: #{bot_user_mention}") if !bot_user_mention.is_a? Discord::Mention::User
      return Result::Error.new(@client, message, "StackCoin itself can't have an account with itself!") if bot_user_mention.id.to_u64 == @config.client_id
      bot_user = @cache.resolve_user bot_user_mention.id
      return Result::Error.new(@client, message, "Mentioned a non-bot user as the bot user in your message") if !bot_user.bot

      bot_users_owner_mention = mentions[1]
      return Result::Error.new(@client, message, "Mentioned a non-user entity in your message: #{bot_users_owner_mention}") if !bot_users_owner_mention.is_a? Discord::Mention::User
      bot_users_owner = @cache.resolve_user bot_users_owner_mention.id
      return Result::Error.new(@client, message, "Mentioned a bot user as the bot users owner in your message") if bot_users_owner.bot

      result = @auth.create_account_with_token bot_user.id.to_u64
      return Result::Error.new(@client, message, result.message) if !result.is_a? StackCoin::Auth::Result::AccountCreated

      begin
        private_channel = @client.create_dm bot_users_owner.id
        response = "Check your direct messages for a token from StackCoin :)"
        token_message = "Here's your token to access the StackCoin API from #{bot_user.username}: ```#{result.token}```"

        send_msg @client, private_channel.id, token_message
      rescue Discord::CodeException
        owner = @cache.resolve_user @config.owner_id
        response = "Direct message containing token failed to send (maybe you have DMs locked down?), ask #{owner.username} for your token instead :)"
        token_message = "#{bot_users_owner.username}##{bot_users_owner.discriminator}'s (#{bot_users_owner.id}) token to access the StackCoin API: ```#{result.token}```"

        owners_private_channel = @client.create_dm @config.owner_id
        send_msg @client, owners_private_channel.id, token_message
      end

      send_emb message, Discord::Embed.new(
        title: "_Token-authenticated bot user initialized_:",
        fields: [
          Discord::EmbedField.new(
            name: "#{message.author.username}",
            value: response
          ),
        ],
      )
    end
  end
end
