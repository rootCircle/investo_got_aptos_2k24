module investo_addr::investo {
  use std::signer;
  use std::vector;
  use std::string::{Self, String};
  use aptos_std::table::{Self, Table};
  use aptos_std::timestamp;
  use aptos_std::aptos_account;
  use aptos_std::aptos_coin;
  use aptos_token_objects::collection::{Self};
  use aptos_token_objects::token::{Self, Token};
  use aptos_framework::object;
  use std::option;

  const E_NOT_INITIALIZED: u64 = 1;
  const E_NO_CORRESPONDING_DEAL: u64 = 2;
  const E_DEAL_FREEZED: u64 = 3;
  const E_AMOUNT_EXCEEDS_TARGET: u64 = 4;
  const E_UNAUTHORIZED_ACCESS: u64 = 5;
  const E_INVALID_TARGET_AMOUNT: u64 = 6;
  const E_INVALID_FREEZING_PERIOD: u64 = 7;
  const E_INVALID_MATURITY_TIMESTAMP: u64 = 8;
  const E_INVALID_MIN_TOKEN_AMOUNT: u64 = 9;
  const E_TARGET_AMOUNT_LESS_THAN_MIN_TOKEN_AMOUNT: u64 = 10;
  const E_UNAUTHORIZED: u64 = 11;
  const E_NOT_MATURED_YET: u64 = 12;
  const E_UNAUTHORIZED_DIGITAL_ASSET_ACCESS: u64 = 13;
  const E_DIGITAL_ASSET_TRANSFER_FAILED: u64 = 14;
  
  struct OnChainConfig has key {
    collection: String,
  }

  struct Deals has key {
    deal: Table<u64, Deal>,
    deal_counter: u64,
  }

  struct Investments has key {
    investment: Table<u64, Investment>,
    investment_counter: u64,
  }

  // A deal is open for investment till freezingPeriodStartTimestamp, and after any investment is not allowed
  // A withdrawl after freezingPeriodStartTimestamp, but before dealMaturityTimestamp, will only return the amount invested, not the interest
  struct Deal has store, drop, copy {
    minTokenAmount: u64,
    targetRaiseAmount: u64,
    freezingPeriodStartTimestamp: u64,
    dealMaturityTimestamp: u64,
    tokenNFTID: u64,
    promisedInterestRate: u64,
    companyAddress: address,
    amountRaised: u64, // Live
  }
  
  struct Investment has store, drop, copy {
    dealID: u64, // same as the key of the deal(table<dealID, Deal>)
    investorAddress: address,
    amountInvested: u64,
  }

  inline fun assert_admin(deployer: &signer) {
      assert!(signer::address_of(deployer) == @investo_addr, E_UNAUTHORIZED);
  }


  public entry fun initializeInvesto(account: &signer) {
    let investment_holder = Investments {
      investment: table::new(),
      investment_counter: 0,
    };
    
    let deal_holder = Deals {
      deal: table::new(),
      deal_counter: 0,
    };

    let royalty = option::none();

    let collection_name = string::utf8(b"Investment Collection");
 
    collection::create_unlimited_collection(
        account,
        string::utf8(b"This is a sample description of the collection containing all invoices"),
        collection_name,
        royalty,
        string::utf8(b"https://google.com"),
    );

    move_to(account, investment_holder);
    move_to(account, deal_holder);
    move_to(account, OnChainConfig {
      collection: collection_name,
    });
  }

  public entry fun mintNFT(account: &signer, digitalAssetname: String, description: String, uri: String) acquires OnChainConfig {
    let signer_address = signer::address_of(account);
    let on_chain_config = borrow_global<OnChainConfig>(signer_address);

    token::create_named_token(
        account,
        on_chain_config.collection,
        description,
        digitalAssetname,
        option::none(),
        uri,
    );
  }

  public fun create_token_seed(collection: &String, name: &String): vector<u8> {
    // assert!(string::length(name) <= MAX_TOKEN_NAME_LENGTH, error::out_of_range(ETOKEN_NAME_TOO_LONG));
    let seed = *string::bytes(collection);
    vector::append(&mut seed, b"::");
    vector::append(&mut seed, *string::bytes(name));
    seed
}


  public entry fun transferNFT(account: &signer, receiver: address, digitalAssetname: String) acquires OnChainConfig {
    let signer_address = signer::address_of(account);
    let on_chain_config = borrow_global<OnChainConfig>(signer_address);
    let collection_name = on_chain_config.collection;
    let token_addr = object::create_object_address(&signer_address, create_token_seed(&collection_name, &digitalAssetname));
    let token = object::address_to_object<Token>(token_addr);
    assert!(object::owner(token) == signer_address, E_UNAUTHORIZED_DIGITAL_ASSET_ACCESS);
    object::transfer(account, token, receiver);
    assert!(object::owner(token) == receiver, E_DIGITAL_ASSET_TRANSFER_FAILED);

  }


  public entry fun addInvestment(account: &signer, dealID: u64, investorAddress: address, amountInvested: u64) acquires Investments, Deals {
    let signer_address = signer::address_of(account);
  
    assert!(exists<Deals>(signer_address), E_NOT_INITIALIZED);
    assert!(exists<Investments>(signer_address), E_NOT_INITIALIZED);

    let investment_holder = borrow_global_mut<Investments>(signer_address);
    let deal_holder = borrow_global_mut<Deals>(signer_address);

    assert!(table::contains(&deal_holder.deal, dealID), E_NO_CORRESPONDING_DEAL);
    let deal = table::borrow(&deal_holder.deal, dealID);
    
    // assert!(deal.freezingPeriodStartTimestamp > timestamp::now_microseconds(), E_DEAL_FREEZED);
    assert!(deal.targetRaiseAmount >= deal.amountRaised + amountInvested, E_AMOUNT_EXCEEDS_TARGET);

    let leftAmt = deal.targetRaiseAmount - deal.amountRaised;
    assert!(
      amountInvested >= deal.minTokenAmount || 
      (leftAmt < deal.minTokenAmount && amountInvested == leftAmt),
      E_AMOUNT_EXCEEDS_TARGET
    );

    let counter = investment_holder.investment_counter + 1;

    let investment = Investment {
      dealID: dealID,
      investorAddress: investorAddress,
      amountInvested: amountInvested,
    };

    aptos_account::transfer_coins<aptos_coin::AptosCoin>(account, investorAddress, amountInvested);

    table::upsert(&mut investment_holder.investment, counter, investment);

    investment_holder.investment_counter = counter;
    table::borrow_mut(&mut deal_holder.deal, dealID).amountRaised = deal.amountRaised +  amountInvested;
  }

  public entry fun addDeal(
    account: &signer,
    minTokenAmount: u64,
    targetRaiseAmount: u64,
    freezingPeriodStartTimestamp: u64,
    dealMaturityTimestamp: u64,
    tokenNFTID: u64,
    promisedInterestRate: u64,
    companyAddress: address
  ) acquires Deals {
    let signer_address = signer::address_of(account);

    assert!(exists<Deals>(signer_address), E_NOT_INITIALIZED);
    assert_admin(account);

    // TODO: Confirm if user is authorized to add a deal
    assert!(targetRaiseAmount > 0, E_INVALID_TARGET_AMOUNT);
    // assert!(freezingPeriodStartTimestamp > timestamp::now_microseconds(), E_INVALID_FREEZING_PERIOD);
    assert!(dealMaturityTimestamp > freezingPeriodStartTimestamp, E_INVALID_MATURITY_TIMESTAMP);
    assert!(minTokenAmount > 0, E_INVALID_MIN_TOKEN_AMOUNT);
    assert!(targetRaiseAmount >= minTokenAmount, E_TARGET_AMOUNT_LESS_THAN_MIN_TOKEN_AMOUNT);

    let deal_holder = borrow_global_mut<Deals>(signer_address);

    let dealID = deal_holder.deal_counter + 1;

    let deal = Deal {
      minTokenAmount: minTokenAmount,
      targetRaiseAmount: targetRaiseAmount,
      freezingPeriodStartTimestamp: freezingPeriodStartTimestamp,
      dealMaturityTimestamp: dealMaturityTimestamp,
      tokenNFTID: tokenNFTID,
      promisedInterestRate: promisedInterestRate,
      companyAddress: companyAddress,
      amountRaised: 0,
    };

    table::upsert(&mut deal_holder.deal, dealID, deal);

    deal_holder.deal_counter = dealID;
  }

  public entry fun transferAllBackPerDeal(account: &signer, dealID: u64) acquires Deals, Investments {
    let signer_address = signer::address_of(account);

    assert!(exists<Deals>(signer_address), E_NOT_INITIALIZED);
    assert!(exists<Investments>(signer_address), E_NOT_INITIALIZED);

    assert_admin(account);

    let deal_holder = borrow_global_mut<Deals>(signer_address);
    let investment_holder = borrow_global_mut<Investments>(signer_address);

    assert!(table::contains(&deal_holder.deal, dealID), E_NO_CORRESPONDING_DEAL);
    let deal = table::borrow(&deal_holder.deal, dealID);

    // assert!(deal.dealMaturityTimestamp <= timestamp::now_microseconds(), E_NOT_MATURED_YET);

    let interest = (deal.targetRaiseAmount * (deal.promisedInterestRate + 100) * (deal.dealMaturityTimestamp - deal.freezingPeriodStartTimestamp)) / (100 * 365 * 24 * 60 * 60 * 1000000);

    let i = 0;
    while (i <= investment_holder.investment_counter) {
      if (table::contains(&investment_holder.investment, i)) {
        let investment = table::borrow(&investment_holder.investment, i);
        if (investment.dealID == dealID && investment.amountInvested != 0) {
          aptos_account::transfer_coins<aptos_coin::AptosCoin>(account, investment.investorAddress, interest);
          table::remove(&mut investment_holder.investment, i);
        }
      };
      i = i + 1
    };
  }

  public entry fun revertInvestment(account: &signer, investmentID: u64) acquires Investments, Deals {
    let signer_address = signer::address_of(account);

    assert!(exists<Investments>(signer_address), E_NOT_INITIALIZED);
    assert!(exists<Deals>(signer_address), E_NOT_INITIALIZED);

    assert_admin(account);

    let investment_holder = borrow_global_mut<Investments>(signer_address);
    let deal_holder = borrow_global_mut<Deals>(signer_address);

    assert!(table::contains(&investment_holder.investment, investmentID), E_NO_CORRESPONDING_DEAL);
    let investment = table::borrow(&investment_holder.investment, investmentID);

    assert!(investment.amountInvested > 0, E_AMOUNT_EXCEEDS_TARGET);
    let deal = table::borrow(&deal_holder.deal, investment.dealID);

    // assert!(deal.freezingPeriodStartTimestamp > timestamp::now_microseconds(), E_DEAL_FREEZED);

    aptos_account::transfer_coins<aptos_coin::AptosCoin>(account, investment.investorAddress, investment.amountInvested);

    table::remove(&mut investment_holder.investment, investmentID);
  }

  public entry fun dealStartApproval(account: &signer, dealID: u64, approved: bool) acquires Deals, Investments {
    let signer_address = signer::address_of(account);

    assert!(exists<Deals>(signer_address), E_NOT_INITIALIZED);
    assert!(exists<Investments>(signer_address), E_NOT_INITIALIZED);

    assert_admin(account);

    let deal_holder = borrow_global_mut<Deals>(signer_address);

    assert!(table::contains(&deal_holder.deal, dealID), E_NO_CORRESPONDING_DEAL);
    let deal = table::borrow_mut(&mut deal_holder.deal, dealID);

    if (deal.amountRaised == deal.targetRaiseAmount || approved) {
        aptos_account::transfer_coins<aptos_coin::AptosCoin>(account, deal.companyAddress, deal.amountRaised);
    } else {
        deal.dealMaturityTimestamp = deal.freezingPeriodStartTimestamp;
        deal.promisedInterestRate = 0;
        transferAllBackPerDeal(account, dealID);
        // transferNFT(account, deal.companyAddress, false, deal.tokenNFTID);
    }
  }

}
