class StackCoin::Api
  class Benefit < Route
    def initialize(context : Context)
      super(context)
      @routes = ["GET -> /benefit"]
    end

    def setup
      get "/benefit" do |env|
        benefit = @stats.all_benefits

        next render("src/views/benefit.ecr") if should_return_html(env)
        benefit.to_json
      end
    end
  end
end
