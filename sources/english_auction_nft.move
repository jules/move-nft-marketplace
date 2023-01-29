/// This module provides an implementation of an English auction for NFTs,
/// with an option for a fixed end time.
module marketplace::english_auction_nft {
    use std::fixed_point32::{Self, FixedPoint32};
    use std::option::{Self, Option};
    use std::signer;
    use std::string::String;

    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp::now_seconds;
    use aptos_std::table::{Self, Table};
    use aptos_token::token::{Self, Token};

    use marketplace::payment::pay_out;

    /// Errors
    const ECOIN_NOT_INITIALIZED: u64 = 1000;
    const EMIN_PRICE_ZERO: u64 = 1001;
    const EMIN_INCREASE_ZERO: u64 = 1002;
    const ECONFIRM_TIME_OUT_OF_BOUNDS: u64 = 1003;
    const EPOOL_NOT_OPEN: u64 = 1004;
    const EBIDDER_NOT_CURRENT_BIDDER: u64 = 1005;
    const EFEE_TOO_HIGH: u64 = 1006;
    const EROYALTY_TOO_HIGH: u64 = 1007;
    const EBUY_AMOUNT_TOO_LOW: u64 = 1008;
    const EPOOL_CLOSED: u64 = 1009;
    const EPOOL_NOT_CLOSED: u64 = 1010;
    const EPOOLS_NOT_EXISTS: u64 = 1011;
    const EPOOL_NOT_EXISTS: u64 = 1012;

    struct Pools<phantom CoinType> has key {
        pools: Table<String, Pool<CoinType>>,
    }

    struct Pool<phantom CoinType> has store {
        creator: address,
        sell_token: Option<Token>,
        min_amount: u64,
        min_increase: u64,
        fixed_end: bool,
        confirm_time: u64,
        open_at: u64,
        close_at: u64,
        current_bidder: address,
        current_bid: Option<Coin<CoinType>>,
        coin_recipient: address,
        fee_recipient: address,
        royalty_recipient: address,
        fee_amount: FixedPoint32,
        royalty_amount: FixedPoint32,
    }

    /// Create a new pool.
    public fun new_pool<CoinType>(
        creator: &signer, 
        name: String, 
        sell_token: Token, 
        min_amount: u64, 
        min_increase: u64, 
        fixed_end: bool,
        confirm_time: u64, 
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
        assert!(min_amount > 0, EMIN_PRICE_ZERO);
        assert!(min_increase > 0, EMIN_INCREASE_ZERO);
        // Confirm time should be greater than or equal to 5 minutes and
        // less than or equal to 1 day.
        assert!(confirm_time >= 60 * 5 && confirm_time <= 60 * 60 * 24, ECONFIRM_TIME_OUT_OF_BOUNDS);
        assert!(fee_amount_numerator < fee_amount_denominator, EFEE_TOO_HIGH);
        assert!(royalty_amount_numerator < royalty_amount_denominator, EROYALTY_TOO_HIGH);
        if (!exists<Pools<CoinType>>(signer::address_of(creator))) {
            move_to(creator, Pools { pools: table::new<String, Pool<CoinType>>() });
        };

        let close_at = open_at + confirm_time;
        let fee_amount = fixed_point32::create_from_rational(
            fee_amount_numerator, 
            fee_amount_denominator
        );
        let royalty_amount = fixed_point32::create_from_rational(
            royalty_amount_numerator, 
            royalty_amount_denominator
        );
        let pool = Pool {
            creator: signer::address_of(creator),
            sell_token: option::some(sell_token),
            min_amount,
            min_increase,
            fixed_end,
            confirm_time,
            open_at,
            close_at,
            current_bidder: signer::address_of(creator),
            current_bid: option::none(),
            coin_recipient,
            fee_recipient,
            royalty_recipient,
            fee_amount,
            royalty_amount,
        };
        let pools = &mut borrow_global_mut<Pools<CoinType>>(signer::address_of(creator)).pools;
        table::add(pools, name, pool);
    }

    /// Place a bid on the token.
    /// Only works if the auction is still open.
    public fun bid<CoinType>(
        bidder: &signer,
        pool_creator: address,
        pool_name: String,
        bid_amount: u64,
    ) acquires Pools {
        assert!(exists<Pools<CoinType>>(pool_creator), EPOOLS_NOT_EXISTS);
        let pools = &mut borrow_global_mut<Pools<CoinType>>(pool_creator).pools;
        assert!(table::contains(pools, pool_name), EPOOL_NOT_EXISTS);
        let pool = table::borrow_mut(pools, pool_name);
        assert!(bid_amount > pool.min_amount, EBUY_AMOUNT_TOO_LOW);
        let now = now_seconds();
        assert!(now >= pool.open_at, EPOOL_NOT_OPEN);
        assert!(now < pool.close_at, EPOOL_CLOSED);

        let coin = coin::withdraw(bidder, bid_amount);
        if (option::is_some(&pool.current_bid)) {
            let current_value = coin::value(option::borrow(&pool.current_bid));
            assert!(bid_amount > current_value, EBUY_AMOUNT_TOO_LOW);
            let old_bid = option::swap(&mut pool.current_bid, coin); 

            // Return the bid to the original bidder.
            coin::deposit(pool.current_bidder, old_bid);
            pool.current_bidder = signer::address_of(bidder);
        } else {
            option::fill(&mut pool.current_bid, coin);
            pool.current_bidder = signer::address_of(bidder);
        };

        if (!pool.fixed_end) {
            // Bump auction close time.
            pool.close_at = now + pool.confirm_time;
        }
    }

    /// Claim the token from the auction.
    /// Only works if the auction has closed, and the caller is the winning bidder.
    public fun bidder_claim<CoinType>(
        bidder: &signer,
        pool_creator: address,
        pool_name: String,
    ) acquires Pools {
        assert!(exists<Pools<CoinType>>(pool_creator), EPOOLS_NOT_EXISTS);
        let pools = &mut borrow_global_mut<Pools<CoinType>>(pool_creator).pools;
        assert!(table::contains(pools, pool_name), EPOOL_NOT_EXISTS);
        let pool = table::borrow_mut(pools, pool_name);
        assert!(signer::address_of(bidder) == pool.current_bidder, EBIDDER_NOT_CURRENT_BIDDER);

        // Ensure auction is closed.
        assert!(now_seconds() >= pool.close_at, EPOOL_NOT_CLOSED);

        if (option::is_some(&pool.current_bid)) {
            pay_out(
                pool.coin_recipient, 
                pool.fee_recipient, 
                pool.royalty_recipient, 
                pool.fee_amount, 
                pool.royalty_amount, 
                option::extract(&mut pool.current_bid)
            );
        };

        // Send the NFT to the winning bidder.
        let sell_token = option::extract(&mut pool.sell_token);
        token::deposit_token(bidder, sell_token);

        // Take and destroy pool.
        let pool = table::remove(pools, pool_name);
        destroy(pool);
    }

    /// Withdraw the coins from the auction, if the auction has closed.
    /// Only the auction creator can call this function.
    public fun creator_claim<CoinType>(
        creator: &signer,
        pool_name: String,
    ) acquires Pools {
        let pool_creator = signer::address_of(creator);
        assert!(exists<Pools<CoinType>>(pool_creator), EPOOLS_NOT_EXISTS);
        let pools = &mut borrow_global_mut<Pools<CoinType>>(pool_creator).pools;
        assert!(table::contains(pools, pool_name), EPOOL_NOT_EXISTS);
        let pool = table::borrow_mut(pools, pool_name);
        assert!(now_seconds() >= pool.close_at, EPOOL_NOT_CLOSED);

        if (option::is_some(&pool.current_bid)) {
            pay_out<CoinType>(
                pool_creator, 
                pool.fee_recipient, 
                pool.royalty_recipient, 
                pool.fee_amount, 
                pool.royalty_amount, 
                option::extract(&mut pool.current_bid)
            );
        } else {
            // Return the NFT to the creator.
            let sell_token = option::extract(&mut pool.sell_token);
            token::deposit_token(creator, sell_token);

            // Take and destroy pool.
            let pool = table::remove(pools, pool_name);
            destroy(pool);
        };
    }

    /// Destroy a pool.
    fun destroy<CoinType>(
        pool: Pool<CoinType>,
    ) {
        let Pool {
            creator: _,
            sell_token: sell_token,
            min_amount: _,
            min_increase: _,
            fixed_end: _,
            confirm_time: _,
            open_at: _,
            close_at: _,
            current_bidder: _,
            current_bid: current_bid,
            coin_recipient: _,
            fee_recipient: _,
            royalty_recipient: _,
            fee_amount: _,
            royalty_amount: _,
        } = pool;
        option::destroy_none(current_bid);
        option::destroy_none(sell_token);
    }
}
