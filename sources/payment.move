/// This module implements three-way payment between a receiver, a fee recepient,
/// and a royalty recipient.
module marketplace::payment {
    use std::fixed_point32::{Self, FixedPoint32};

    use aptos_framework::coin::{Self, Coin};

    // Deposit the bid, fee and royalty into the correct accounts.
    public fun pay_out<CoinType>(
        pool_creator: address,
        fee_recipient: address,
        royalty_recipient: address,
        fee_amount: FixedPoint32,
        royalty_amount: FixedPoint32,
        payment: Coin<CoinType>,
    ) {
        let fee_payment_value = fixed_point32::multiply_u64(coin::value(&payment), fee_amount);
        let royalty_payment_value = fixed_point32::multiply_u64(coin::value(&payment), royalty_amount);
        let fee_payment = coin::extract(&mut payment, fee_payment_value);
        let royalty_payment = coin::extract(&mut payment, royalty_payment_value);
        coin::deposit(pool_creator, payment);
        coin::deposit(fee_recipient, fee_payment);
        coin::deposit(royalty_recipient, royalty_payment);
    }
}
