class StackCoin::Bot
  class Help < Command
    property root_help = Discord::Embed.new
    property sub_help = {} of String => Discord::Embed

    def initialize(context : Context)
      @trigger = "help"
      @aliases = ["why"]
      @usage = "?<subcommand>"
      @desc = "This command you're seeing right now!"
      super(context)

      all_fields = [] of Discord::EmbedField
      Command.commands.each_value do |command|
        name = "#{command.trigger}"
        name = "#{name} - #{command.usage}" if command.usage

        command_field = Discord::EmbedField.new(
          name: "#{name}",
          value: command.desc
        )

        @sub_help[command.trigger] = Discord::Embed.new(
          title: "Help: #{command.trigger}",
          fields: [command_field]
        )

        all_fields << command_field
      end

      @root_help = Discord::Embed.new(title: "Help:", fields: all_fields)
    end

    def invoke(message)
      msg_parts = Bot.cleaned_message_content(@config.prefix, message.content)
      return Result::Error.new(@client, message, "Too many arguments in message, found #{msg_parts.size}") if msg_parts.size > 2

      if msg_parts.size == 1
        send_emb(message, @root_help)
      else
        command = msg_parts.last

        if @sub_help.has_key? command
          send_emb(message, @sub_help[command])
        else
          postfix = ""
          potential = Levenshtein.find(command, @sub_help.keys)
          postfix = ", did you mean #{potential}?" if potential

          Result::Error.new(@client, message, "Unknown help section: #{command}#{postfix}")
        end
      end
    end
  end
end
