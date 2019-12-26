require "sqlite3"

DB.open "sqlite3://./data.db" do |db|
  db.exec "create table if not exists transactions (
    time integer,
    amount integer,
    author_id text,
    author_bal integer,
    collector_id text,
    collector_bal integer
  )"

  db.exec "insert into transactions values (?, ?, ?, ?, ?, ?)", 1,2,"3",4,"5",6
end
