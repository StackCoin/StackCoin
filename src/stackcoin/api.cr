require "action-controller"
require "action-controller/logger"
require "kilt"

require "./controllers/application"
require "./controllers/*"

require "action-controller/server"

class StackCoin::Api
  NAME    = "StackCoin"
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify.downcase }}

  LOG_BACKEND = ActionController.default_backend

  # TODO bring env vars in .env.dist

  ENVIRONMENT = ENV["SG_ENV"]? || "development"

  DEFAULT_PORT          = (ENV["SG_SERVER_PORT"]? || 3000).to_i
  DEFAULT_HOST          = ENV["SG_SERVER_HOST"]? || "127.0.0.1"
  DEFAULT_PROCESS_COUNT = (ENV["SG_PROCESS_COUNT"]? || 1).to_i

  STATIC_FILE_PATH = ENV["PUBLIC_WWW_PATH"]? || "./www"

  COOKIE_SESSION_KEY    = ENV["COOKIE_SESSION_KEY"]? || "_stack_coin_"
  COOKIE_SESSION_SECRET = ENV["COOKIE_SESSION_SECRET"]? || "default_cookie_session_secret"

  def self.prod?
    ENVIRONMENT == "production"
  end
end

class StackCoin::Api
  @@server : ActionController::Server? = nil

  def initialize
    filter_params = ["password", "bearer_token"] # TODO hide our auth token

    ActionController::Server.before(
      ActionController::ErrorHandler.new(StackCoin::Api.prod?),
      ActionController::LogHandler.new(filter_params),
      HTTP::CompressHandler.new
    )

    ActionController::Session.configure do |settings|
      settings.key = StackCoin::Api::COOKIE_SESSION_KEY
      settings.secret = StackCoin::Api::COOKIE_SESSION_SECRET
      settings.secure = StackCoin::Api.prod?
    end
  end

  def run!
    port = StackCoin::Api::DEFAULT_PORT
    host = StackCoin::Api::DEFAULT_HOST

    server = ActionController::Server.new(port, host)

    @@server = server

    server.run do
      puts "Listening on #{server.print_addresses}"
    end
  end

  def close
    if server = @@server
      server.close
    end
  end
end
