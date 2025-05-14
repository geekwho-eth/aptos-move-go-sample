module aries::reward_container {
    use aptos_std::type_info::{Self, TypeInfo};
    use aptos_framework::coin::{Self, Coin};

    use util_types::map::{Self, Map};
    use util_types::pair::{Self, Pair};

    use aries::reserve;

    friend aries::controller;
    #[test_only]
    friend aries::reward_container_tests;

    /// If a RewardContainer of a coin cannot be found
    const EREWARD_CONTAINER_NOT_EXIST: u64 = 1;

    /// If a container has insufficient balance to payout
    const EREWARD_CONTAINER_INSUFFICIENT_BALANCE: u64 = 2;

    /// If try to access an unregistered sub-contianer
    const EREWARD_CONTAINER_NOT_FOUND: u64 = 3;

    /// Holds the rewards of a specific coin for one or more reserves
    struct RewardContainer<phantom CoinType> has key {
        /// Indexed by Reserve's coin type and then Farming Type
        rewards: Map<Pair<TypeInfo, TypeInfo>, Coin<CoinType>>
    }

    /// Init container under lp_store
    public(friend) fun init_container<CoinType>(account: &signer) {
        move_to(
            account,
            RewardContainer<CoinType> {
                rewards: map::new()
            }
        )
    }

    public(friend) fun add_reward<ReserveCoin, FarmingType, RewardCoin>(
        coin: Coin<RewardCoin>,
    ) acquires RewardContainer {
        assert!(exists<RewardContainer<RewardCoin>>(@aries), EREWARD_CONTAINER_NOT_EXIST);
        let reward_container = borrow_global_mut<RewardContainer<RewardCoin>>(@aries);
        let coin_container = borrow_coin_store_mut<RewardCoin>(
            reward_container, 
            reserve::type_info<ReserveCoin>(),
            type_info::type_of<FarmingType>(),
            true
        );
        coin::merge(coin_container, coin);
    }

    /// This function could be used to claim reward by any user that has corresponding share
    /// or remove reward by the admin. The caller should do appropriate access control.
    public(friend) fun remove_reward<ReserveCoin, FarmingType, RewardCoin>(
        amount: u64
    ): Coin<RewardCoin> acquires RewardContainer {
        remove_reward_ti<RewardCoin>(
            reserve::type_info<ReserveCoin>(),
            type_info::type_of<FarmingType>(),
            amount
        )
    }

    public(friend) fun remove_reward_ti<RewardCoin>(
        reserve_type: TypeInfo,
        farming_type: TypeInfo,
        amount: u64,
    ): Coin<RewardCoin> acquires RewardContainer {
        assert!(exists<RewardContainer<RewardCoin>>(@aries), EREWARD_CONTAINER_NOT_EXIST);
        let reward_container = borrow_global_mut<RewardContainer<RewardCoin>>(@aries);
        let coin_container = borrow_coin_store_mut<RewardCoin>(
            reward_container, reserve_type, farming_type, false
        );
        assert!(coin::value(coin_container) >= amount, EREWARD_CONTAINER_INSUFFICIENT_BALANCE);
        coin::extract(coin_container, amount)
    }

    fun borrow_coin_store_mut<RewardCoin>(
        reward_container: &mut RewardContainer<RewardCoin>,
        reserve_type: TypeInfo,
        farming_type: TypeInfo,
        create_if_not_found: bool
    ): &mut Coin<RewardCoin> {
        let key = pair::new(reserve_type, farming_type);
        if (!map::contains(&reward_container.rewards, key)) {
            if (create_if_not_found) {
                map::add(&mut reward_container.rewards, key, coin::zero());
            } else {
                abort(EREWARD_CONTAINER_NOT_FOUND)
            }
        };
        let coin_container = map::borrow_mut(&mut reward_container.rewards, key);
        coin_container
    }

    public fun exists_container<RewardCoin>(): bool {
        exists<RewardContainer<RewardCoin>>(@aries)
    }

    public fun has_reward<
        ReserveCoin, FarmingType, RewardCoin
    >(): bool acquires RewardContainer {
        assert!(exists<RewardContainer<RewardCoin>>(@aries), EREWARD_CONTAINER_NOT_EXIST);
        let reward_container = borrow_global<RewardContainer<RewardCoin>>(@aries);
        let key = pair::new(reserve::type_info<ReserveCoin>(), type_info::type_of<FarmingType>());
        map::contains(&reward_container.rewards, key)
    }

    public fun remaining_reward<
        ReserveCoin, FarmingType, RewardCoin
    >(): u64 acquires RewardContainer {
        assert!(exists<RewardContainer<RewardCoin>>(@aries), EREWARD_CONTAINER_NOT_EXIST);
        let reward_container = borrow_global<RewardContainer<RewardCoin>>(@aries);
        let key = pair::new(reserve::type_info<ReserveCoin>(), type_info::type_of<FarmingType>());
        assert!(map::contains(&reward_container.rewards, key), EREWARD_CONTAINER_NOT_FOUND);
        let coin_container = map::borrow(&reward_container.rewards, key);
        return coin::value(coin_container)
    }
}
