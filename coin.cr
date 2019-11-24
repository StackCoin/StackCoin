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

    def bal(payload)
        usr_id = grab_usr_id(payload)
        bal = @redis.get("#{usr_id}:bal")
        if bal.is_a?(String)
            @client.create_message(payload.channel_id, "<@#{payload.author.id}> Balance: #{bal.as(String)}")
        else
            @client.create_message(payload.channel_id, "You don't have a balance, run 's!dole' to collect some coin!")
        end
    end

    def incr_bal(payload, amount)
        usr_id = grab_usr_id(payload)
        return @redis.incrby("#{usr_id}:bal", amount)
    end

    def dole(payload)
        usr_id = grab_usr_id(payload)

        dole_key = "#{usr_id}:dole_date"
        now = Time.utc
        last_given = Redis::Future.new

        @redis.multi do |multi|
            last_given = multi.get(dole_key)
            multi.set(dole_key, now.to_unix)
        end

        if last_given.value.is_a?(Nil)
            give_dole(payload)
        elsif last_given.value.is_a?(String)
            last_given = Time.unix(last_given.value.as(String).to_u64)

            if last_given.day != now.day
                give_dole(payload)
            else
                deny_dole(payload)
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