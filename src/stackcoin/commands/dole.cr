class StackCoin::Bot
  class Dole < Command
    def initialize(context : Context)
      @trigger = "dole"
      @desc = "Get some STK, daily"
      super context
    end

    def invoke(message)
      # Bet my money on a stupid horse, I lost that
      # So I ran out to the track to get my cash back
      # I just gotta leave this place with a big bag
      # So I found the fuckin' jockey and I grabbed that (pick it up)
      # Pushed him down to the ground and I punched him in his face (in his face)
      # Yeah, I stole his phone, that put him in his place (in his place)
      # Me on the horse, we ran out of the place (the place)
      # Then we took my Porsche back to my place
      if message.author.id.to_u64 == 134337759446958081_u64
        # Stupid horse, I just fell out of the Porsche
        # Lost the money in my bank account, oh no
        # Stupid horse, I just fell out of the Porsche
        # Lost the money in my bank account, oh no
        # Stupid horse, I just fell out of the Porsche
        # Lost the money in my bank account, oh no
        # Stupid horse, I just fell out of the Porsche
        # Lost the money in my bank account
        sleep 2.seconds
        send_msg message, "no sven"
        # Woo
        # Pick it up
        sleep 10.seconds
        send_msg message, "maybe?"
        sleep 5.seconds
        # Stupid horse and a swordfish dancer (pick it up)
        # Bet my money on a fishnet carousel
        # Go, go, go, go, go so fast now
        # Go, go, go, go, go so fast now
        # Racing horses at the derby
        # Why am I never getting lucky?
        # I never have any money
        # I never win any money
        send_msg message, "fine..."
        sleep 2.seconds
      end
      # Stupid horse, I just fell out of the Porsche
      # Lost the money in my bank account, oh no
      # Stupid horse, I just fell out of the Porsche
      # Lost the money in my bank account, oh no
      # Stupid horse, I just fell out of the Porsche (oh shit)
      # Lost the money in my bank account, oh no (oh no)
      # Stupid horse, I just fell out of the Porsche (oh no)
      # Lost the money in my bank account, oh no
      # Stupid horse, I just fell out of the Porsche (of the Porsche)
      # Lost the money in my bank account, oh no (oh no)
      # Stupid horse, I just fell out of the Porsche (of the Porsche)
      # Lost the money in my bank account
      send_msg message, @bank.deposit_dole(message.author.id.to_u64).message
    end
  end
end
