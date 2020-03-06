require "discordcr"

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

  def initialize(config : Config, bank : Bank, stats : Statistics)
    @client = Discord::Client.new(token: config.token, client_id: config.client_id)
    @cache = Discord::Cache.new(@client)
    @client.cache = @cache
    @config = config
    @bank = bank
    @stats = stats

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
        self.leaderboard message if msg.starts_with? "#{config.prefix}leaderboard"
        self.ledger message if msg.starts_with? "#{config.prefix}ledger"
        self.circulation message if msg.starts_with? "#{config.prefix}circulation"
      rescue ex
        puts ex.inspect_with_backtrace
        Result::Error.new @client, message, "```#{ex.inspect_with_backtrace}```"
      end
    end
  end

  def cache
    @cache
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
    return Result::Error.new(@client, message, "Too many mentions in your message; max is one") if mentions.size > 1

    prefix = "You don't"
    user = message.author
    bal = nil

    if mentions.size > 0
      mention = mentions[0]
      if !mention.is_a? Discord::Mention::User
        return Result::Error.new @client, message, "Mentioned entity isn't a user!"
      end

      user = @cache.resolve_user mention.id
      bal = @bank.balance mention.id.to_u64
      prefix = "User doesn't" if mention.id != message.author.id
    else
      bal = @bank.balance message.author.id.to_u64
    end

    if bal.is_a? Nil
      return Result::Error.new @client, message, "#{prefix} have an account, run #{@config.prefix}open to create an account"
    end

    send_emb message, "", Discord::Embed.new(
      title: "_Balance:_",
      fields: [Discord::EmbedField.new(
        name: "#{user.username}",
        value: "#{bal}",
      )]
    )
  end

  def open(message)
    send_msg message, @bank.open_account(message.author.id.to_u64).message
  end

  def dole(message)
    send_msg message, @bank.deposit_dole(message.author.id.to_u64).message
  end

  def leaderboard(message)
    fields = [] of Discord::EmbedField

    @stats.leaderboard.each_with_index do |res, i|
      user = @cache.resolve_user res[0]
      fields << Discord::EmbedField.new(
        name: "\##{i + 1}: #{user.username}",
        value: "Balance: #{res[1]}"
      )
    end

    send_emb message, "", Discord::Embed.new title: "_Leaderboard:_", fields: fields
  end

  def circulation(message)
    send_emb message, "", Discord::Embed.new(
      title: "_Total StackCoin in Circulation:_",
      fields: [Discord::EmbedField.new(
        name: "#{@stats.circulation} STK",
        value: "Since #{EPOCH}",
      )]
    )
  end

  def ledger(message)
    dates = [] of String
    from_ids = [] of UInt64
    to_ids = [] of UInt64

    fields = [] of Discord::EmbedField
    condition_context = [] of String

    yyy_mm_dd_regex = /([12]\d{3}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01]))/
    matches = message.content.scan(yyy_mm_dd_regex)
    return Result::Error.new(@client, message, "Too many yyyy-mm-dd string in your message; max is one") if matches.size > 1
    if matches.size > 0
      date = matches[0][1]
      dates << date
      condition_context << "Occured on #{date}"
    end

    mentions = Discord::Mention.parse message.content
    return Result::Error.new(@client, message, "Too many mentions in your message; max is two") if mentions.size > 2
    mentions.each do |mentioned|
      if !mentioned.is_a? Discord::Mention::User
        return Result::Error.new(@client, message, "Mentioned a non-user entity in your message") if mentions.size > 2
      else
        # TODO allow to specify from / to
        from_ids << mentioned.id
        to_ids << mentioned.id
        condition_context << "Mentions #{@cache.resolve_user(mentioned.id).username}"
      end
    end

    ledger_results = @stats.ledger dates, from_ids, to_ids

    ledger_results.results.each_with_index do |result, i|
      from = @cache.resolve_user result.from_id
      to = @cache.resolve_user result.to_id
      fields << Discord::EmbedField.new(
        name: "#{i + 1} - #{result.time}",
        value: "#{from.username} (#{result.from_bal}) ⟶ #{to.username} (#{result.to_bal}) - #{result.amount} STK"
      )
    end

    condition_context << "Most recent" if condition_context.size == 0

    fields << Discord::EmbedField.new(
      name: "*crickets*",
      value: "Seems like no transactions were found in the ledger :("
    ) if fields.size == 0

    title = "_Searching ledger by_:"
    condition_context.each do |cond|
      title += "\n- #{cond}"
    end

    send_emb message, "", Discord::Embed.new(title: title, fields: fields)
  end

  def run!
    @client.run
  end
end
