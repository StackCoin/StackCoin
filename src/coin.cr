require "discordcr"
require "redis"

class Coin
    def initialize(client : Discord::Client, redis : Redis)
        @client = client
        @redis = redis
        @dole = 10
    end

    def grab_usr_id(payload)
        return payload.author.id.to_u64.to_s
    end

    def send_msg(payload, text)
        @client.create_message payload.channel_id, text
    end

    def send(payload)
        mentions = Discord::Mention.parse payload.content
        if mentions.size == 1
            mention = mentions[0]
            if mention.is_a? Discord::Mention::User
                author_bal_key = "#{payload.author.id}:bal"
                collector_bal_key = "#{mention.id}:bal"

                if @redis.get(collector_bal_key).is_a? Nil
                    send_msg payload, "Collector of funds has no balance yet!, ask them to at least run 's!dole' once."
                    return
                end

                amount = payload.content.split(" ").last.to_i

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
            send_msg payload, "Too many/little mentions in your message!"
        end
    end

    def bal(payload)
        usr_id = payload.author.id.to_u64.to_s
        bal = @redis.get "#{usr_id}:bal"

        if bal.is_a? String
            send_msg payload, "<@#{payload.author.id}> Balance: #{bal.as(String)}"
        else
            send_msg payload, "You don't have a balance, run 's!dole' to collect some coin!"
        end
    end

    def incr_bal(payload, amount)
        usr_id = payload.author.id.to_u64.to_s
        return @redis.incrby "#{usr_id}:bal", amount
    end

    def dole(payload)
        usr_id = payload.author.id.to_u64.to_s

        dole_key = "#{usr_id}:dole_date"
        now = Time.utc
        last_given = Redis::Future.new

        @redis.multi do |multi|
            last_given = multi.get dole_key
            multi.set dole_key, now.to_unix
        end

        if last_given.value.is_a? Nil
            give_dole payload
        elsif last_given.value.is_a? String
            last_given = Time.unix last_given.value.as(String).to_u64

            if last_given.day != now.day
                give_dole payload
            else
                deny_dole payload
            end
        end
    end

    def give_dole(payload)
        new_bal = incr_bal(payload, @dole)
        @client.create_message(payload.channel_id, "Dole given, new bal #{new_bal}")
    end

    def deny_dole(payload)
        @client.create_message(payload.channel_id, "Dole already given today!")
    end
end