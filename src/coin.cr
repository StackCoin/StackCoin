require "discordcr"
require "redis"

class Coin
  def initialize(client : Discord::Client, cache : Discord::Cache, redis : Redis, db : DB::Database, prefix : String)
    @client = client
    @cache = cache
    @redis = redis
    @db = db
    @prefix = prefix
    @dole = 10
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

  def check(message, condition, check_failed_message)
    send_msg message, check_failed_message if condition
    return condition
  end

  def send(message)
    guild_id = message.guild_id
    if !guild_id.is_a? Discord::Snowflake
      send_msg message, "This command is only valid within a guild!"
      return
    end

    mentions = Discord::Mention.parse message.content

    return if check(message, mentions.size != 1, "Too many/little mentions in your message!")

    mention = mentions[0]

    if !mention.is_a? Discord::Mention::User
      send_msg message, "Mentioned entity isn't a User"
      return
    end

    return if check(message, mention.id == message.author.id, "You can't send money to yourself!")

    author_bal_key = "#{message.author.id}:bal"
    collector_bal_key = "#{mention.id}:bal"

    return if check(message, @redis.get(author_bal_key).is_a? Nil, "You don't have any funds to give yet!, run '#{@prefix}dole' to collect some.")

    return if check(message, @redis.get(collector_bal_key).is_a? Nil, "Collector of funds has no balance yet!, ask them to at least run '#{@prefix}dole' once.")

    amount = Int32.new(0)
    msg_parts = message.content.split(" ")

    return if check(message, msg_parts.size > 3, "Too many arguments in message, found #{msg_parts.size}")

    begin
      amount = msg_parts.last.to_i
    rescue
      send_msg message, "Invalid amount: #{msg_parts.last}"
      return
    end

    return if check(message, amount <= 0, "The amount must be greater than 0!")
    return if check(message, amount > 10000, "The amount can't be greater than 10000!")

    redis_resp = @redis.eval "
      local author_bal = redis.call('get',KEYS[1])
      local collector_bal = redis.call('get',KEYS[2])

      if author_bal - ARGV[1] >= 0 then
        redis.call('set', KEYS[1], author_bal - ARGV[1])
        local new_author_bal = redis.call('get', KEYS[1])

        redis.call('set', KEYS[2], collector_bal + ARGV[1])
        local new_collector_bal = redis.call('get', KEYS[2])

        return {0, new_author_bal, new_collector_bal}
      end

      return {1, author_bal, collector_bal}", [author_bal_key, collector_bal_key], [amount]

    new_author_bal = redis_resp[1]
    raise "new_author_bal isn't a String" if !new_author_bal.is_a?(String)

    new_collector_bal = redis_resp[2]
    raise "new_collector_bal isn't a String" if !new_collector_bal.is_a?(String)

    return if check(message, redis_resp[0] != 0, "Failed to transfer funds!")

    collector = @cache.resolve_user(mention.id)

    trans = [] of DB::Any
    trans << guild_id.to_u64.to_i64
    trans << message.author.id.to_u64.to_i64
    trans << message.author.username
    trans << new_author_bal
    trans << collector.id.to_u64.to_i64
    trans << collector.username
    trans << new_collector_bal
    trans << amount
    trans << Time.utc

    @db.exec "INSERT INTO ledger VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", args: trans

    send_emb message, "Transaction complete!", Discord::Embed.new(
      fields: [
        Discord::EmbedField.new(
          name: "#{message.author.username}",
          value: "New bal: #{new_author_bal}",
        ),
        Discord::EmbedField.new(
          name: "#{collector.username}",
          value: "New bal: #{new_collector_bal}",
        ),
      ],
    )
  end

  def bal(message)
    usr_id = message.author.id.to_u64.to_s
    bal = @redis.get "#{usr_id}:bal"

    if bal.is_a? String
      send_emb message, "", Discord::Embed.new(
        fields: [Discord::EmbedField.new(
          name: "#{message.author.username}",
          value: "Bal: #{bal}",
        )]
      )
    else
      send_msg message, "You don't have a balance, run '#{@prefix}dole' to collect some coin!"
    end
  end

  def incr_bal(message, amount)
    usr_id = message.author.id.to_u64.to_s
    return @redis.incrby "#{usr_id}:bal", amount
  end

  def dole(message)
    usr_id = message.author.id.to_u64.to_s

    dole_key = "#{usr_id}:dole_date"
    now = Time.utc
    last_given = Redis::Future.new

    @redis.multi do |multi|
      last_given = multi.get dole_key
      multi.set dole_key, now.to_unix
    end

    if last_given.value.is_a? Nil
      give_dole message
    elsif last_given.value.is_a? String
      last_given = Time.unix last_given.value.as(String).to_u64

      if last_given.day != now.day
        give_dole message
      else
        deny_dole message
      end
    end
  end

  def give_dole(message)
    new_bal = incr_bal(message, @dole)
    send_msg message, "Dole given, new bal #{new_bal}"
  end

  def deny_dole(message)
    send_msg message, "Dole already given today!"
  end
end
