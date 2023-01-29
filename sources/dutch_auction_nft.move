/// This module provides an implementation of a dutch auction for NFTs.
module marketplace::dutch_auction_nft {
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
    const EAUCTION_NOT_OPEN: u64 = 1001;
    const EFEE_TOO_HIGH: u64 = 1002;
    const EROYALTY_TOO_HIGH: u64 = 1003;
    const EBUY_AMOUNT_TOO_LOW: u64 = 1004;
    const EAUCTIONS_NOT_EXISTS: u64 = 1005;
    const EAUCTION_NOT_EXISTS: u64 = 1006;
    const ESTARTING_PRICE_HIGHER_THAN_RESERVE_PRICE: u64 = 1007;
    const EEND_TIME_BEFORE_START_TIME: u64 = 1008;
    const ETOKENS_LEFT_IN_AUCTION: u64 = 1009;

    struct DutchAuctions<phantom CoinType> has key {
        auctions: Table<String, DutchAuction<CoinType>>,
    }

    struct DutchAuction<phantom CoinType> has store {
        creator: address,
        starting_price: u64,
        reserve_price: u64,
        start_at: u64,
        end_at: u64,
        coin_recipient: address,
        fee_recipient: address,
        royalty_recipient: address,
        fee_amount: FixedPoint32,
        royalty_amount: FixedPoint32,
        tokens: vector<Token>,
    }

    // Creates a new dutch auction.
    public fun new_dutch_auction<CoinType>(
        creator: &signer,
        name: String,
        starting_price: u64,
        reserve_price: u64,
        start_at: u64,
        end_at: u64,
        coin_recipient: address,
        fee_recipient: address,
        royalty_recipient: address,
        fee_amount_numerator: u64,
        fee_amount_denominator: u64,
        royalty_amount_numerator: u64,
        royalty_amount_denominator: u64,
        tokens: vector<Token>,
    ) acquires DutchAuctions {
        assert!(coin::is_coin_initialized<CoinType>(), ECOIN_NOT_INITIALIZED);
        assert!(starting_price > reserve_price, ESTARTING_PRICE_HIGHER_THAN_RESERVE_PRICE);
        assert!(end_at > start_at, EEND_TIME_BEFORE_START_TIME);
        assert!(fee_amount_numerator < fee_amount_denominator, EFEE_TOO_HIGH);
        assert!(royalty_amount_numerator < royalty_amount_denominator, EROYALTY_TOO_HIGH);
        if (!exists<DutchAuctions<CoinType>>(signer::address_of(creator))) {
            move_to(creator, DutchAuctions { auctions: table::new<String, DutchAuction<CoinType>>() });
        };

        let fee_amount = fixed_point32::create_from_rational(
            fee_amount_numerator, 
            fee_amount_denominator
        );
        let royalty_amount = fixed_point32::create_from_rational(
            royalty_amount_numerator, 
            royalty_amount_denominator
        );
        let dutch_auction = DutchAuction {
            creator: signer::address_of(creator),
            starting_price,
            reserve_price,
            start_at,
            end_at,
            coin_recipient,
            fee_recipient,
            royalty_recipient,
            fee_amount,
            royalty_amount,
            tokens
        };
        let auctions = &mut borrow_global_mut<DutchAuctions<CoinType>>(
            signer::address_of(creator)
        ).auctions;
        table::add(auctions, name, dutch_auction);
    }

    public fun mint<CoinType>(
        buyer: &signer,
        auction_name: String, 
        auction_creator: address, 
        payment_amount: u64, 
        count: u64
    ) acquires DutchAuctions {
        assert!(count > 0, EBUY_AMOUNT_TOO_LOW);

        assert!(exists<DutchAuctions<CoinType>>(auction_creator), EAUCTIONS_NOT_EXISTS);
        let auctions = &mut borrow_global_mut<DutchAuctions<CoinType>>(auction_creator).auctions;
        assert!(table::contains(auctions, auction_name), EAUCTION_NOT_EXISTS);
        let dutch_auction = table::borrow_mut(auctions, auction_name);

        // We specifically request that at least 1 second has passed
        // to avoid potential divisions by zero.
        assert!(dutch_auction.start_at < now_seconds(), EAUCTION_NOT_OPEN);

        assert!(payment_amount >= get_price(
                dutch_auction.starting_price, 
                dutch_auction.reserve_price, 
                dutch_auction.start_at,
                dutch_auction.end_at
            ) * count, EBUY_AMOUNT_TOO_LOW
        );

        pay_out<CoinType>(
            dutch_auction.coin_recipient, 
            dutch_auction.fee_recipient, 
            dutch_auction.royalty_recipient, 
            dutch_auction.fee_amount, 
            dutch_auction.royalty_amount, 
            coin::withdraw(buyer, payment_amount)
        );

        // Send NFTs.
        let i = 0;
        while (i < count) {
            let token = vector::pop_back(&mut dutch_auction.tokens);
            token::deposit_token(buyer, token);
            i = i + 1;
        };
    }

    public fun destroy<CoinType>(destroyer: &signer, auction_name: String) acquires DutchAuctions {
        assert!(exists<DutchAuctions<CoinType>>(signer::address_of(destroyer)), EAUCTIONS_NOT_EXISTS);
        let auctions = &mut borrow_global_mut<DutchAuctions<CoinType>>(
            signer::address_of(destroyer)
        ).auctions;
        assert!(table::contains(auctions, auction_name), EAUCTION_NOT_EXISTS);
        let dutch_auction = table::remove(auctions, auction_name);

        assert!(vector::is_empty(&dutch_auction.tokens), ETOKENS_LEFT_IN_AUCTION);
        let DutchAuction {
            creator: _,
            starting_price: _,
            reserve_price: _,
            start_at: _,
            end_at: _,
            coin_recipient: _,
            fee_recipient: _,
            royalty_recipient: _,
            fee_amount: _,
            royalty_amount: _,
            tokens: tokens,
        } = dutch_auction;
        vector::destroy_empty(tokens);
    }

    public fun get_price(
        starting_price: u64, 
        reserve_price: u64, 
        start_at: u64,
        end_at: u64
    ): u64 {
        if (now_seconds() >= end_at) {
            return reserve_price
        };

        let time_elapsed = now_seconds() - start_at;
        let rate_of_decrease = fixed_point32::create_from_rational(
            starting_price - reserve_price, 
            end_at - start_at
        );
        starting_price - fixed_point32::multiply_u64(time_elapsed, rate_of_decrease)
    }
}
