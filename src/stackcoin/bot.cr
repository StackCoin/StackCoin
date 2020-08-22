require "levenshtein"
require "discordcr"
require "./commands/base"
require "./commands/*"

class StackCoin::Bot
  class Result
    class Base
      def initialize(client, message, content)
        client.create_message(message.channel_id, content)
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
    getter auth : StackCoin::Auth
    getter banned : StackCoin::Banned
    getter config : Config

    def initialize(@client, @cache, @bank, @stats, @auth, @banned, @config)
    end
  end

  def self.cleaned_message_content(prefix, message_content)
    cleaned = message_content.strip.split(' ').select { |i| i != "" }

    cleaned[0] = cleaned[0].downcase.lchop(prefix)

    if cleaned[0] == "" && cleaned.size >= 2
      cleaned.shift
      cleaned[0] = cleaned[0].downcase.lchop(prefix)
    end

    cleaned
  end

  @@instance : self? = nil

  def self.get
    @@instance.not_nil!
  end

  def cache
    @cache
  end

  def initialize(config : Config, bank : Bank, stats : Statistics, auth : StackCoin::Auth, banned : Banned)
    @client = Discord::Client.new(token: config.token, client_id: config.client_id)
    @cache = Discord::Cache.new(@client)
    @client.cache = @cache
    @config = config
    @bank = bank
    @auth = auth
    @stats = stats

    @@instance = self

    context = Context.new(@client, @cache, bank, stats, auth, banned, config)

    Log.info { "Initializing commands" }
    Auth.new(context)
    Bal.new(context)
    Ban.new(context)
    Circulation.new(context)
    Send.new(context)
    Dole.new(context)
    Graph.new(context)
    Leaderboard.new(context)
    Ledger.new(context)
    Open.new(context)
    Send.new(context)
    Unban.new(context)

    Help.new(context)

    command_lookup = Command.lookup

    Log.info { "Creating listener for discord messages" }
    @client.on_message_create do |message|
      guild_id = message.guild_id
      if !guild_id.is_a?(Nil) && message.author.bot
        next if (guild_id <=> config.test_guild_snowflake) != 0
      end
      msg = message.content

      begin
        next if !msg.downcase.starts_with?(config.prefix)

        if banned.is_banned(message.author.id.to_u64)
          next
        end

        @client.trigger_typing_indicator(message.channel_id)

        msg_parts = Bot.cleaned_message_content(config.prefix, message.content)
        command_key = msg_parts.first

        if command_key == ""
          command_lookup["help"].invoke(message)
          next
        end

        if command_lookup.has_key?(command_key)
          command_lookup[command_key].invoke(message)
        else
          postfix = ""
          potential = Levenshtein.find(command_key, command_lookup.keys)
          postfix = ", did you mean #{potential}?" if potential

          Result::Error.new(@client, message, "Unknown command: #{command_key}#{postfix}")
        end
      rescue ex
        Log.error { "Exception while invoking discord command: #{ex.inspect_with_backtrace}" }
        Result::Error.new(@client, message, "```#{ex.inspect_with_backtrace}```")
      end
    end
  end

  def run!
    Log.info { "Running Discord client" }
    @client.run
  end
end
