require "jwt"
require "./result.cr"

class StackCoin::Auth
  class Result < StackCoin::Result
    class AccountCreated < Success
      property token : String

      def initialize(@message, @token)
      end
    end

    class Authenticated < Success
      property access_token : String

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

  @@instance : self? = nil

  def self.get
    @@instance.not_nil!
  end

  def initialize(@db : DB::Database, @bank : Bank, @jwt_secret_key : String)
    @@instance = self
  end

  def create_account_with_token(user_id : UInt64)
    result = @bank.open_account(user_id)
    return result if !result.is_a?(Bank::Result::Success)

    token = Random::Secure.hex(32)
    @db.exec(<<-SQL, user_id.to_s, token)
      INSERT INTO token VALUES (?, ?)
      SQL

    Result::AccountCreated.new("Account created", token)
  end

  def authenticate(user_id : UInt64, token : String)
    @db.transaction do |tx|
      cnn = tx.connection

      token_exists = cnn.query_one(<<-SQL, user_id.to_s, as: Int) == 1
        SELECT EXISTS(SELECT 1 FROM token WHERE user_id = ?)
        SQL

      return Result::NoSuchAccount.new(tx, "No such account") unless token_exists

      db_token = cnn.query_one(<<-SQL, user_id.to_s, as: String)
        SELECT token FROM token WHERE user_id = ?
        SQL

      return Result::InvalidToken.new(tx, "Invalid Token") unless db_token == token
    end

    invalid_at = (Time.utc + 1.seconds).to_s("%Y-%m-%d %H:%M:%S %:z")

    payload = {"user_id" => user_id, "invalid_at" => invalid_at}
    access_token = JWT.encode(payload, @jwt_secret_key, JWT::Algorithm::HS256)

    Result::Authenticated.new("Authenticated", access_token)
  end

  def validate_access_token(access_token : String)
    payload, header = JWT.decode(access_token, @jwt_secret_key, JWT::Algorithm::HS256)

    invalid_at = Time.parse_utc(payload["invalid_at"].as_s, "%Y-%m-%d %H:%M:%S %z")
    is_valid_access_token = invalid_at > Time.utc

    if !is_valid_access_token
      return Result::InvalidAccessToken.new("Invalid access token")
    end

    Result::ValidAccessToken.new("Valid access token", payload["user_id"].as_i64.to_u64)
  end
end
