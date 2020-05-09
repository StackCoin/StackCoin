class StackCoin::Banned
  def initialize(@db : DB::Database)
    @banned_users = [] of UInt64

    db.query "SELECT * FROM banned" do |rs|
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
    @banned_users << user_id
    @db.exec "INSERT INTO banned VALUES (?)", args: [user_id.to_s]
  end
end
