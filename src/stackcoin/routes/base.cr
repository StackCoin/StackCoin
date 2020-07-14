class StackCoin::Api
end

abstract class StackCoin::Api::Route
  class_getter list : Array(Route) = [] of Route

  def should_return_html(env)
    headers = env.request.headers
    if headers.has_key? "Accept"
      return headers["Accept"].split(',').includes?("text/html")
    end
    false
  end

  def json_error(message)
    %({"message": "#{message}"})
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
    Log.debug { "Initialized route: #{self.class.name}" }
  end

  property routes : Array(String) = [] of String
  property requires_auth : Array(String) | Nil

  def info
    {
      "routes"        => @routes,
      "requires_auth" => @requires_auth,
    }
  end

  abstract def setup
end
