class StackCoin::Config
  property token : String = ""
  property client_id : UInt64 = 0_u64
  property prefix : String = ""
  property test_guild_snowflake : Discord::Snowflake = Discord::Snowflake.new 0_u64
  property database_url : String = ""
  property jwt_secret_key : String = ""
  property owner_id : Discord::Snowflake = Discord::Snowflake.new 0_u64

  def self.from_env
    config = Config.new
    config.token = "Bot #{ENV["STACKCOIN_DISCORD_TOKEN"]}"
    config.client_id = ENV["STACKCOIN_DISCORD_CLIENT_ID"].to_u64
    config.prefix = ENV["STACKCOIN_PREFIX"]
    config.test_guild_snowflake = Discord::Snowflake.new ENV["STACKCOIN_TEST_GUILD_SNOWFLAKE"]
    config.database_url = ENV["STACKCOIN_DATABASE_URL"]
    config.jwt_secret_key = ENV["STACKCOIN_JWT_SECRET_KEY"]
    config.owner_id = Discord::Snowflake.new ENV["STACKCOIN_OWNER_ID"]
    config
  end
end
