class Auth < Application
  base "/auth/"

  class AuthPost
    include JSON::Serializable
    property user_id : UInt64
    property token : String
  end

  def create
    ensure_json
    auth_post = AuthPost.from_json(request.body.not_nil!)

    result = auth.authenticate(auth_post.user_id, auth_post.token)

    if !result.is_a?(StackCoin::Auth::Result::Authenticated)
      unauthorized
    end

    respond_with do
      json(result)
    end
  end
end
