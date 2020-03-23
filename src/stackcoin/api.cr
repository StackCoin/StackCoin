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
    context = Context.new bank, stats, auth, config

    Root.new context
    Auth.new context
    User.new context

    Route.list.each do |route|
      route.setup
    end
  end

  def run!
    Kemal.run
  end
end
