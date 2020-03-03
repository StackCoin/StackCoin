require "discordcr"

module StackCoin
  class Bot
    property client
    property cache

    def initialize(config : Config)
      @client = Discord::Client.new(token: config.token, client_id: config.client_id)
      @cache = Discord::Cache.new(@client)
      @client.cache = @cache
    end

    def run!
      @client.run
    end
  end
end
