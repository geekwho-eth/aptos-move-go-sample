module aries::fa_to_coin_wrapper {
    use std::signer;
    use std::string;
    use std::vector;

    use aptos_std::math64;

    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::coin::{Self, Coin, MintCapability, BurnCapability, FreezeCapability};
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::object::{Object};
    use std::option::{Self};
    use aptos_framework::primary_fungible_store;

    friend aries::controller;

    /// Admin mismatch.
    const EADMIN_MISMATCH: u64 = 1;
    /// WrapperCoinInfo has already exist.
    const EWRAPPER_COIN_INFO_ALREADY_EXIST: u64 = 2;
    /// WrapperCoinInfo does not exist.
    const EWRAPPER_COIN_INFO_DOES_NOT_EXIST: u64 = 3;
    /// WrapperCoinInfo does not exist.
    const EFA_SIGNER_DOES_NOT_EXIST: u64 = 4;
    /// FA amount and Coin amount doesn't match.
    const EAMOUNT_MISMATCH: u64 = 5;

    struct WrappedUSDT {}

    /// We create a resource account to be the FA signer. 
    struct FASigner has key, store {
        addr: address,
        cap: SignerCapability,
    }

    /// The paired Coin for a given FA.
    struct WrapperCoinInfo<phantom WCoin> has key {
        /// Mint capability for LP Coin.
        mint_capability: MintCapability<WCoin>,
        /// Burn capability for LP Coin.
        burn_capability: BurnCapability<WCoin>,
        /// Freeze capability for LP Coin.
        freeze_capability: FreezeCapability<WCoin>,
        /// The amount of FA that is currently in store.
        metadata: Object<Metadata>,
        /// The amount of FA that is currently held by the contract.
        fa_amount: u64,
    }

    public(friend) fun init(account: &signer) {
        assert!(!exists<FASigner>(signer::address_of(account)), EWRAPPER_COIN_INFO_ALREADY_EXIST);
        assert!(signer::address_of(account) == @aries, EADMIN_MISMATCH);

        let (fa_signer, cap) = account::create_resource_account(
            account, b"FASigner");
        move_to(account, FASigner {
            addr: signer::address_of(&fa_signer),
            cap
        })
    }

    public(friend) fun add_fa<WCoin>(account: &signer, metadata: Object<Metadata>) acquires FASigner {
        assert!(exists<FASigner>(signer::address_of(account)), EFA_SIGNER_DOES_NOT_EXIST);
        assert!(signer::address_of(account) == @aries, EADMIN_MISMATCH);
        assert!(!exists<WrapperCoinInfo<WCoin>>(signer::address_of(account)), EWRAPPER_COIN_INFO_ALREADY_EXIST);
        // Wrapping is only needed when the FA doesn't have a corresponding `Coin`.
        assert!(option::is_none(&coin::paired_coin(metadata)), EWRAPPER_COIN_INFO_ALREADY_EXIST);
        let wrapper = borrow_global_mut<FASigner>(@aries);
        let (symbol, name) = make_symbol_and_name_for_wrapped_coin(metadata);

        let (burn_capability, freeze_capability, mint_capability) = coin::initialize<WCoin>(
            account,
            name,
            symbol,
            fungible_asset::decimals(metadata),
            true
        );

        primary_fungible_store::ensure_primary_store_exists(wrapper.addr, metadata);

        move_to(
            account,
            WrapperCoinInfo<WCoin> {
                mint_capability,
                burn_capability,
                freeze_capability,
                metadata,
                fa_amount: 0,
            }
        );        
    }

    public fun fa_to_coin<WCoin>(account: &signer, amount: u64): Coin<WCoin> acquires WrapperCoinInfo, FASigner {
        assert!(exists<FASigner>(@aries), EFA_SIGNER_DOES_NOT_EXIST);
        assert!(exists<WrapperCoinInfo<WCoin>>(@aries), EWRAPPER_COIN_INFO_DOES_NOT_EXIST);

        let fa_signer = borrow_global_mut<FASigner>(@aries);
        let wrapper = borrow_global_mut<WrapperCoinInfo<WCoin>>(@aries);

        let coin_supply = coin::supply<WCoin>();
        if (option::is_some(&coin_supply)) {
            assert!(*option::borrow(&coin_supply) <= (wrapper.fa_amount as u128), EAMOUNT_MISMATCH);
        };
        wrapper.fa_amount = wrapper.fa_amount + amount;
        primary_fungible_store::transfer(account, wrapper.metadata, fa_signer.addr, amount);
        coin::mint<WCoin>(amount, &wrapper.mint_capability)
    }

    public fun coin_to_fa<WCoin>(wrapped_coin: Coin<WCoin>, account: &signer) acquires WrapperCoinInfo, FASigner {
        assert!(exists<FASigner>(@aries), EFA_SIGNER_DOES_NOT_EXIST);
        assert!(exists<WrapperCoinInfo<WCoin>>(@aries), EWRAPPER_COIN_INFO_DOES_NOT_EXIST);
        
        let fa_signer = borrow_global_mut<FASigner>(@aries);
        let wrapper = borrow_global_mut<WrapperCoinInfo<WCoin>>(@aries);
        let coin_supply = coin::supply<WCoin>();
        let amount = coin::value<WCoin>(&wrapped_coin);
        if (option::is_some(&coin_supply)) {
            assert!(*option::borrow(&coin_supply) <= (wrapper.fa_amount as u128), EAMOUNT_MISMATCH);
        };
        wrapper.fa_amount = wrapper.fa_amount - amount;
        primary_fungible_store::transfer(&account::create_signer_with_capability(&fa_signer.cap), wrapper.metadata, signer::address_of(account), amount);
        coin::burn(wrapped_coin, &wrapper.burn_capability);
    }

    #[view]
    public fun is_fa_wrapped_coin<WCoin>(): bool {
        exists<WrapperCoinInfo<WCoin>>(@aries)
    }

    #[view]
    public fun wrapped_amount<WCoin>(): u64 acquires WrapperCoinInfo {
        assert!(exists<WrapperCoinInfo<WCoin>>(@aries), EWRAPPER_COIN_INFO_DOES_NOT_EXIST);
        borrow_global<WrapperCoinInfo<WCoin>>(@aries).fa_amount
    }

    /// Creates the symbol and name for the wrapped coin from FA.
    fun make_symbol_and_name_for_wrapped_coin(metadata: Object<Metadata>): (string::String, string::String) {
        let symbol0 = fungible_asset::symbol(metadata);
        let symbol = vector::empty();
        vector::append(&mut symbol, b"AW");
        vector::append(&mut symbol, *string::bytes(&symbol0));
        let symbol_str = string::utf8(symbol);

        let name0 = fungible_asset::name(metadata);
        let name = b"Aries Wrapped ";
        vector::append(&mut name, *string::bytes(&name0));
        let name_str = string::utf8(name);

        (
            // Token symbol should be shorter than 10 chars
            string::sub_string(&symbol_str, 0, math64::min(string::length(&symbol_str), 10)), 
            // Token name should be shorter than 32 chars
            string::sub_string(&name_str, 0, math64::min(string::length(&name_str), 32))
        )
    }
}
