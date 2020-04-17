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

  def json_error(message)
    %({"message": "#{message}"})
  end

  macro expect_json
    headers = env.request.headers
    next unless headers.has_key? "Content-Type"
    if headers["Content-Type"] != "application/json"
      halt env, status_code: 403, response: json_error "Content-Type must be application/json"
    end
  end

  macro expect_access_token
    if !env.request.headers.has_key? "X-Access-Token"
      halt env, status_code: 403, response: json_error "Missing header: X-Access-Token"
    end
  end

  macro expect_keys(keys)
    errors = ""
    {{keys}}.each do |key|
      errors = "#{errors}, #{key}" if !env.params.json.has_key? key
    end
    errors = errors.lchop ", "
    halt env, status_code: 403, response: json_error "Missing keys: #{errors}" if errors != ""
  end

  macro expect_value_to_be(type, value)
    halt env, status_code: 403, response: json_error "value '#{{{ value }}}' should be the type '#{{{ type }}}'" unless {{ value }}.is_a? {{ type }}
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
  end

  abstract def setup
end
