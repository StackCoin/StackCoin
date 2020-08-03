class Root < Application
  base "/"

  def index
    routes = [] of {String, Symbol, Symbol, String}
    {% for klass in ActionController::Base::CONCRETE_CONTROLLERS %}
      routes.concat {{klass}}.__route_list__
    {% end %}

    grouped_routes = {} of String => Array({action: Symbol, verb: Symbol, uri: String})

    routes.each do |route|
      grouped_routes[route[0]] = [] of {action: Symbol, verb: Symbol, uri: String} unless grouped_routes.has_key?(route[0])

      grouped_routes[route[0]] << {
        action: route[1],
        verb:   route[2],
        uri:    route[3],
      }
    end

    respond_with do
      json(grouped_routes)
      html template("home.ecr")
    end
  end
end
