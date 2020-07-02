require "../src/stackcoin/*"

martin_id = 0_u64
joshua_id = 1_u64
andrew_id = 2_u64
daniel_id = 3_u64

db = DB.open("sqlite3://%3Amemory%3A")
StackCoin::Database.init(db)
bank = StackCoin::Bank.new(db)
stats = StackCoin::Statistics.new(db)

martin_id = 0_u64
joshua_id = 1_u64
andrew_id = 2_u64
daniel_id = 3_u64

bank.open_account martin_id
bank.open_account andrew_id
bank.deposit_dole andrew_id
bank.open_account daniel_id
bank.deposit_dole daniel_id
bank.transfer(andrew_id, daniel_id, 1)
bank.transfer(andrew_id, daniel_id, 1)
bank.transfer(andrew_id, daniel_id, 1)
bank.transfer(andrew_id, daniel_id, 1)
bank.transfer(andrew_id, daniel_id, 1)
bank.transfer(andrew_id, daniel_id, 1)
bank.transfer(andrew_id, daniel_id, 1)
bank.transfer(andrew_id, daniel_id, 1)
bank.transfer(andrew_id, daniel_id, 1)

p stats.all_balances
p stats.leaderboard(5)
p stats.richest
p stats.ledger [] of String, [andrew_id, daniel_id], [daniel_id, andrew_id]
p stats.circulation
