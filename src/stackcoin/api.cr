require "kemal"
require "./routes/base"
require "./routes/*"

class StackCoin::Api
  class Context
    getter bank : Bank
    getter stats : Statistics
    getter config : Config

    def initialize(@bank, @stats, @config)
    end
  end

  def initialize(config : Config, bank : Bank, stats : Statistics)
    context = Context.new bank, stats, config

    User.new context
    Root.new context

    Route.list.each do |route|
      route.setup
    end
  end

  def run!
    Kemal.run
  end
end
