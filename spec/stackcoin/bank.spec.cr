require "spec"
require "../../src/stackcoin/*"

martin_id = 0_u64
joshua_id = 1_u64
andrew_id = 2_u64
daniel_id = 3_u64

def create_empty_test_bank
  db = DB.open "sqlite3://%3Amemory%3A"
  StackCoin::Database.init db
  StackCoin::Bank.new db
end

def create_populated_test_bank
  bank = create_empty_test_bank
  bank.open_account 0_u64 # martin
  bank.open_account 2_u64 # andrew
  bank.deposit_dole 2_u64
  bank.open_account 3_u64 # daniel
  bank.deposit_dole 3_u64

  bank.transfer 2_u64, 3_u64, 5 # andrew -> daniel
  bank
end

describe StackCoin::Bank do
  describe "balance" do
    it "returns nil with empty bank" do
      bank = create_empty_test_bank
      bank.balance(martin_id).should be_nil
    end

    it "returns correct amount from test bank" do
      bank = create_populated_test_bank
      bank.balance(martin_id).should eq 0
      bank.balance(joshua_id).should eq nil
      bank.balance(andrew_id).should eq 5
      bank.balance(daniel_id).should eq 15
    end
  end

  describe "account" do
    it "creates an account empty bank" do
      bank = create_empty_test_bank
      bank.balance(martin_id).should be_nil
    end

    it "returns correct amount from test bank" do
      bank = create_populated_test_bank
      bank.balance(martin_id).should eq 0
      bank.balance(joshua_id).should eq nil
      bank.balance(andrew_id).should eq 5
      bank.balance(daniel_id).should eq 15
    end
  end
end
