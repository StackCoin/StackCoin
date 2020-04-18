class StackCoin::Api
  class Root < Route
    def initialize(context : Context)
      super context
      @routes = ["GET -> /"]
    end

    def setup
      get "/" do |env|
        next render "src/views/home.ecr" if self.should_return_html env

        infos = Hash(String, Hash(String, Array(String) | Nil)).new

        Route.list.each do |route|
          infos[route.class.name] = route.info
        end

        infos.to_json
      end
    end
  end
end
