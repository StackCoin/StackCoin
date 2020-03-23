class StackCoin::Api
  class Root < Route
    def setup
      get "/" do |env|
        next render "src/views/home.ecr" if self.should_return_html env
        Hash(String, String).new.to_json # TODO return all routes
      end
    end
  end
end
