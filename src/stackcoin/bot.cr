require "discordcr"

module StackCoin
  class Bot
    class Error
      def initialize(client, message, content)
        client.create_message message.channel_id, content
      end
    end

    def initialize(config : Config, bank : Bank)
      @client = Discord::Client.new(token: config.token, client_id: config.client_id)
      @cache = Discord::Cache.new(@client)
      @client.cache = @cache
      @bank = bank
      @config = config

      @client.on_message_create do |message|
        guild_id = message.guild_id
        if !guild_id.is_a? Nil && message.author.bot
          next if (guild_id <=> config.test_guild_snowflake) != 0
        end
        msg = message.content

        begin
          next if !msg.starts_with? config.prefix

          self.bal message if msg.starts_with? "#{config.prefix}bal"
          self.open message if msg.starts_with? "#{config.prefix}open"
          self.dole message if msg.starts_with? "#{config.prefix}dole"
        rescue ex
          puts ex.inspect_with_backtrace
          @client.create_message message.channel_id, "```#{ex.inspect_with_backtrace}```"
        end
      end
    end

    def send_msg(message, content)
      @client.create_message message.channel_id, content
    end

    def send_emb(message, content, emb)
      emb.colour = 16773120
      emb.timestamp = Time.utc
      emb.footer = Discord::EmbedFooter.new(
        text: "StackCoin™",
        icon_url: "https://i.imgur.com/CsVxtvM.png"
      )
      @client.create_message message.channel_id, content, emb
    end

    def bal(message)
      mentions = Discord::Mention.parse message.content
      return Error.new(@client, message, "Too many mentions in your message; max is one") if mentions.size > 1

      prefix = "You don't"
      user = message.author
      bal = nil

      if mentions.size > 0
        mention = mentions[0]
        if !mention.is_a? Discord::Mention::User
          return Error.new(@client, message, "Mentioned entity isn't a user!")
        end

        user = @cache.resolve_user(mention.id)
        bal = @bank.balance mention.id.to_u64
        prefix = "User doesn't" if mention.id != message.author.id
      else
        bal = @bank.balance message.author.id.to_u64
      end

      if bal.is_a? Nil
        return Error.new(@client, message, "#{prefix} have an account, run #{@config.prefix}open to create an account")
      end

      send_emb message, "", Discord::Embed.new(
        title: "_Balance:_",
        fields: [Discord::EmbedField.new(
          name: "#{user.username}",
          value: "Bal: #{bal}",
        )]
      )
    end

    def open(message)
      send_msg message, @bank.open_account(message.author.id.to_u64).message
    end

    def dole(message)
      send_msg message, @bank.deposit_dole(message.author.id.to_u64).message
    end

    def run!
      @client.run
    end
  end
end
