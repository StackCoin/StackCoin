require "discordcr"
require "./commands/base"
require "./commands/*"

class StackCoin::Bot
  class Result
    class Base
      def initialize(client, message, content)
        client.create_message message.channel_id, content
      end
    end

    class Error < Base
    end
  end

  class Context
    getter client : Discord::Client
    getter cache : Discord::Cache
    getter bank : Bank
    getter stats : Statistics
    getter config : Config

    def initialize(@client, @cache, @bank, @stats, @config)
    end
  end

  def initialize(config : Config, bank : Bank, stats : Statistics)
    @client = Discord::Client.new(token: config.token, client_id: config.client_id)
    @cache = Discord::Cache.new(@client)
    @client.cache = @cache
    @config = config
    @bank = bank
    @stats = stats

    context = Context.new(@client, @cache, bank, stats, config)

    Bal.new context
    Circulation.new context
    Send.new context
    Dole.new context
    Graph.new context
    Leaderboard.new context
    Ledger.new context
    Open.new context
    Send.new context

    Help.new context

    command_lookup = Command.lookup

    @client.on_message_create do |message|
      guild_id = message.guild_id
      if !guild_id.is_a? Nil && message.author.bot
        next if (guild_id <=> config.test_guild_snowflake) != 0
      end
      msg = message.content

      begin
        next if !msg.starts_with? config.prefix
        msg_parts = msg.split " "
        command_key = msg_parts.first.lchop config.prefix

        if command_lookup.has_key? command_key
          command_lookup[command_key].invoke message
        else
          Result::Error.new @client, message, "Unknown command: #{command_key}"
        end
      rescue ex
        puts ex.inspect_with_backtrace
        Result::Error.new @client, message, "```#{ex.inspect_with_backtrace}```"
      end
    end
  end

  def run!
    @client.run
  end
end
