//! Some utility functions to reduce coding efforts
module aries::utils {
    use std::signer;
    use aptos_std::type_info;

    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::account;

    public fun deposit_coin<Coin0>(
        recipient: &signer,
        coin: Coin<Coin0>
    ) {
        let addr = signer::address_of(recipient);
        if (!coin::is_account_registered<Coin0>(addr)) {
            coin::register<Coin0>(recipient);
        };
        coin::deposit(addr, coin);
    }

    public fun burn_coin<Coin0>(
        coin: Coin<Coin0>,
        burn_cap: &coin::BurnCapability<Coin0>,
    ) {
        if (coin::value(&coin) == 0) {
            // aptos framework cannot burn zero coin
            coin::destroy_zero(coin);
        } else {
            coin::burn(coin, burn_cap);
        }
    }

    public fun can_receive_coin<Coin0>(addr: address): bool {
        account::exists_at(addr) &&
        coin::is_account_registered<Coin0>(addr)
    }

    public fun type_eq<T, U>(): bool {
        type_info::type_of<T>() == type_info::type_of<U>()
    }
}
