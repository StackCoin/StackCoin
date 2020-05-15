class StackCoin::Bot
  class Dole < Command
    def initialize(context : Context)
      @trigger = "dole"
      @desc = "Get some STK, daily"
      super context
    end

    def loading(message)
      send_msg message, "loading."
      sleep 20.seconds
      send_msg message, "loading.."
      sleep 20.seconds
      send_msg message, "loading..."
      sleep 20.seconds
    end

    def memes(message)
      case message.author.id.to_u64
      when 134337759446958081_u64 # sven
        loading message
        send_msg message, "ding!"
      when 120571255635181568_u64 # z64
        send_msg message, "m-m-maintainer-san @__@"
      when 140981598987354112_u64 # bobi
        loading message
        send_msg message, "boobi gt doyl"
      when 72073771468468224_u64 # cheem
        send_msg message, "DOLE"
      when 72069821960822784_u64 # duunie
        send_msg message, "'I need it'"
      when 163415804761735170_u64 # bigman
        send_msg message, "frdulnt tranactin dtectd by VraFin™™™™™™™™™™™™"
      when 636346308403134484_u64 # human lambo
        send_msg message, "Just send it to <@72073771468468224> now, might as well not wait until he beats you again :)"
      else
      end
    end

    def invoke(message)
      memes message
      send_msg message, @bank.deposit_dole(message.author.id.to_u64).message
    end
  end
end
