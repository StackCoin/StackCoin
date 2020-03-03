module StackCoin
  class Config
    property token : String = ""
    property client_id : UInt64 = 0_u64
    property prefix : String = ""
    property test_guild_snowflake : Discord::Snowflake = Discord::Snowflake.new 0_u64
    property redis_host : String = ""

    def self.from_env
      config = Config.new
      config.token = ENV["STACKCOIN_DISCORD_TOKEN"]
      config.client_id = ENV["STACKCOIN_DISCORD_CLIENT_ID"].to_u64
      config.prefix = ENV["STACKCOIN_PREFIX"]
      config.test_guild_snowflake = Discord::Snowflake.new ENV["STACKCOIN_TEST_GUILD_SNOWFLAKE"]
      config.redis_host = ENV["STACKCOIN_REDIS_HOST"]
      config
    end
  end
end
