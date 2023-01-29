#[test_only]
module marketplace::testing {
    use std::string;

    use aptos_token::token::{Self, create_collection, TokenDataId};

    public fun launch_nft(
        creator: &signer,
        maximum: u64,
    ) {
        create_collection(
            creator,
            string::utf8(b"TestToken"),
            string::utf8(b"Test"),
            string::utf8(b"TEST"),
            maximum,
            vector<bool>[true, true, true, true, true]
        );
    }

    public fun create_token_data_id(
        creator: address,
    ): TokenDataId {
        token::create_token_data_id(
            creator,
            string::utf8(b"TestToken"),
            string::utf8(b"Test")
        )
    }
}
