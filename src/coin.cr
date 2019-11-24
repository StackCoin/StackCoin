require "discordcr"
require "redis"

class Coin
    def initialize(client : Discord::Client, redis : Redis, message : Discord::Message)
        @client = client
        @redis = redis
        @message = message
        @dole = 10
    end

    def send_msg(text)
        @client.create_message @message.channel_id, text
    end

    def send
        mentions = Discord::Mention.parse @message.content
        if mentions.size == 1
            mention = mentions[0]
            if mention.is_a? Discord::Mention::User
                if mention.id == @message.author.id
                    send_msg "You can't send money to yourself!"
                    return
                end

                author_bal_key = "#{@message.author.id}:bal"
                collector_bal_key = "#{mention.id}:bal"

                if @redis.get(collector_bal_key).is_a? Nil
                    send_msg "Collector of funds has no balance yet!, ask them to at least run 's!dole' once."
                    return
                end

                amount = Int32.new(0)

                begin
                    amount = @message.content.split(" ").last.to_i
                rescue
                    send_msg "Invalid amount: #{@message.content.split(" ").last}"
                    return
                end

                if amount < 0
                    send_msg "The amount must be greater than 0!"
                    return
                elsif amount > 10000
                    send_msg "The amount can't be greater than 10000!"
                    return
                end

                p @redis.eval "
                    local author_bal = redis.call('get',KEYS[1])
                    local collector_bal = redis.call('get',KEYS[2])

                    if author_bal - ARGV[1] >= 0 then
                        redis.call('set', KEYS[1], author_bal - ARGV[1])
                        local new_author_bal = redis.call('get', KEYS[1])

                        redis.call('set', KEYS[2], collector_bal + ARGV[1])
                        local new_collector_bal = redis.call('get', KEYS[2])

                        return {0, new_author_bal, new_collector_bal}
                    end

                    return {1, author_bal, collector_bal}
                ", [author_bal_key, collector_bal_key], [amount]
            end
        else
            send_msg "Too many/little mentions in your message!"
        end
    end

    def bal
        usr_id = @message.author.id.to_u64.to_s
        bal = @redis.get "#{usr_id}:bal"

        if bal.is_a? String
            send_msg "<@#{@message.author.id}> Balance: #{bal.as(String)}"
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