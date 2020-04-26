require "kemal"

class StackCoin::Notification
  @channels : Hash(UInt64, Channel(StackCoin::Result::Base))

  enum SocketState
    Hello
    Ready
    AwaitingAcknowledgement
    Closed
  end

  struct Connection
    property socket : HTTP::WebSocket
    property user_id : UInt64

    def initialize(@socket, @user_id)
    end
  end

  struct AuthMessage
    JSON.mapping(
      token: String,
    )
  end

  struct AcknowledgeMessage
    JSON.mapping(
      acknowledge: String,
    )
  end

  def state_change(new_state)
    %({"state": "#{new_state}"})
  end

  def close(state, connection)
    state = SocketState::Closed
    connection.socket.send(state_change SocketState::Closed.to_s)
    connection.socket.close
    cleanup connection
  end

  def exception(state, connection, problem)
    connection.socket.send %({"exception": "#{problem}"})
    close state, connection
  end

  def failure(state, connection, problem)
    connection.socket.send %({"failure": "#{problem}"})
    close state, connection
  end

  def cleanup(connection)
    @channels.delete(connection.user_id)
    connection.socket.close
  end

  def inject(@auth : StackCoin::Auth)
  end

  def initialize(@db : DB::Database)
    @channels = Hash(UInt64, Channel(StackCoin::Result::Base)).new
  end

  def run!
    auth = @auth.not_nil!

    ws "/ws/notification/:user_id" do |socket, context|
      state = SocketState::Hello
      last_send_result_uuid = nil

      begin
        user_id = context.ws_route_lookup.params["user_id"].to_u64
      rescue
        exception state, Connection.new(socket, 0_u64), "Failed to parse user_id to u64"
        next
      end

      connection = Connection.new socket, user_id

      socket.send(state_change state.to_s)

      socket.on_message do |message|
        p "message: ", message
        state = SocketState::Closed if socket.closed?
        next if state.closed?

        begin
          response = JSON.parse(message)
          if !response.raw.is_a? Hash(String, JSON::Any)
            exception state, connection, "expected but did not get Hash(String, JSON::Any)"
            next
          end
        rescue e : JSON::ParseException
          exception state, connection, e.to_s
          next
        end

        response = response.as_h

        loop do
          case state
          when SocketState::Hello
            begin
              auth_message = AuthMessage.from_json message
              result = auth.valid_token user_id, auth_message.token

              if result.is_a? StackCoin::Auth::Result::ValidToken
                new_channel = Channel(StackCoin::Result::Base).new
                @channels[user_id] = new_channel

                # TODO populate new channel w/messages from DB

                state = SocketState::Ready
                socket.send(state_change state.to_s)
                next
              end
            rescue e : JSON::ParseException
              exception state, connection, "Invalid AuthMessage JSON: #{e}"
            end

            exception state, connection, "Auth failure"
          when SocketState::Ready
            result = @channels[user_id].receive
            break if socket.closed?
            last_send_result_uuid = result.uuid
            socket.send result.to_json

            state = SocketState::AwaitingAcknowledgement
            socket.send(state_change state.to_s)
            break
          when SocketState::AwaitingAcknowledgement
            begin
              acknowledge_message = AcknowledgeMessage.from_json message
              # TODO verify: acknowledge_message.acknowledge == last_send_result_uuid
              # TODO REMOVE MESSAGE FROM DB
            rescue e : JSON::ParseException
              exception state, connection, "Invalid AcknowledgeMessage JSON: #{e}"
            end

            state = SocketState::Ready
            socket.send(state_change state.to_s)
            next
          else
            raise "Unexpected state"
          end
        end
      end

      socket.on_close do
        cleanup connection
      end
    end
  end

  def send(user_id, result)
    # STORE RESULT IN DB

    if @channels.has_key? user_id
      puts "SENDING"
      @channels[user_id].send result
    end
  end
end
