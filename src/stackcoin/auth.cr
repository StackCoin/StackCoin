require "jwt"
require "./result.cr"

class StackCoin::Auth
  class Result < StackCoin::Result
    class Authenticated < Success
      JSON.mapping(
        message: String,
        access_token: String,
      )

      def initialize(@message, @access_token)
      end
    end

    class ValidAccessToken < Success
      getter user_id : UInt64

      def initialize(@message, @user_id)
      end
    end

    class InvalidAccessToken < Error
    end

    class NoSuchAccount < Error
    end

    class InvalidToken < Error
    end
  end

  def initialize(db : DB::Database)
    @db = db
  end

  def authenticate(user_id : UInt64, token : String)
    @db.transaction do |tx|
      cnn = tx.connection
      token_exists = cnn.query_one("SELECT EXISTS(SELECT 1 FROM token WHERE user_id = ?)", user_id.to_s, as: Int) == 1
      return Result::NoSuchAccount.new tx, "No such account" unless token_exists

      db_token = cnn.query_one "SELECT token FROM token WHERE user_id = ?", user_id.to_s, as: String
      return Result::InvalidToken.new tx, "Invalid Token" unless db_token == token
    end

    invalid_at = (Time.utc + 1.seconds).to_s("%Y-%m-%d %H:%M:%S %:z")

    payload = {"user_id" => user_id, "invalid_at" => invalid_at}
    access_token = JWT.encode(payload, "SecretKey", JWT::Algorithm::HS256)

    Result::Authenticated.new "Authenticated", access_token
  end

  def validate_access_token(access_token : String)
    payload, header = JWT.decode(access_token, "SecretKey", JWT::Algorithm::HS256)

    invalid_at = Time.parse_utc payload["invalid_at"].as_s, "%Y-%m-%d %H:%M:%S %z"
    is_valid_access_token = invalid_at > Time.utc

    return Result::InvalidAccessToken.new "Invalid access token" unless is_valid_access_token
    Result::ValidAccessToken.new "Valid access token", payload["user_id"].as_i64.to_u64
  end
end
