/// This module provides a convenient wrapper over the Token module
/// which allows one to mint and drop an NFT directly.
module marketplace::airdrop_nft {
    use aptos_token::token::{Self, TokenDataId, TokenId};

    /// Convenience function to mint and drop an NFT to a recipient.
    public fun mint_to(
        minter: &signer,
        token_data_id: TokenDataId,
        amount: u64,
        recipient: address,
    ): TokenId {
        let token_id = token::mint_token(minter, token_data_id, amount);
        token::transfer(minter, token_id, recipient, amount);
        token_id
    }

    #[test_only]
    use std::signer;
    #[test_only]
    use marketplace::testing::{create_token_data_id, launch_nft};

    #[test(minter = @0x1d8, recipient = @0x1d9)]
    fun mint_test(minter: signer, recipient: signer) {
        launch_nft(&minter, 1);
        let token_data_id = create_token_data_id(signer::address_of(&minter));
        let token_id = mint_to(&minter, token_data_id, 1, signer::address_of(&recipient));
        assert!(token::balance_of(signer::address_of(&recipient), token_id) == 1, 0);
    }
}
