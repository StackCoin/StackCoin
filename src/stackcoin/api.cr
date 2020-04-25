require "kemal"

require "./result"
require "./routes/base"
require "./routes/*"

class StackCoin::Api
  class Context
    getter bank : Bank
    getter stats : Statistics
    getter auth : StackCoin::Auth
    getter config : Config

    def initialize(@bank, @stats, @auth, @config)
    end
  end

  def initialize(config : Config, bank : Bank, stats : Statistics, auth : StackCoin::Auth)
    Log.info { "Initializing routes" }
    context = Context.new bank, stats, auth, config

    Ledger.new context
    Auth.new context
    User.new context

    Root.new context

    Route.list.each do |route|
      route.setup
    end
  end

  def run!
    Log.info { "Starting Kemal" }
    Kemal.run
  end
end
