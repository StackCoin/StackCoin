class StackCoin::Api
end

abstract class StackCoin::Api::Route
  @@list = [] of Route

  def self.list
    @@list
  end

  def should_return_html(env)
    headers = env.request.headers
    if headers.has_key? "Accept"
      return headers["Accept"].split(',').includes? "text/html"
    end
    false
  end

  macro expect_key(key)
    halt env, status_code: 403, response: "Missing key: #{{{key}}}" if !env.params.json.has_key? {{key}}
  end

  property bank : Bank
  property stats : Statistics
  property auth : StackCoin::Auth
  property config : Config

  def initialize(context : Context)
    @bank = context.bank
    @stats = context.stats
    @auth = context.auth
    @config = context.config
    Route.list << self
  end

  abstract def setup
end
