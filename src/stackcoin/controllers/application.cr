abstract class Application < ActionController::Base
  Log = StackCoin::Log.for("controller")

  protected def ensure_json
    unless request.headers["Content-Type"]?.try(&.starts_with?("application/json"))
      render status: :not_acceptable, text: "Accepts: application/json"
    end
  end

  def prod?
    StackCoin::Api.prod?
  end

  def pagination(pagination_limit)
    limit = (params["limit"]? || pagination_limit).to_i32
    offset = (params["offset"]? || 0).to_i32
    [limit, offset]
  end

  def valid_pagination(pagination_limit, limit, offset)
    limit < pagination_limit || limit > 0 || offset > 0
  end

  def pagination_params_back(limit, old_offset)
    new_offset = old_offset - limit

    new_offset = 0 if new_offset < 0

    "limit=#{limit}&offset=#{new_offset}"
  end

  def pagination_params_next(limit, old_offset)
    new_offset = old_offset + limit
    "limit=#{limit}&offset=#{new_offset}"
  end

  rescue_from JSON::MappingError do |error|
    Log.debug(exception: error) { "missing/extraneous properties in client JSON" }

    if prod?
      respond_with(:bad_request) do
        json({error: error.message})
      end
    else
      respond_with(:bad_request) do
        json({
          error:     error.message,
          backtrace: error.backtrace?,
        })
      end
    end
  end

  rescue_from JSON::ParseException do |error|
    Log.debug(exception: error) { "failed to parse client JSON" }

    if prod?
      respond_with(:bad_request) do
        json({error: error.message})
      end
    else
      respond_with(:bad_request) do
        json({
          error:     error.message,
          backtrace: error.backtrace?,
        })
      end
    end
  end

  # TODO error type + message from results
  macro unprocessable_entity
    respond_with(:unprocessable_entity) do
      json({error: "Unprocessable Entity"})
    end
  end

  macro unauthorized
    respond_with(:bad_request) do
      json({error: "Unauthorized"})
    end
  end

  def stats
    StackCoin::Statistics.get
  end

  def bank
    StackCoin::Bank.get
  end

  def auth
    StackCoin::Auth.get
  end

  def bot
    StackCoin::Bot.get
  end
end
