/// This module provides and implementation of a swap protocol for NFTs.
module marketplace::swap_nft {
    use std::fixed_point32::{Self, FixedPoint32};
    use std::signer;
    use std::string::String;
    use std::vector;

    use aptos_framework::coin;
    use aptos_framework::timestamp::now_seconds;
    use aptos_std::table::{Self, Table};
    use aptos_token::token::{Self, Token};

    use marketplace::payment::pay_out;

    /// Errors
    const ECOIN_NOT_INITIALIZED: u64 = 1000;
    const ENO_TOKENS_PROVIDED: u64 = 1001;
    const EPRICE_IS_ZERO: u64 = 1002;
    const EFEE_TOO_HIGH: u64 = 1003;
    const EROYALTY_TOO_HIGH: u64 = 1004;
    const EPOOL_NOT_OPEN: u64 = 1005;
    const EPOOL_CANCELED: u64 = 1006;
    const EBUY_AMOUNT_TOO_LOW: u64 = 1007;
    const EALL_TOKENS_SOLD: u64 = 1008;
    const ENOT_ENOUGH_TOKENS_LEFT: u64 = 1009;
    const EPOOLS_NOT_EXISTS: u64 = 1010;
    const EPOOL_NOT_EXISTS: u64 = 1011;

    struct Pools<phantom CoinType> has key {
        pools: Table<String, Pool<CoinType>>,
    }

    struct Pool<phantom CoinType> has store {
        creator: address,
        sell_tokens: vector<Token>,
        price: u64,
        open_at: u64,
        canceled: bool,
        coin_recipient: address,
        fee_recipient: address,
        royalty_recipient: address,
        fee_amount: FixedPoint32,
        royalty_amount: FixedPoint32,
    }

    public fun new_pool<CoinType>(
        creator: &signer,
        pool_name: String,
        sell_tokens: vector<Token>,
        price: u64,
        open_at: u64,
        coin_recipient: address,
        fee_recipient: address,
        royalty_recipient: address,
        fee_amount_numerator: u64,
        fee_amount_denominator: u64,
        royalty_amount_numerator: u64,
        royalty_amount_denominator: u64,
    ) acquires Pools {
        assert!(coin::is_coin_initialized<CoinType>(), ECOIN_NOT_INITIALIZED);
        assert!(vector::length(&sell_tokens) > 0, ENO_TOKENS_PROVIDED);
        assert!(price > 0, EPRICE_IS_ZERO);
        assert!(fee_amount_numerator < fee_amount_denominator, EFEE_TOO_HIGH);
        assert!(royalty_amount_numerator < royalty_amount_denominator, EROYALTY_TOO_HIGH);
        if (!exists<Pools<CoinType>>(signer::address_of(creator))) {
            move_to(creator, Pools { pools: table::new<String, Pool<CoinType>>() });
        };

        let fee_amount = fixed_point32::create_from_rational(
            fee_amount_numerator, 
            fee_amount_denominator
        );
        let royalty_amount = fixed_point32::create_from_rational(
            royalty_amount_numerator, 
            royalty_amount_denominator
        );
        let pool = Pool<CoinType> {
            creator: signer::address_of(creator),
            sell_tokens,
            price,
            open_at,
            canceled: false,
            coin_recipient,
            fee_recipient,
            royalty_recipient,
            fee_amount,
            royalty_amount,
        };
        let pools = &mut borrow_global_mut<Pools<CoinType>>(signer::address_of(creator)).pools;
        table::add(pools, pool_name, pool);
    }

    public fun swap<CoinType>(
        buyer: &signer,
        pool_name: String,
        pool_creator: address,
        buy_amount: u64,
    ) acquires Pools {
        assert!(exists<Pools<CoinType>>(pool_creator), EPOOLS_NOT_EXISTS);
        let pools = &mut borrow_global_mut<Pools<CoinType>>(pool_creator).pools;
        assert!(table::contains(pools, pool_name), EPOOL_NOT_EXISTS);
        let pool = table::borrow_mut(pools, pool_name);
        assert!(now_seconds() >= pool.open_at, EPOOL_NOT_OPEN);
        assert!(!pool.canceled, EPOOL_CANCELED);
        assert!(buy_amount >= pool.price, EBUY_AMOUNT_TOO_LOW);
        assert!(vector::length(&pool.sell_tokens) > 0, EALL_TOKENS_SOLD);

        let amount_of_tokens = buy_amount / pool.price;
        assert!(amount_of_tokens <= vector::length(&pool.sell_tokens), ENOT_ENOUGH_TOKENS_LEFT);
        assert!(amount_of_tokens > 0, EBUY_AMOUNT_TOO_LOW);

        pay_out<CoinType>(
            pool.coin_recipient,
            pool.fee_recipient, 
            pool.royalty_recipient, 
            pool.fee_amount, 
            pool.royalty_amount, 
            coin::withdraw(buyer, buy_amount)
        );

        let i = 0;
        while (i < amount_of_tokens) {
            token::deposit_token(buyer, vector::pop_back(&mut pool.sell_tokens));
            i = i + 1;
        };
    }

    public fun cancel<CoinType>(
        creator: &signer,
        pool_name: String,
    ) acquires Pools {
        assert!(exists<Pools<CoinType>>(signer::address_of(creator)), EPOOLS_NOT_EXISTS);
        let pools = &mut borrow_global_mut<Pools<CoinType>>(signer::address_of(creator)).pools;
        assert!(table::contains(pools, pool_name), EPOOL_NOT_EXISTS);
        let pool = table::borrow_mut(pools, pool_name);
        assert!(pool.canceled == false, EPOOL_CANCELED);
        pool.canceled = true;

        // Return all tokens back to the creator.
        while (vector::length(&pool.sell_tokens) > 0) {
            token::deposit_token(creator, vector::pop_back(&mut pool.sell_tokens));
        };
    }
}
