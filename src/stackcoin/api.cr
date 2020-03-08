require "kemal"
require "./routes/base"
require "./routes/*"

class StackCoin::Api
  def initialize(config : Config, bank : Bank, stats : Statistics)
    User.new config, bank, stats
    Root.new config, bank, stats

    Route.list.each do |route|
      route.setup
    end
  end

  def run!
    Kemal.run
  end
end
