//! A module that is used to record liquidity mining rewards.

module aries::profile_farm {
    use std::option;
    use std::vector;
    use aptos_std::type_info::{TypeInfo};
    use aptos_std::math128;

    use aries::reserve_farm::{Self, Reward as ReserveReward};
    use decimal::decimal::{Self, Decimal};
    use util_types::map::{Self, Map};
    use util_types::iterable_table::{Self, IterableTable};

    friend aries::profile;

    /// When there is no reward entry for a coin type in the profile farm
    const EPROFILE_FARM_REWARD_NOT_FOUND: u64 = 2;

    /// When trying to remove more share than existing
    const EPROFILE_FARM_NEGATIVE_SHARE: u64 = 3;

    /// Struct to support distributing rewards.
    /// Each `ProfileFarm` corresponds to *one* deposit or borrow positions.
    struct ProfileFarm has store {
        /// The total number of shares that is in the farm.
        /// This can be used to represent various different things,
        /// such as token staked, borrow amount, etc. Furthermore,
        /// you can also using some sort of heuristics to provide bonus
        /// share.
        /// 
        /// TODO: need to use Decimal? As we already use it for deposit & borrow shares
        share: u128,
        /// All the rewards that the farm is distributing.
        rewards: IterableTable<TypeInfo, Reward>,
    }

    struct Reward has store, drop {
        /// The amount of the reward that is yet to be claimed.
        unclaimed_amount: Decimal,
        /// The reward per share.
        last_reward_per_share: Decimal,
    }

    struct ProfileFarmRaw has copy, drop, store {
        share: u128,
        reward_type: vector<TypeInfo>,
        rewards: vector<RewardRaw>,
    }

    struct RewardRaw has copy, store, drop {
        unclaimed_amount_decimal: u128,
        last_reward_per_share_decimal: u128,
    }

    /// Create initial snapshot of the latest reserve rewards
    public fun new(
        reserve_rewards: &Map<TypeInfo, ReserveReward>
    ): ProfileFarm {
        let profile_farm = ProfileFarm {
            share: 0,
            rewards: iterable_table::new()
        };
        
        let key = map::head_key(reserve_rewards);
        while (option::is_some(&key)) {
            let type_info = option::destroy_some(key);
            let (reserve_reward, _, next) = map::borrow_iter(reserve_rewards, type_info);
            let current_reward_per_share = reserve_farm::reward_per_share(reserve_reward);
            iterable_table::add(
                &mut profile_farm.rewards, 
                type_info, 
                new_reward(current_reward_per_share)
            );
            key = next;
        };

        profile_farm
    }

    public fun new_reward(init_reward_per_share: Decimal): Reward {
        Reward {
            unclaimed_amount: decimal::zero(),
            last_reward_per_share: init_reward_per_share,
        }
    }

    public fun has_reward(farm: &ProfileFarm, type_info: TypeInfo): bool {
        iterable_table::contains(&farm.rewards, type_info)
    }

    public fun get_share(
        profile_farm: &ProfileFarm,
    ): u128 {
        profile_farm.share
    }
    
    public fun get_reward_balance(
        profile_farm: &ProfileFarm,
        type_info: TypeInfo
    ): Decimal {
        if (!has_reward(profile_farm, type_info)) {
            decimal::zero()
        } else {
            let reward = iterable_table::borrow(&profile_farm.rewards, type_info);
            reward.unclaimed_amount
        }
    }

    public fun get_reward_detail(
        profile_farm: &ProfileFarm,
        type_info: TypeInfo
    ): (Decimal, Decimal) {
        if (!has_reward(profile_farm, type_info)) {
            (decimal::zero(), decimal::zero())
        } else {
            let reward = iterable_table::borrow(&profile_farm.rewards, type_info);
            (reward.unclaimed_amount, reward.last_reward_per_share)
        }
    }

    public fun get_claimable_amount(
        profile_farm: &ProfileFarm,
        type_info: TypeInfo
    ): u64 {
        let balance = get_reward_balance(profile_farm, type_info);
        decimal::floor_u64(balance)
    }

    // Reserve farm needs to be updated and the profile farm needs to have all the `RewardRecord`s.
    public fun update(
        profile_farm: &mut ProfileFarm,
        reserve_rewards: &Map<TypeInfo, ReserveReward>
    ) {
        let key = map::head_key(reserve_rewards);
        while (option::is_some(&key)) {
            let type_info = option::destroy_some(key);
            let (reserve_reward, _, next) = map::borrow_iter(reserve_rewards, type_info);
            let current_reward_per_share = reserve_farm::reward_per_share(reserve_reward);

            // Because we assume each update of this profile farm depends on the latest reserve rewards' states,
            // when this default value is used, it means there are new reward types added to the reserve after 
            // last update of this profile. The profile farm should obtain rewards in this period. 
            // And since the reserve's reward is insert-only and monotonically increasing, we could safely assume its previous
            // reward_per_share for this reward type was 0.
            // For this reward type, it is equivalent to invoking this update once the new reward has been added
            let reward = iterable_table::borrow_mut_with_default(
                &mut profile_farm.rewards, 
                type_info,
                new_reward(decimal::zero())
            );
            let diff = decimal::sub(
                current_reward_per_share,
                reward.last_reward_per_share
            );
            let new_unclaimed_amount = decimal::mul_u128(diff, profile_farm.share);
            // Otherwise the profile even cannot obtain any rewards under frequent update.
            reward.unclaimed_amount = decimal::add(reward.unclaimed_amount, new_unclaimed_amount);
            reward.last_reward_per_share = current_reward_per_share;
            key = next;
        }
    }

    /// Clear the `unclaimed_amount` and return the amount that is to be claimed.
    public fun claim_reward(
        profile_farm: &mut ProfileFarm,
        reserve_rewards: &Map<TypeInfo, ReserveReward>,
        reward_type: TypeInfo
    ): u64 {
        // The order of the next two lines is important.
        // It prevents false aborts. A case this could happen is if a reward is not yet
        // present in the profile_farm, but it will be added during update.
        update(profile_farm, reserve_rewards);
        assert!(has_reward(profile_farm, reward_type), EPROFILE_FARM_REWARD_NOT_FOUND);

        let reward = iterable_table::borrow_mut(
            &mut profile_farm.rewards,
            reward_type
        );
        let claimed_reward = decimal::floor_u64(reward.unclaimed_amount);
        reward.unclaimed_amount = decimal::sub(reward.unclaimed_amount, decimal::from_u64(claimed_reward));

        claimed_reward
    }

    /// Add shares to the profile farm, and keep its 
    /// reward types up to date with reserve rewards.
    public fun add_share(
        profile_farm: &mut ProfileFarm, 
        reserve_rewards: &Map<TypeInfo, ReserveReward>,
        amount: u128
    ) {
        update(profile_farm, reserve_rewards);
        profile_farm.share = profile_farm.share + amount;
    }

    /// Returns actually removed shares
    public fun try_remove_share(
        profile_farm: &mut ProfileFarm, 
        reserve_rewards: &Map<TypeInfo, ReserveReward>,
        amount: u128
    ): u128 {
        update(profile_farm, reserve_rewards);
        let removed_share = math128::min(amount, profile_farm.share);
        profile_farm.share = profile_farm.share - removed_share;
        removed_share
    }

    public fun get_all_claimable_rewards(profile_farm: &ProfileFarm): Map<TypeInfo, u64> {
        let res = map::new();
        aggregate_all_claimable_rewards(profile_farm, &mut res);
        res
    }

    /// Aggregate all claimable rewards amount
    /// claimable_rewards is a map of `Reward Coin Type` to `Claimable Reward Amount`
    public fun aggregate_all_claimable_rewards(profile_farm: &ProfileFarm, claimable_rewards: &mut Map<TypeInfo, u64>) {
        let reward_key = iterable_table::head_key(&profile_farm.rewards);
        while (option::is_some(&reward_key)) {
            let reward_type = *option::borrow(&reward_key);
            let reward_amount = get_claimable_amount(profile_farm, reward_type);
            if (map::contains(claimable_rewards, reward_type)) {
                reward_amount = reward_amount + map::get(claimable_rewards, reward_type);
                map::upsert(claimable_rewards, reward_type, reward_amount);
            } else {
                map::add(claimable_rewards, reward_type, reward_amount);
            };

            let (_, _, next)= iterable_table::borrow_iter(&profile_farm.rewards, reward_type);
            reward_key = next;
        };
    }

    public fun profile_farm_raw(profile_farm: &ProfileFarm): ProfileFarmRaw {
        let raw = ProfileFarmRaw {
            share: profile_farm.share,
            reward_type: vector::empty(),
            rewards: vector::empty(),
        };
        let reward_key = iterable_table::head_key(&profile_farm.rewards);
        while (option::is_some(&reward_key)) {
            let reward_type = *option::borrow(&reward_key);
            let (reward, _, next)= iterable_table::borrow_iter(&profile_farm.rewards, reward_type);

            vector::push_back(&mut raw.reward_type, reward_type);
            vector::push_back(&mut raw.rewards, RewardRaw {
                unclaimed_amount_decimal: decimal::raw(reward.unclaimed_amount),
                last_reward_per_share_decimal: decimal::raw(reward.last_reward_per_share),
            });

            reward_key = next;
        };

        raw
    }

    public fun profile_farm_reward_raw(profile_farm: &ProfileFarm, reward_type: TypeInfo): RewardRaw {
        if (iterable_table::contains(&profile_farm.rewards, reward_type)) {
            let reward = iterable_table::borrow(&profile_farm.rewards, reward_type);
            RewardRaw {
                unclaimed_amount_decimal: decimal::raw(reward.unclaimed_amount),
                last_reward_per_share_decimal: decimal::raw(reward.last_reward_per_share),
            }
        } else {
            RewardRaw {
                unclaimed_amount_decimal: 0,
                last_reward_per_share_decimal: 0,
            }
        }
    }


    public(friend) fun accumulate_profile_farm_raw(
        profile_farm: &mut ProfileFarmRaw, 
        reserve_rewards: &Map<TypeInfo, ReserveReward>
    ) {
        let (reward_idx, reward_len) = (0, vector::length(&profile_farm.reward_type));
        while (reward_idx < reward_len) {
            let reward_type = vector::borrow(&profile_farm.reward_type, reward_idx);
            let reward = vector::borrow_mut(&mut profile_farm.rewards, reward_idx);

            if (!map::contains(reserve_rewards, *reward_type)) {
                continue
            };

            let reserve_reward = map::borrow(reserve_rewards, *reward_type);
            accumulate_profile_reward_raw(reward, profile_farm.share, reserve_farm::reward_per_share(reserve_reward));
            reward_idx = reward_idx + 1;
        };
    }

    public(friend) fun accumulate_profile_reward_raw(farm_reward: &mut RewardRaw, farm_share: u128, current_reward_per_share: Decimal) {
        let diff = decimal::sub(
            current_reward_per_share,
            decimal::from_scaled_val(farm_reward.last_reward_per_share_decimal),
        );
        let new_unclaimed_amount = decimal::mul_u128(diff, farm_share);
        // Otherwise the profile even cannot obtain any rewards under frequent update.
        farm_reward.unclaimed_amount_decimal = decimal::raw(
            decimal::add(
                decimal::from_scaled_val(farm_reward.unclaimed_amount_decimal), 
                new_unclaimed_amount
            )
        );
    }

    public fun unwrap_profile_farm_raw(farm_raw: ProfileFarmRaw): (u128, vector<TypeInfo>, vector<RewardRaw>) {
        let ProfileFarmRaw {share, reward_type, rewards} = farm_raw;
        (share, reward_type, rewards)
    }

    public fun unwrap_profile_reward_raw(reward: RewardRaw): (u128, u128) {
        let RewardRaw { unclaimed_amount_decimal, last_reward_per_share_decimal } = reward;
        (unclaimed_amount_decimal, last_reward_per_share_decimal)
    }
}