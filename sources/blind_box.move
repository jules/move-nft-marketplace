/// This module provides an implementation of a Blind Box.
module marketplace::blind_box {
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
    const EBLIND_BOX_NOT_OPEN: u64 = 1001;
    const EFEE_TOO_HIGH: u64 = 1002;
    const EROYALTY_TOO_HIGH: u64 = 1003;
    const EBUY_AMOUNT_TOO_LOW: u64 = 1004;
    const EBLIND_BOXES_NOT_EXISTS: u64 = 1005;
    const EBLIND_BOX_NOT_EXISTS: u64 = 1006;
    const EPRICE_IS_ZERO: u64 = 1007;
    const ETOKENS_LEFT_IN_BLIND_BOX: u64 = 1008;

    struct BlindBoxes<phantom CoinType> has key {
        boxes: Table<String, BlindBox<CoinType>>,
    }

    struct BlindBox<phantom CoinType> has store {
        creator: address,
        price: u64,
        mint_at: u64,
        coin_recipient: address,
        fee_recipient: address,
        royalty_recipient: address,
        fee_amount: FixedPoint32,
        royalty_amount: FixedPoint32,
        tokens: vector<Token>,
    }

    // Creates a new blind box.
    public fun new_blind_box<CoinType>(
        creator: &signer,
        name: String,
        price: u64,
        mint_at: u64,
        coin_recipient: address,
        fee_recipient: address,
        royalty_recipient: address,
        fee_amount_numerator: u64,
        fee_amount_denominator: u64,
        royalty_amount_numerator: u64,
        royalty_amount_denominator: u64,
        tokens: vector<Token>,
    ) acquires BlindBoxes {
        assert!(coin::is_coin_initialized<CoinType>(), ECOIN_NOT_INITIALIZED);
        assert!(price > 0, EPRICE_IS_ZERO);
        assert!(fee_amount_numerator < fee_amount_denominator, EFEE_TOO_HIGH);
        assert!(royalty_amount_numerator < royalty_amount_denominator, EROYALTY_TOO_HIGH);
        if (!exists<BlindBoxes<CoinType>>(signer::address_of(creator))) {
            move_to(creator, BlindBoxes { boxes: table::new<String, BlindBox<CoinType>>() });
        };
            
        let fee_amount = fixed_point32::create_from_rational(
            fee_amount_numerator, 
            fee_amount_denominator
        );
        let royalty_amount = fixed_point32::create_from_rational(
            royalty_amount_numerator, 
            royalty_amount_denominator
        );
        let blind_box = BlindBox {
            creator: signer::address_of(creator),
            price,
            mint_at,
            coin_recipient,
            fee_recipient,
            royalty_recipient,
            fee_amount,
            royalty_amount,
            tokens,
        };
        let boxes = &mut borrow_global_mut<BlindBoxes<CoinType>>(signer::address_of(creator)).boxes;
        table::add(boxes, name, blind_box);
    }

    public fun mint<CoinType>(
        buyer: &signer,
        box_name: String, 
        box_creator: address, 
        payment_amount: u64, 
        count: u64
    ) acquires BlindBoxes {
        assert!(count > 0, EBUY_AMOUNT_TOO_LOW);

        assert!(exists<BlindBoxes<CoinType>>(box_creator), EBLIND_BOXES_NOT_EXISTS);
        let boxes = &mut borrow_global_mut<BlindBoxes<CoinType>>(box_creator).boxes;
        assert!(table::contains(boxes, box_name), EBLIND_BOX_NOT_EXISTS);
        let blind_box = table::borrow_mut(boxes, box_name);
        assert!(blind_box.mint_at <= now_seconds(), EBLIND_BOX_NOT_OPEN);

        assert!(payment_amount >= blind_box.price * count, EBUY_AMOUNT_TOO_LOW);
        pay_out<CoinType>(
            blind_box.coin_recipient, 
            blind_box.fee_recipient, 
            blind_box.royalty_recipient, 
            blind_box.fee_amount, 
            blind_box.royalty_amount, 
            coin::withdraw(buyer, payment_amount)
        );

        // Send NFTs.
        let i = 0;
        while (i < count) {
            let token = vector::pop_back(&mut blind_box.tokens);
            token::deposit_token(buyer, token);
            i = i + 1;
        };
    }

    public fun destroy<CoinType>(destroyer: &signer, box_name: String) acquires BlindBoxes {
        assert!(exists<BlindBoxes<CoinType>>(signer::address_of(destroyer)), EBLIND_BOXES_NOT_EXISTS);
        let boxes = &mut borrow_global_mut<BlindBoxes<CoinType>>(signer::address_of(destroyer)).boxes;
        assert!(table::contains(boxes, box_name), EBLIND_BOX_NOT_EXISTS);
        let blind_box = table::remove(boxes, box_name);

        assert!(vector::is_empty(&blind_box.tokens), ETOKENS_LEFT_IN_BLIND_BOX);
        let BlindBox {
            creator: _,
            price: _,
            mint_at: _,
            coin_recipient: _,
            fee_recipient: _,
            royalty_recipient: _,
            fee_amount: _,
            royalty_amount: _,
            tokens: tokens,
        } = blind_box;
        vector::destroy_empty(tokens);
    }
}
