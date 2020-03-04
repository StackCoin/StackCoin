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

  martin_id = 0_u64
  joshua_id = 1_u64
  andrew_id = 2_u64
  daniel_id = 3_u64

  bank.open_account martin_id
  bank.open_account andrew_id
  bank.deposit_dole andrew_id
  bank.open_account daniel_id
  bank.deposit_dole daniel_id
  bank.transfer andrew_id, daniel_id, 5
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

  describe "deposit_dole" do
    it "gives user dole if they're freshly created" do
      bank = create_populated_test_bank
      bank.deposit_dole(martin_id).should be_a StackCoin::Result::Success
    end

    it "fails on no account" do
      bank = create_populated_test_bank
      bank.deposit_dole(joshua_id).should be_a StackCoin::Bank::Result::NoSuchAccount
    end

    it "fails on giving user dole that already gotten it today" do
      bank = create_populated_test_bank
      bank.deposit_dole(andrew_id).should be_a StackCoin::Bank::Result::PrematureDole
    end

    it "fails, then passes once its a week in the future" do
      bank = create_populated_test_bank
      bank.deposit_dole(andrew_id).should be_a StackCoin::Bank::Result::PrematureDole
      bank.db.exec "UPDATE last_given_dole SET time = ? WHERE id = ?", Time.utc + 1.weeks, andrew_id.to_s
      bank.deposit_dole(andrew_id).should be_a StackCoin::Result::Success
    end
  end

  describe "open_account" do
    it "creates an account that doens't already exist" do
      bank = create_populated_test_bank
      bank.balance(joshua_id).should be_nil
      bank.open_account(joshua_id)
      bank.balance(joshua_id).should be_a Int32
    end

    it "fails on creating existing account" do
      bank = create_populated_test_bank
      bank.open_account(martin_id).should be_a StackCoin::Bank::Result::PreexistingAccount
    end
  end

  describe "transfer" do
    it "sends money from one user to another" do
      bank = create_populated_test_bank

      resp = bank.transfer(daniel_id, martin_id, 5)
      resp.should be_a StackCoin::Bank::Result::TransferSuccess

      if resp.is_a? StackCoin::Bank::Result::TransferSuccess
        resp.from_bal.should eq 10
        resp.to_bal.should eq 5
      end
    end

    it "fails if user is trying to transfer money to themselves" do
      bank = create_populated_test_bank
      resp = bank.transfer(martin_id, martin_id, 10).should be_a StackCoin::Bank::Result::TransferSelf
    end

    it "fails if amount is less than zero" do
      bank = create_populated_test_bank
      resp = bank.transfer(daniel_id, martin_id, -1).should be_a StackCoin::Bank::Result::InvalidAmount
    end

    it "fails if amount is greater than 10000" do
      bank = create_populated_test_bank
      resp = bank.transfer(martin_id, daniel_id, 10001).should be_a StackCoin::Bank::Result::InvalidAmount
    end

    it "fails if sender has no account" do
      bank = create_populated_test_bank
      resp = bank.transfer(joshua_id, daniel_id, 10).should be_a StackCoin::Bank::Result::NoSuchAccount
    end

    it "fails if reciever hsa no account" do
      bank = create_populated_test_bank
      resp = bank.transfer(daniel_id, joshua_id, 10).should be_a StackCoin::Bank::Result::NoSuchAccount
    end

    it "fails if poor" do
      bank = create_populated_test_bank
      resp = bank.transfer(martin_id, andrew_id, 10).should be_a StackCoin::Bank::Result::InsufficientFunds
    end

    it "fails if poor, then after getting dole, passes" do
      bank = create_populated_test_bank
      resp = bank.transfer(martin_id, andrew_id, 10).should be_a StackCoin::Bank::Result::InsufficientFunds
      bank.deposit_dole martin_id
      resp = bank.transfer(martin_id, andrew_id, 10).should be_a StackCoin::Bank::Result::TransferSuccess
    end
  end
end
