/// This module provides an implementation of an NFT lottery.
module marketplace::lottery_nft_pro {
    use std::bcs;
    use std::fixed_point32::{Self, FixedPoint32};
    use std::hash::sha3_256;
    use std::option::{Self, Option};
    use std::signer;
    use std::string::String;
    use std::vector;

    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp::now_seconds;
    use aptos_framework::block;
    use aptos_std::table::{Self, Table};
    use aptos_token::token::{Self, Token};

    use marketplace::payment::pay_out;

    /// Errors
    const ECOIN_NOT_INITIALIZED: u64 = 1000;
    const ENO_TOKENS_PROVIDED: u64 = 1001;
    const EFEE_TOO_HIGH: u64 = 1002;
    const EROYALTY_TOO_HIGH: u64 = 1003;
    const EPOOL_CANCELED: u64 = 1004;
    const EBUY_AMOUNT_TOO_LOW: u64 = 1005;
    const ECLOSE_AT_TOO_EARLY: u64 = 1006;
    const ENO_SHARES: u64 = 1007;
    const EPOOL_CLOSED: u64 = 1008;
    const EPLAYER_CAPACITY_REACHED: u64 = 1009;
    const EALREADY_PLAYING: u64 = 1010;
    const ETOO_MANY_PLAYERS: u64 = 1011;
    const EVALUE_TOO_HIGH: u64 = 1012;
    const EPOOL_NOT_CLOSED: u64 = 1013;
    const EPOOLS_NOT_EXISTS: u64 = 1014;
    const EPOOL_NOT_EXISTS: u64 = 1015;

    struct Pools<phantom CoinType> has key {
        pools: Table<String, Pool<CoinType>>,
    }

    struct Pool<phantom CoinType> has store {
        creator: address,
        tokens: vector<Token>,
        players: vector<address>,
        max_players: u64,
        close_at: u64,
        last_hash: u64,
        share_num: u64,
        all_bids: Option<Coin<CoinType>>,
        fee_recipient: address,
        royalty_recipient: address,
        fee_amount: FixedPoint32,
        royalty_amount: FixedPoint32,
    }

    public fun new_pool<CoinType>(
        creator: &signer,
        pool_name: String,
        tokens: vector<Token>,
        max_players: u64,
        close_at: u64,
        share_num: u64,
        fee_recipient: address,
        royalty_recipient: address,
        fee_amount_numerator: u64,
        fee_amount_denominator: u64,
        royalty_amount_numerator: u64,
        royalty_amount_denominator: u64,
    ) acquires Pools {
        assert!(coin::is_coin_initialized<CoinType>(), ECOIN_NOT_INITIALIZED);
        assert!(vector::length(&tokens) > 0, ENO_TOKENS_PROVIDED);
        assert!(close_at > now_seconds(), ECLOSE_AT_TOO_EARLY);
        assert!(share_num > 0, ENO_SHARES);
            
        assert!(fee_amount_numerator < fee_amount_denominator, EFEE_TOO_HIGH);
        assert!(royalty_amount_numerator < royalty_amount_denominator, EROYALTY_TOO_HIGH);
        if (!exists<Pools<CoinType>>(signer::address_of(creator))) {
            move_to(creator, Pools<CoinType> {
                pools: table::new<String, Pool<CoinType>>(),
            })
        };

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
            tokens,
            players: vector::empty(),
            max_players,
            close_at,
            last_hash: 0,
            share_num,
            all_bids: option::none(),
            fee_recipient,
            royalty_recipient,
            fee_amount,
            royalty_amount,
        };
        let pools = borrow_global_mut<Pools<CoinType>>(signer::address_of(creator));
        table::add(&mut pools.pools, pool_name, pool);
    }

    public fun bet<CoinType>(
        player: &signer,
        pool_creator: address,
        pool_name: String,
        bid_amount: u64,
    ) acquires Pools {
        assert!(bid_amount > 0, EBUY_AMOUNT_TOO_LOW);

        assert!(exists<Pools<CoinType>>(pool_creator), EPOOLS_NOT_EXISTS);
        let pools = &mut borrow_global_mut<Pools<CoinType>>(pool_creator).pools;
        assert!(table::contains(pools, pool_name), EPOOL_NOT_EXISTS);
        let pool = table::borrow_mut(pools, pool_name);
        let now = now_seconds();
        assert!(now < pool.close_at, EPOOL_CLOSED);

        assert!(vector::length(&pool.players) < pool.max_players, EPLAYER_CAPACITY_REACHED);
        let player_address = signer::address_of(player);
        assert!(!vector::contains(&pool.players, &player_address), EALREADY_PLAYING);

        let bid = coin::withdraw(player, bid_amount);
        if (option::is_some(&pool.all_bids)) {
            let all_bids = option::extract(&mut pool.all_bids);
            coin::merge(&mut all_bids, bid);
            option::fill(&mut pool.all_bids, all_bids);
        } else {
            option::fill(&mut pool.all_bids, bid);
        };

        vector::push_back(&mut pool.players, player_address);
        pool.last_hash = hash(&pool.last_hash);
    }

    public fun claim_owner<CoinType>(
        creator: &signer,
        pool_name: String,
    ) acquires Pools {
        assert!(exists<Pools<CoinType>>(signer::address_of(creator)), EPOOLS_NOT_EXISTS);
        let pools = &mut borrow_global_mut<Pools<CoinType>>(signer::address_of(creator)).pools;
        assert!(table::contains(pools, pool_name), EPOOL_NOT_EXISTS);
        let pool = table::borrow_mut(pools, pool_name);

        assert!(vector::length(&pool.players) < pool.share_num, ETOO_MANY_PLAYERS);

        // Deposit all tokens in the pool to the creator address.
        while (vector::length(&pool.tokens) > 0) {
            token::deposit_token(creator, vector::pop_back(&mut pool.tokens));
        }
    }

    public fun claim<CoinType>(
        player: &signer,
        pool_creator: address,
        pool_name: String,
    ) acquires Pools {
        assert!(exists<Pools<CoinType>>(pool_creator), EPOOLS_NOT_EXISTS);
        let pools = &mut borrow_global_mut<Pools<CoinType>>(pool_creator).pools;
        assert!(table::contains(pools, pool_name), EPOOL_NOT_EXISTS);
        let pool = table::borrow_mut(pools, pool_name);

        assert!(vector::contains(&pool.players, &signer::address_of(player)), EALREADY_PLAYING);

        if (is_winner(signer::address_of(player), pool)) {
            // Deposit a single token to the player address.
            token::deposit_token(player, vector::pop_back(&mut pool.tokens));
        };

        // The first claimer also gets all of the bids.
        if (option::is_some(&pool.all_bids)) {
            let all_bids = option::extract(&mut pool.all_bids);
            pay_out<CoinType>(
                signer::address_of(player), 
                pool.fee_recipient, 
                pool.royalty_recipient, 
                pool.fee_amount, 
                pool.royalty_amount, 
                all_bids
            );
        };
    }

    public fun lo2(value: u64): u64 {
        assert!(value < 65536, EVALUE_TOO_HIGH);

        if (value <= 2) {
            return 0
        } else if (value == 3) {
            return 2
        };

        let x = 0u64;
        let s = value;

        while (value > 1) {
            value = value >> 1;
            x = x + 1;
        };

        if (s > ((2 << ((x - 1) as u8)) + (2 << ((x - 2) as u8)))) {
            return x * 2 + 1
        };

        x * 2
    }

    public fun calc_ret(index: u64, m: u64): u64 {
        let p = vector<u64>[3, 3, 5, 7, 17, 11, 7, 11, 13, 23, 31, 47, 61, 89, 127, 191, 251, 383, 
            509, 761, 1021, 1531, 2039, 3067, 4093, 6143, 8191, 12281, 16381, 24571, 32749, 49139];
        let n_sel = lo2(m);
        (index * vector::remove(&mut p, n_sel)) % m
    }

    public fun is_winner<CoinType>(
        sender: address, 
        pool: &Pool<CoinType>,
    ): bool {
        let now = now_seconds();
        assert!(pool.close_at <= now, EPOOL_NOT_CLOSED);

        if (!vector::contains(&pool.players, &sender)) {
            return false
        };

        let player_amount = vector::length(&pool.players);
        if (player_amount <= pool.share_num) {
            return true
        };

        let pool_ext_index = pool.last_hash % player_amount;
        let pos = calc_ret(get_player_index(&pool.players, &sender) - 1, player_amount);
        if (pool_ext_index + pool.share_num % player_amount > pool_ext_index) {
            if (pos >= pool_ext_index && pos < (pool_ext_index + pool.share_num)) {
                return true
            };
        } else {
            if (pos >= pool_ext_index && pos < player_amount) {
                return true
            };

            if (pos < pool_ext_index + pool.share_num % player_amount) {
                return true
            };
        };

        false
    }

    fun get_player_index(players: &vector<address>, player: &address): u64 {
        let index = 0u64;
        let len = vector::length(players);
        while (index < len) {
            if (vector::borrow(players, index) == player) {
                return index
            };
            index = index + 1;
        };
        0
    }

    /// NOTE: this isn't true to the Bounce method, since we can't get most of the
    /// required fields.
    fun hash(last_hash: &u64): u64 {
        let now = now_seconds();
        let block_height = block::get_current_block_height();
        let data = bcs::to_bytes(&now);
        vector::append(&mut data, bcs::to_bytes(&block_height));
        vector::append(&mut data, bcs::to_bytes(last_hash));
        let hash = sha3_256(data);
        (vector::pop_back(&mut hash) as u64) + ((vector::pop_back(&mut hash) << 8) as u64)
            + ((vector::pop_back(&mut hash) << 16) as u64) + ((vector::pop_back(&mut hash) << 24) as u64) 
            + ((vector::pop_back(&mut hash) << 32) as u64) + ((vector::pop_back(&mut hash) << 40) as u64) 
            + ((vector::pop_back(&mut hash) << 48) as u64) + ((vector::pop_back(&mut hash) << 56) as u64)
    }
}
