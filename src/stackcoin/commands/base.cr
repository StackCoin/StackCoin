class StackCoin::Bot
end

abstract class StackCoin::Bot::Command
  class_getter lookup : Hash(String, Command) = {} of String => Command
  class_getter commands : Hash(String, Command) = {} of String => Command

  getter trigger : String = ""
  getter aliases : Array(String) = [] of String
  getter usage : String | Nil
  getter desc : String = ""
  property client : Discord::Client
  property cache : Discord::Cache
  property bank : Bank
  property stats : Statistics
  property auth : StackCoin::Auth
  property banned : Banned
  property config : Config

  def initialize(context : Context)
    @client = context.client
    @cache = context.cache
    @bank = context.bank
    @stats = context.stats
    @auth = context.auth
    @banned = context.banned
    @config = context.config

    Command.commands[@trigger] = self
    Command.lookup[@trigger] = self
    @aliases.each do |command_alias|
      Command.lookup[command_alias] = self
    end

    Log.debug { "Initialized command: #{self.class.name}" }
  end

  def send_msg(message, content)
    @client.create_message(message.channel_id, content)
  end

  def send_msg(message, channel_id, content)
    @client.create_message(channel_id, content)
  end

  def send_emb(message, emb : Discord::Embed)
    self.send_emb(message, "", emb)
  end

  def send_emb(message, content, emb : Discord::Embed)
    emb.colour = 16773120
    emb.timestamp = Time.utc
    emb.footer = Discord::EmbedFooter.new(
      text: "StackCoin™",
      icon_url: "https://i.imgur.com/CsVxtvM.png"
    )
    @client.create_message(message.channel_id, content, emb)
  end

  abstract def invoke(message)
end
