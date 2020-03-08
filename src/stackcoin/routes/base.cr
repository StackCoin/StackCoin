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

  def initialize(@config : Config, @bank : Bank, @stats : Statistics)
    Route.list << self
  end

  abstract def setup
end
