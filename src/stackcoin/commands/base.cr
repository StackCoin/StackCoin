class StackCoin::Bot
end

abstract class StackCoin::Bot::Command
  getter trigger : String = ""
  getter usage : String | Nil = ""
  getter desc : String = ""
  property client : Discord::Client
  property cache : Discord::Cache
  property bank : Bank
  property  stats : Statistics
  property config : Config

  def initialize(context : Context)
    @client = context.client
    @cache = context.cache
    @bank = context.bank
    @stats = context.stats
    @config = context.config
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

  abstract def invoke(message)
end
