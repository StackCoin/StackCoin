class StackCoin::Banned
  def initialize(@db : DB::Database)
    Log.info { "Initialization list of banned users" }
    @banned_users = [] of UInt64

    all_banned_users = <<-SQL
      SELECT * FROM banned
      SQL

    db.query all_banned_users do |rs|
      rs.each do
        user_id = rs.read String
        @banned_users << user_id.to_u64
      end
    end
  end

  def is_banned(user_id : UInt64)
    @banned_users.includes? user_id
  end

  def ban(user_id : UInt64)
    Log.info { "Banning '#{user_id}'" }
    @banned_users << user_id

    @db.exec <<-SQL, args: [user_id.to_s]
      INSERT INTO banned VALUES (?)
      SQL
  end

  def unban(user_id : UInt64)
    Log.info { "Unbanning '#{user_id}'" }
    @banned_users.delete user_id
    @db.exec <<-SQL, args: [user_id.to_s]
      DELETE FROM banned WHERE user_id = ?
      SQL
  end
end
