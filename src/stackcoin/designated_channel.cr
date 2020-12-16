class StackCoin::DesignatedChannel
  def initialize(@db : DB::Database)
    Log.info { "Initialization map of designated channels" }
    @designated_channels = Hash(Discord::Snowflake, Discord::Snowflake).new

    all_designated_channels = <<-SQL
      SELECT * FROM designated_channel
      SQL

    db.query(all_designated_channels) do |rs|
      rs.each do
        guild_id = Discord::Snowflake.new(rs.read(String)).not_nil!
        channel_id = Discord::Snowflake.new(rs.read(String)).not_nil!
        @designated_channels[guild_id] = channel_id
      end
    end
  end

  def is_permitted_to_reply_in(guild_id : Discord::Snowflake, channel_id : Discord::Snowflake)
    if permitted_channel = @designated_channels[guild_id]?
      return permitted_channel == channel_id
    end

    true
  end

  def for_guild(guild_id : Discord::Snowflake)
    @designated_channels[guild_id]?
  end

  def mark(guild_id : Discord::Snowflake, channel_id : Discord::Snowflake)
    if permitted_channel = @designated_channels[guild_id]?
      @designated_channels.delete(channel_id)
      @db.exec(<<-SQL, args: [guild_id.to_s])
        DELETE FROM designated_channel WHERE guild_id = ?
        SQL
    end

    Log.info { "Marking '#{channel_id}' as the channel to be used for messages for '#{guild_id}'" }
    @designated_channels[guild_id] = channel_id

    @db.exec(<<-SQL, args: [guild_id.to_s, channel_id.to_s])
      INSERT INTO designated_channel VALUES (?, ?)
      SQL
  end
end
