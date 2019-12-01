require "discordcr"
require "redis"

class Coin
  def initialize(client : Discord::Client, cache : Discord::Cache, redis : Redis, message : Discord::Message)
    @client = client
    @cache = cache
    @redis = redis
    @message = message
    @dole = 10
  end

  def send_msg(content)
    @client.create_message @message.channel_id, content
  end

  def send_emb(content, emb)
    emb.colour = 16773120
    emb.timestamp = Time.utc
    emb.footer = Discord::EmbedFooter.new(
      text: "StackCoin™",
      icon_url: "https://i.imgur.com/CsVxtvM.png"
    )
    @client.create_message @message.channel_id, content, emb
  end

  def send
    mentions = Discord::Mention.parse @message.content
    if mentions.size != 1
      send_msg "Too many/little mentions in your message!"
    end

    mention = mentions[0]
    if !mention.is_a? Discord::Mention::User
      send_msg "Mentioned entity isn't a User"
      return
    end

    if mention.id == @message.author.id
      send_msg "You can't send money to yourself!"
      return
    end

    author_bal_key = "#{@message.author.id}:bal"
    collector_bal_key = "#{mention.id}:bal"

    if @redis.get(author_bal_key).is_a? Nil
      send_msg "You don't have any funds to give yet!, run 's!dole' to collect some."
      return
    end

    if @redis.get(collector_bal_key).is_a? Nil
      send_msg "Collector of funds has no balance yet!, ask them to at least run 's!dole' once."
      return
    end

    amount = Int32.new(0)
    msg_parts = @message.content.split(" ")

    if msg_parts.size > 3
      send_msg "Too many arguments in message, found #{msg_parts.size}"
      return
    end

    begin
      amount = msg_parts.last.to_i
    rescue
      send_msg "Invalid amount: #{msg_parts.last}"
      return
    end

    if amount < 0
      send_msg "The amount must be greater than 0!"
      return
    elsif amount > 10000
      send_msg "The amount can't be greater than 10000!"
      return
    end

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
    new_collector_bal = redis_resp[2]

    if redis_resp[0] == 0
      collector = @cache.resolve_user(mention.id)

      send_emb "Transaction complete!", Discord::Embed.new(
        fields: [
          Discord::EmbedField.new(
            name: "#{@message.author.username}",
            value: "New bal: #{new_author_bal}",
          ),
          Discord::EmbedField.new(
            name: "#{collector.username}",
            value: "New bal: #{new_collector_bal}",
          ),
        ],
      )
    elsif
      send_msg "fail"
    end
  end

  def bal
    usr_id = @message.author.id.to_u64.to_s
    bal = @redis.get "#{usr_id}:bal"

    if bal.is_a? String
      send_emb "", Discord::Embed.new(
        fields: [Discord::EmbedField.new(
          name: "#{@message.author.username}",
          value: "Bal: #{bal}",
        )]
      )
    else
      send_msg "You don't have a balance, run 's!dole' to collect some coin!"
    end
  end

  def incr_bal(amount)
    usr_id = @message.author.id.to_u64.to_s
    return @redis.incrby "#{usr_id}:bal", amount
  end

  def dole
    usr_id = @message.author.id.to_u64.to_s

    dole_key = "#{usr_id}:dole_date"
    now = Time.utc
    last_given = Redis::Future.new

    @redis.multi do |multi|
      last_given = multi.get dole_key
      multi.set dole_key, now.to_unix
    end

    if last_given.value.is_a? Nil
      give_dole
    elsif last_given.value.is_a? String
      last_given = Time.unix last_given.value.as(String).to_u64

      if last_given.day != now.day
        give_dole
      else
        deny_dole
      end
    end
  end

  def give_dole
    new_bal = incr_bal @dole
    send_msg "Dole given, new bal #{new_bal}"
  end

  def deny_dole
    send_msg "Dole already given today!"
  end
end
