//! Module which handles deposit, withdraw, borrow and repay.
//! Mostly ported from CToken from Compound.
module aries::reserve {
    use std::string::{Self};
    use std::option::{Self, Option};
    use std::vector;
    use std::signer;

    use aptos_std::type_info::{type_of as std_type, TypeInfo};
    use aptos_std::table::{Self, Table};
    use aptos_std::math64;
    
    use aptos_framework::coin::{Self, Coin, MintCapability, BurnCapability, FreezeCapability};

    use decimal::decimal::{Self, Decimal};
    use util_types::map::{Self, Map};
    use util_types::pair::{Self, Pair};

    use aries::borrow_type;
    use aries::controller_config;
    use aries_config::interest_rate_config::{InterestRateConfig};
    use aries::reserve_details::{Self, ReserveDetails};
    use aries_config::reserve_config::{Self, ReserveConfig};
    use aries::reserve_farm::{Self, RewardConfig, Reward, ReserveFarm};
    use aries::math_utils;
    use aries::utils;

    friend aries::controller;
    friend aries::profile;
    
    #[test_only]
    friend aries::test_utils;
    #[test_only]
    friend aries::profile_tests;
    #[test_only]
    friend aries::reserve_tests;
    //
    // Errors.
    //

    /// When there is no collateral that can be remove from this user.
    const ERESERVE_DETAILS_CORRUPTED: u64 = 0;

    /// When `Reserves` struct is not exist.
    const ERESERVE_NOT_EXIST: u64 = 1;

    /// When `Reserves` struct already exist.
    const ERESERVE_ALREADY_EXIST: u64 = 2;

    /// When the deposit limit exceeds.
    const ERESERVE_DEPOSIT_LIMIT_EXCEED: u64 = 3;

    /// When the borrow limit exceeds.
    const ERESERVE_BORROW_LIMIT_EXCEED: u64 = 4;

    /// When this asset is not accepted as collateral.
    const ERESERVE_NOT_ALLOW_AS_COLLATERAL: u64 = 5;

    /// Timestamp should only increase.
    const ERESERVE_TIME_SHOULD_INCREASE: u64 = 6;

    /// When this particular reserve is not exist.
    const ERESERVE_RESERVE_NOT_EXIST: u64 = 7;

    /// When the account is not Aries Markets Account.
    const ERESERVE_NOT_ARIES: u64 = 8;

    /// When a reserve has no matched liquidity farming entry.
    const ERESERVE_FARM_NOT_FOUND: u64 = 9;

    /// When a reserve has no matched liquidity farming entry.
    const ERESERVE_NO_ALLOW_COLLATERAL: u64 = 10;

    /// Represents an LP coin.
    struct LP<phantom Coin> has store { }

    /// Global singelton to store reserve related statistics.
    /// We don't store those statistics in `ReserveCoinContainer` to enable access by `TypeInfo`. 
    struct Reserves has key {
        stats: Table<TypeInfo, ReserveDetails>,
        /// Liquidity Farming keyed by Reserve's Type, and then `FarmingType`.
        farms: Table<Pair<TypeInfo, TypeInfo>, ReserveFarm>,
    }

    /// The struct to hold all the underlying `Coin`s.
    /// Stored as a resources.
    struct ReserveCoinContainer<phantom Coin0> has key {
        /// Stores the available `Coin`.
        underlying_coin: Coin<Coin0>,
        /// Stores the LP `Coin` that act as collateral.
        collateralised_lp_coin: Coin<LP<Coin0>>,
        /// Mint capability for LP Coin.
        mint_capability: MintCapability<LP<Coin0>>,
        /// Burn capability for LP Coin.
        burn_capability: BurnCapability<LP<Coin0>>,
        /// Freeze capability for LP Coin.
        freeze_capability: FreezeCapability<LP<Coin0>>,
        /// Holds the borrow fee from the protocol.
        fee: Coin<Coin0>,
    }

    /// A helper struct to temporarily hold the fee to be distributed
    struct FeeDisbursement<phantom Coin0>{
        coin: Coin<Coin0>,
        receiver: address
    }

    #[event]
    struct MintLPEvent<phantom CoinType> has drop, store {
        amount: u64,
        lp_amount: u64,
    }

    #[event]
    struct RedeemLPEvent<phantom CoinType> has drop, store{
        // redeemed underlying amount without fee
        amount: u64,
        // underlying fee amount
        fee_amount: u64,
        lp_amount: u64,
    }

    #[event]
    struct DistributeBorrowFeeEvent<phantom CoinType> has drop, store {
        // amount that user borrowed without any fee
        actual_borrow_amount: u64,
        platform_fee_amount: u64,
        referrer_fee_amount: u64,
        referrer: Option<address>,
        borrow_type: string::String,
    }

    #[event]
    struct SyncReserveDetailEvent<phantom CoinType> has drop, store {
        total_lp_supply: u128,
        total_cash_available: u128,
        initial_exchange_rate_decimal: u128,
        reserve_amount_decimal: u128,
        total_borrowed_share_decimal: u128,
        total_borrowed_decimal: u128,
        interest_accrue_timestamp: u64,
    }

    #[event]
    struct SyncReserveFarmEvent has drop, store {
        reserve_type: TypeInfo,
        farm_type: TypeInfo,
        farm: reserve_farm::ReserveFarmRaw,
    }

    public(friend) fun init(account: &signer) {
        assert!(signer::address_of(account) == @aries, ERESERVE_NOT_ARIES);
        assert!(!exists<Reserves>(signer::address_of(account)), ERESERVE_ALREADY_EXIST);
        move_to(
            account, 
            Reserves {
                stats: table::new(),
                farms: table::new(),
            }
        );
    }

    #[view]
    public fun reserve_state<CoinType>(): ReserveDetails acquires Reserves {
        reserve_details(std_type<CoinType>())
    }

    #[view]
    public fun reserve_farm<CoinType, FarmingType>(): Option<reserve_farm::ReserveFarmRaw> acquires Reserves {
        let reserves = borrow_global_mut<Reserves>(@aries);
        let reserve_type_info = std_type<CoinType>();
        if (reserve_ref_has_farm(reserves, reserve_type_info, std_type<FarmingType>())) {
            let farm = borrow_reserve_farm(reserves, reserve_type_info, std_type<FarmingType>());
            option::some(reserve_farm::reserve_farm_raw(farm))
        } else {
            option::none()
        }
    }
    
    #[view]
    public fun reserve_farm_map<ReserveType, FarmingType>(): Map<TypeInfo, reserve_farm::Reward> acquires Reserves {
        let reserves = borrow_global_mut<Reserves>(@aries);
        let reserve_type_info = std_type<ReserveType>();
        if (reserve_ref_has_farm(reserves, reserve_type_info, std_type<FarmingType>())) {
            let farm = borrow_reserve_farm(reserves, reserve_type_info, std_type<FarmingType>());
            reserve_farm::get_latest_reserve_farm_view(farm)
        } else {
            map::new()
        }
    }

    #[view]
    /// Return reward detail of specified (Reserve, Farming, RewardCoin)
    /// # Returns
    ///
    /// * `u128`: total share of reward pool
    /// * `u128`: reward per share distributed in decimal(`@aries::decimal::Decimal`)
    /// * `u128`: remaining reward of the pool
    /// * `u128`: reward per day to be distributed(configed in advance)
    public fun reserve_farm_coin<ReserveType, FarmingType, RewardCoin>(): (u128, u128, u128, u128) acquires Reserves {
        let reserves = borrow_global_mut<Reserves>(@aries);
        let reserve_type_info = std_type<ReserveType>();
        if (reserve_ref_has_farm(reserves, reserve_type_info, std_type<FarmingType>())) {
            let farm = borrow_reserve_farm(reserves, reserve_type_info, std_type<FarmingType>());
            let reward = reserve_farm::get_latest_reserve_reward_view(farm, std_type<RewardCoin>());
            (
                reserve_farm::get_share(farm),
                decimal::raw(reserve_farm::reward_per_share(&reward)),
                reserve_farm::remaining_reward(&reward),
                reserve_farm::reward_per_day(&reward)
            )
        } else {
            (0, 0, 0, 0)
        }
    }

    #[test_only]
    public fun has_initiated(): bool {
        exists<Reserves>(@aries)
    }

    public(friend) fun create<Coin0>(
        account: &signer,
        initial_exchange_rate: Decimal,
        reserve_config: ReserveConfig,
        interest_rate_config: InterestRateConfig
    ) acquires Reserves {
        controller_config::assert_is_admin(signer::address_of(account));
        
        let (symbol, name) = make_symbol_and_name_for_lp_token<Coin0>();

        let (burn_capability, freeze_capability, mint_capability) = coin::initialize<LP<Coin0>>(
            account,
            name,
            symbol,
            coin::decimals<Coin0>(),
            true
        );

        move_to(account, ReserveCoinContainer<Coin0> {
            underlying_coin: coin::zero<Coin0>(),
            collateralised_lp_coin: coin::zero<LP<Coin0>>(),
            fee: coin::zero<Coin0>(),
            mint_capability,
            burn_capability,
            freeze_capability,
        });

        update_reserve_details(
            type_info<Coin0>(),
            reserve_details::new_fresh(
                initial_exchange_rate,
                reserve_config,
                interest_rate_config
            )
        );
    }

    // Make a copy of the `ReserveDetails`. It is fine that this function is public, since you can only read.
    public fun reserve_details(reserve_type_info: TypeInfo): ReserveDetails acquires Reserves {
        assert_reserves_exists();
        let reserves = borrow_global<Reserves>(@aries);
        assert!(table::contains(&reserves.stats, reserve_type_info), ERESERVE_RESERVE_NOT_EXIST);
        let reserve_stats = table::borrow<TypeInfo, ReserveDetails>(
            &reserves.stats,
            reserve_type_info,
        );
        *reserve_stats
    }

    fun update_reserve_details(
        reserve_type_info: TypeInfo,
        reserve_details: ReserveDetails
    ) acquires Reserves {
        assert_reserves_exists();
        let reserves = borrow_global_mut<Reserves>(@aries);
        if (table::contains<TypeInfo, ReserveDetails>(&reserves.stats, reserve_type_info)) {
            let val = table::borrow_mut<TypeInfo, ReserveDetails>(
                &mut reserves.stats,
                reserve_type_info,
            );
            *val = reserve_details;
        } else {
            table::add<TypeInfo, ReserveDetails>(
                &mut reserves.stats,
                reserve_type_info,
                reserve_details
            )
        }
    }

    // This is a helper method to set `ReserveDetails` to any arbitrary state to enable testing for interest accumulation.
    #[test_only]
    public fun update_reserve_details_for_testing<Coin0>(reserve_details: ReserveDetails) acquires Reserves {
        update_reserve_details(type_info<Coin0>(), reserve_details);
    }

    public(friend) fun update_reserve_config<Coin0>(reserve_config: ReserveConfig) acquires Reserves {
        let new_reserve_details = reserve_details(type_info<Coin0>());
        reserve_details::update_reserve_config(&mut new_reserve_details, reserve_config);
        update_reserve_details(type_info<Coin0>(), new_reserve_details);
    }

    public(friend) fun update_interest_rate_config<Coin0>(interest_rate_config: InterestRateConfig) acquires Reserves {
        let reserve_details = reserve_details(type_info<Coin0>());
        reserve_details::update_interest_rate_config(&mut reserve_details, interest_rate_config);
        update_reserve_details(type_info<Coin0>(), reserve_details);
    }

    /// The key that is stored in the map.
    public fun type_info<Coin0>(): TypeInfo {
        std_type<Coin0>()
    }

    #[test_only]
    public fun update_reserve_stats_with_mock_borrow<Coin0>(
        details: ReserveDetails,
        borrow_amount: u64, 
        borrow_share_amount: Decimal
    ) acquires Reserves {
        let new_total_borrowed = decimal::add(
            reserve_details::total_borrow_amount(&mut details), 
            decimal::from_u64(borrow_amount)
        );
        let new_total_borrowed_share = decimal::add(
            reserve_details::total_borrowed_share(&mut details), 
            borrow_share_amount
        );

        reserve_details::set_total_borrow_amount(&mut details, new_total_borrowed);
        reserve_details::set_total_borrow_share(&mut details, new_total_borrowed_share);

        update_reserve_details(type_info<Coin0>(), details);
    }

    #[test_only]
    public fun update_reserve_stats_with_mock_reserve_amount<Coin0>(
        details: ReserveDetails, 
        reserve_amount: Decimal,
    ) acquires Reserves {
        reserve_details::set_reserve_amount(&mut details, reserve_amount);
        update_reserve_details(type_info<Coin0>(), details);
    }

    #[test_only]
    public fun total_borrow_amount(reserve_type_info: TypeInfo): Decimal acquires Reserves {
        reserve_details::total_borrow_amount(&mut reserve_details(reserve_type_info))
    }

    #[test_only]
    public fun total_borrow_share(reserve_type_info: TypeInfo): Decimal acquires Reserves {
        reserve_details::total_borrowed_share(&reserve_details(reserve_type_info))
    }

    #[test_only]
    public fun total_cash_available(reserve_type_info: TypeInfo): u128 acquires Reserves {
        reserve_details::total_cash_available(&reserve_details(reserve_type_info))
    }

    #[test_only]
    public fun reserve_amount(reserve_type_info: TypeInfo): Decimal acquires Reserves {
        reserve_details::reserve_amount(&mut reserve_details(reserve_type_info))
    }

    #[test_only]
    public fun reserve_interest_config(reserve_type_info: TypeInfo): InterestRateConfig acquires Reserves {
        reserve_details::interest_rate_config(&reserve_details(reserve_type_info))
    }

    public fun reserve_config(reserve_type_info: TypeInfo): ReserveConfig acquires Reserves {
        reserve_details::reserve_config(&reserve_details(reserve_type_info))
    }

    public fun loan_to_value(reserve_type_info: TypeInfo): u8 acquires Reserves {
        reserve_config::loan_to_value(&reserve_config(reserve_type_info))
    }

    public fun liquidation_threshold(reserve_type_info: TypeInfo): u8 acquires Reserves {
        reserve_config::liquidation_threshold(&reserve_config(reserve_type_info))
    }

    public fun liquidation_bonus_bips(reserve_type_info: TypeInfo): u64 acquires Reserves {
        reserve_config::liquidation_bonus_bips(&reserve_config(reserve_type_info))
    }

    public(friend) fun borrow_factor(reserve_type: TypeInfo): u8 acquires Reserves {
        reserve_config::borrow_factor(&reserve_config(reserve_type))
    }

    public fun get_underlying_amount_from_lp_amount(
        reserve_type_info: TypeInfo,
        lp_amount: u64
    ): u64 acquires Reserves {
        let reserve_details = reserve_details(reserve_type_info);
        reserve_details::get_underlying_amount_from_lp_amount(&mut reserve_details, lp_amount)
    }

    public fun get_lp_amount_from_underlying_amount(
        reserve_type_info: TypeInfo,
        underlying_amount: u64
    ): u64 acquires Reserves {
        let reserve_details = reserve_details(reserve_type_info);
        reserve_details::get_lp_amount_from_underlying_amount(&mut reserve_details, underlying_amount)
    }

    public fun get_borrow_amount_from_share(
        reserve_type_info: TypeInfo,
        share_amount: u64
    ): Decimal acquires Reserves {
        get_borrow_amount_from_share_dec(reserve_type_info, decimal::from_u64(share_amount))
    }

    public fun get_borrow_amount_from_share_dec(
        reserve_type_info: TypeInfo,
        share_amount: Decimal
    ): Decimal acquires Reserves {
        let reserve_details = reserve_details(reserve_type_info);
        reserve_details::get_borrow_amount_from_share_amount(&mut reserve_details, share_amount)
    }

    public fun get_share_amount_from_borrow_amount(
        reserve_type_info: TypeInfo,
        borrow_amount: u64
    ): Decimal acquires Reserves {
        get_share_amount_from_borrow_amount_dec(reserve_type_info, decimal::from_u64(borrow_amount))
    }

    public fun get_share_amount_from_borrow_amount_dec(
        reserve_type_info: TypeInfo,
        borrow_amount: Decimal
    ): Decimal acquires Reserves {
        let reserve_details = reserve_details(reserve_type_info);
        reserve_details::get_share_amount_from_borrow_amount(&mut reserve_details, borrow_amount)
    }

    public fun mint<Coin0> (
        underlying_coin: Coin<Coin0>
    ): Coin<LP<Coin0>> acquires Reserves, ReserveCoinContainer {
        let reserve_details = reserve_details(type_info<Coin0>());

        let reserve_coins = borrow_global_mut<ReserveCoinContainer<Coin0>>(@aries);
        check_stats_integrity<Coin0>(reserve_coins, &reserve_details);

        let amount = coin::value(&underlying_coin);
        let lp_amount = reserve_details::mint(&mut reserve_details, amount);

        update_reserve_details(type_info<Coin0>(), reserve_details);

        // Perform the deposit
        coin::merge(&mut reserve_coins.underlying_coin, underlying_coin);

        // Return minted LP tokens
        let lp_coins = coin::mint<LP<Coin0>>(lp_amount, &reserve_coins.mint_capability);

        aptos_std::event::emit(MintLPEvent<Coin0> {
            amount: amount,
            lp_amount: lp_amount,
        });
        emit_sync_reserve_detail_event<Coin0>(&reserve_details);

        lp_coins
    }

    fun check_stats_integrity<Coin0>(
        reserve_coins: &ReserveCoinContainer<Coin0>,
        details: &ReserveDetails
    ) {
        let total_cash_available = coin::value(&reserve_coins.underlying_coin);
        let total_lp_supply = option::destroy_some(coin::supply<LP<Coin0>>());

        assert!(
            (total_cash_available as u128) == reserve_details::total_cash_available(details),
            ERESERVE_DETAILS_CORRUPTED
        );
        assert!(
            (total_lp_supply as u128) == reserve_details::total_lp_supply(details),
            ERESERVE_DETAILS_CORRUPTED
        );
    }

    public fun redeem<Coin0> (
        lp_coin: Coin<LP<Coin0>>
    ) : Coin<Coin0> acquires Reserves, ReserveCoinContainer {
        let reserve_details = reserve_details(type_info<Coin0>());
        let reserve_coins = borrow_global_mut<ReserveCoinContainer<Coin0>>(@aries);
        check_stats_integrity<Coin0>(reserve_coins, &reserve_details);

        let lp_amount = coin::value(&lp_coin);
        let amount = reserve_details::redeem(
            &mut reserve_details,
            lp_amount,
        );
        update_reserve_details(type_info<Coin0>(), reserve_details);

        // Burn minted LP tokens
        utils::burn_coin<LP<Coin0>>(lp_coin, &reserve_coins.burn_capability);

        // Perform the withdraw, it will fail if there is not enough liquidity.
        let total_withdrawal_coin = coin::extract<Coin0>(&mut reserve_coins.underlying_coin, amount);
        let withdrawal_coin_after_fee = charge_withdrawal_fee(total_withdrawal_coin);

        aptos_std::event::emit(RedeemLPEvent<Coin0> {
            amount: coin::value(&withdrawal_coin_after_fee),
            fee_amount: amount - coin::value(&withdrawal_coin_after_fee),
            lp_amount: lp_amount,
        });

        emit_sync_reserve_detail_event<Coin0>(&reserve_details);

        withdrawal_coin_after_fee
    }

    public(friend) fun add_collateral<Coin0>(
        lp_coin: Coin<LP<Coin0>>
    ) acquires Reserves, ReserveCoinContainer {
        let reserve_type_info = type_info<Coin0>();
        assert!(
            reserve_details::allow_collateral(&reserve_details(reserve_type_info)), 
            ERESERVE_NO_ALLOW_COLLATERAL
        );

        let coins_container = borrow_global_mut<ReserveCoinContainer<Coin0>>(@aries);
        coin::merge<LP<Coin0>>(&mut coins_container.collateralised_lp_coin, lp_coin)
    }

    public(friend) fun remove_collateral<Coin0>(
        amount: u64
    ): Coin<LP<Coin0>> acquires ReserveCoinContainer {
        let coins_container = borrow_global_mut<ReserveCoinContainer<Coin0>>(@aries);
        coin::extract<LP<Coin0>>(&mut coins_container.collateralised_lp_coin, amount)
    }

    /// Can only be called by the `Controller`, this is borrow using collateral.
    public(friend) fun borrow<Coin0>(
        amount: u64,
        maybe_referrer: Option<address>
    ): Coin<Coin0> acquires Reserves, ReserveCoinContainer {
        borrow_internal(amount, borrow_type::normal_borrow_type(), maybe_referrer)
    }

    /// Can only be called by the `Controller`, this is flash loan without using collateral.
    public(friend) fun flash_borrow<Coin0>(
        amount: u64,
        maybe_referrer: Option<address>
    ): Coin<Coin0> acquires Reserves, ReserveCoinContainer {
        borrow_internal(amount, borrow_type::flash_borrow_type(), maybe_referrer)
    }

    public fun calculate_borrow_fee_using_borrow_type(
        type_info: TypeInfo,
        amount: u64,
        borrow_type: u8
    ): u64 acquires Reserves {
        let reserve_details = reserve_details(type_info);
        calculate_fee_amount_from_borrow_type(&reserve_details, amount, borrow_type)
    }

    fun calculate_fee_amount_from_borrow_type(
        reserve_details: &ReserveDetails,
        amount: u64,
        borrow_type: u8
    ): u64 {
        if (borrow_type == borrow_type::normal_borrow_type()) {
            reserve_details::calculate_borrow_fee(reserve_details, amount)
        } else if (borrow_type == borrow_type::flash_borrow_type()) {
            reserve_details::calculate_flash_loan_fee(reserve_details, amount)
        } else {
            abort(0)
        }
    }

    /// We unify the implementation between normal borrow that requires collateral with flash loan that
    /// doesn't requires collateral. The only difference is on the fee that is charged.
    fun borrow_internal<Coin0>(
        amount: u64,
        borrow_type: u8,
        maybe_referrer: Option<address>
    ): Coin<Coin0> acquires Reserves, ReserveCoinContainer {
        let reserve_details = reserve_details(type_info<Coin0>());
        let fee_amount = calculate_fee_amount_from_borrow_type(&reserve_details, amount, borrow_type);
        let borrow_amount_with_fee = amount + fee_amount;
        reserve_details::borrow(&mut reserve_details, borrow_amount_with_fee);
        update_reserve_details(type_info<Coin0>(), reserve_details);

        let coins_container = borrow_global_mut<ReserveCoinContainer<Coin0>>(@aries);

        let fee_coin = coin::extract<Coin0>(&mut coins_container.underlying_coin, fee_amount);
        let loan_coins = coin::extract<Coin0>(&mut coins_container.underlying_coin, amount);
        let (our_fee, maybe_referrer_fee) = distribute_fee_with_referrer(fee_coin, maybe_referrer);

        let platform_fee_amount = coin::value(&our_fee);
        // Deposit into the fee `Coin`.
        coin::merge<Coin0>(&mut coins_container.fee, our_fee);
        let referrer_fee_amount = if (option::is_some(&maybe_referrer_fee)) {
            let FeeDisbursement { coin, receiver } = option::destroy_some(maybe_referrer_fee);
            let fee = coin::value(&coin);
            coin::deposit<Coin0>(receiver, coin);
            fee
        } else {
            option::destroy_none(maybe_referrer_fee);
            0
        };

        aptos_std::event::emit(DistributeBorrowFeeEvent<Coin0> {
            actual_borrow_amount: amount,
            platform_fee_amount: platform_fee_amount,
            referrer_fee_amount: referrer_fee_amount,
            referrer: maybe_referrer,
            borrow_type: borrow_type::borrow_type_str(borrow_type),
        });
        emit_sync_reserve_detail_event<Coin0>(&reserve_details);
        
        loan_coins
    }

    /// Can only be called by the `Controller`, relevant book keeping for user should be done on the caller side.
    /// If the `repaying_coin` is more than the user's debt, the additional part will be returned.
    public(friend) fun repay<Coin0>(
        repaying_coin: Coin<Coin0>
    ): Coin<Coin0> acquires Reserves, ReserveCoinContainer {
        let reserve_details = reserve_details(type_info<Coin0>());
        let max_repay_amount = coin::value<Coin0>(&repaying_coin);
        let (actual_repay_amount, _) = reserve_details::repay(&mut reserve_details, max_repay_amount);
        update_reserve_details(type_info<Coin0>(), reserve_details);

        let coins_container = borrow_global_mut<ReserveCoinContainer<Coin0>>(@aries);
        let remaining_coin = coin::extract<Coin0>(&mut repaying_coin, max_repay_amount - actual_repay_amount);
        coin::merge<Coin0>(&mut coins_container.underlying_coin, repaying_coin);

        emit_sync_reserve_detail_event<Coin0>(&reserve_details);

        remaining_coin
    }

    public(friend) fun withdraw_borrow_fee<Coin0>(): Coin<Coin0> acquires ReserveCoinContainer {
        let coins_container = borrow_global_mut<ReserveCoinContainer<Coin0>>(@aries);
        coin::extract_all<Coin0>(&mut coins_container.fee)
    }

    public(friend) fun withdraw_reserve_fee<Coin0>(): Coin<Coin0> acquires ReserveCoinContainer, Reserves {
        let coins_container = borrow_global_mut<ReserveCoinContainer<Coin0>>(@aries);
        let reserve_details = reserve_details(type_info<Coin0>());
        let reserve_fee_amount = reserve_details::withdraw_reserve_amount(&mut reserve_details);
        update_reserve_details(type_info<Coin0>(), reserve_details);
        coin::extract<Coin0>(&mut coins_container.underlying_coin, reserve_fee_amount)
    }

    public(friend) fun sync_cash_available<Coin0>() acquires ReserveCoinContainer, Reserves {
        let coins_container = borrow_global_mut<ReserveCoinContainer<Coin0>>(@aries);
        let reserve_details = reserve_details(type_info<Coin0>());
        let available_cash = coin::value(&mut coins_container.underlying_coin);
        reserve_details::set_total_cash_available(&mut reserve_details, (available_cash as u128));
        update_reserve_details(type_info<Coin0>(), reserve_details);
    }

    public fun calculate_repay(
        reserve_type_info: TypeInfo,
        borrowed_amount: u64,
        borrowed_share: Decimal
    ): (u64, Decimal) acquires Reserves {
        let reserve_details = reserve_details(reserve_type_info);
        reserve_details::calculate_repay(&mut reserve_details, borrowed_amount, borrowed_share)
    }

    /// Creates the symbol and name of an LP token.
    public fun make_symbol_and_name_for_lp_token<Coin0>(): (string::String, string::String) {
        let symbol0 = coin::symbol<Coin0>();
        let symbol = vector::empty();
        vector::append(&mut symbol, b"A");
        vector::append(&mut symbol, *string::bytes(&symbol0));
        let symbol_str = string::utf8(symbol);

        let name0 = coin::name<Coin0>();
        let name = b"Aries ";
        vector::append(&mut name, *string::bytes(&name0));
        vector::append(&mut name, b" LP Token");
        let name_str = string::utf8(name);

        (
            // Token symbol should be shorter than 10 chars
            string::sub_string(&symbol_str, 0, math64::min(string::length(&symbol_str), 10)), 
            // Token name should be shorter than 32 chars
            string::sub_string(&name_str, 0, math64::min(string::length(&name_str), 32))
        )
    }

    /// Returns 
    /// 1. Fees for ours, 
    /// 2. Fees for the referrer and receiver address 
    ///    (optional, if we can find one account associated with this key and it has registered this coin)
    fun distribute_fee_with_referrer<Coin0>(
        fee_coin: Coin<Coin0>, 
        maybe_referrer: Option<address>
    ): (Coin<Coin0>, Option<FeeDisbursement<Coin0>>) {
        if (option::is_none(&maybe_referrer)
            || !utils::can_receive_coin<Coin0>(*option::borrow(&maybe_referrer))) {
            (fee_coin, option::none())
        } else {
            let referrer = option::destroy_some(maybe_referrer);
            let share_pct = controller_config::find_referral_fee_sharing_percentage(referrer);
            let distribute_fee_amount = math_utils::mul_percentage_u64(
                coin::value(&fee_coin),
                (share_pct as u64)
            );
            let distribute_coins = coin::extract(&mut fee_coin, distribute_fee_amount);
            (
                fee_coin, 
                option::some(FeeDisbursement {
                    coin: distribute_coins,
                    receiver: referrer
                })
            )
        }
    }

    fun assert_reserves_exists() {
        assert!(exists<Reserves>(@aries), ERESERVE_NOT_EXIST);
    }

    public fun reserve_has_farm<FarmingType>(
        reserve_type_info: TypeInfo
    ): bool acquires Reserves {
        let reserves = borrow_global<Reserves>(@aries);
        reserve_ref_has_farm(reserves, reserve_type_info, std_type<FarmingType>())
    }

    /// Whether there is a ReserveFarm given reserve and farming type.
    fun reserve_ref_has_farm(
        reserves: &Reserves,
        reserve_type_info: TypeInfo,
        farming_type_info: TypeInfo
    ): bool {
        let key = pair::new(reserve_type_info, farming_type_info);
        table::contains(&reserves.farms, key)
   }

    fun borrow_reserve_farm(
        reserves: &Reserves,
        reserve_type_info: TypeInfo,
        farming_type_info: TypeInfo
    ): &ReserveFarm {
        assert!(reserve_ref_has_farm(reserves, reserve_type_info, farming_type_info), ERESERVE_FARM_NOT_FOUND);
        let key = pair::new(reserve_type_info, farming_type_info);
        table::borrow(&reserves.farms, key)
    }

    fun borrow_reserve_farm_mut(
        reserves: &mut Reserves,
        reserve_type_info: TypeInfo,
        farming_type_info: TypeInfo
    ): &mut ReserveFarm {
        assert!(reserve_ref_has_farm(reserves, reserve_type_info, farming_type_info), ERESERVE_FARM_NOT_FOUND);
        let key = pair::new(reserve_type_info, farming_type_info);
        table::borrow_mut(&mut reserves.farms, key)
    }

    public fun get_reserve_rewards<FarmingType>(
        reserve_type_info: TypeInfo,
    ): Map<TypeInfo, Reward> acquires Reserves {
        get_reserve_rewards_ti(reserve_type_info, std_type<FarmingType>())
    }
    
    public fun get_reserve_rewards_ti(
        reserve_type_info: TypeInfo,
        farming_type_info: TypeInfo
    ): Map<TypeInfo, Reward> acquires Reserves {
        let reserves = borrow_global_mut<Reserves>(@aries);
        let farm = borrow_reserve_farm_mut(reserves, reserve_type_info, farming_type_info);
        reserve_farm::get_rewards(farm)
    }

    public(friend) fun update_reward_config<
        ReserveCoin, FarmingType, RewardCoin
    >(new_config: RewardConfig) acquires Reserves {
        let reserves = borrow_global_mut<Reserves>(@aries);
        let farm = borrow_reserve_farm_mut(reserves, type_info<ReserveCoin>(), std_type<FarmingType>());
        reserve_farm::update_reward_config(farm, std_type<RewardCoin>(), new_config);
    }

    /// Add reserve liquidity farming reward, and may create a new entry
    public(friend) fun add_reward<
        ReserveCoin, FarmingType, RewardCoin
    >(amount: u64) acquires Reserves {
        let reserves = borrow_global_mut<Reserves>(@aries);
        let key = pair::new(type_info<ReserveCoin>(), std_type<FarmingType>());
        if (!table::contains(&reserves.farms, key)) {
            table::add(&mut reserves.farms, key, reserve_farm::new())
        };
        let farm = table::borrow_mut(&mut reserves.farms, key);
        reserve_farm::add_reward(farm, std_type<RewardCoin>(), (amount as u128));
    }

    public(friend) fun remove_reward<
        ReserveCoin, FarmingType, RewardCoin
    >(amount: u64) acquires Reserves {
        remove_reward_ti(
            type_info<ReserveCoin>(),
            std_type<FarmingType>(),
            std_type<RewardCoin>(),
            amount
        )
    }

    public(friend) fun remove_reward_ti(
        reserve_type_info: TypeInfo,
        farming_type_info: TypeInfo,
        reward_coin_info: TypeInfo,
        amount: u64
    ) acquires Reserves {
        let reserves = borrow_global_mut<Reserves>(@aries);
        let farm = borrow_reserve_farm_mut(reserves, reserve_type_info, farming_type_info);
        reserve_farm::remove_reward(farm, reward_coin_info, (amount as u128));
    }

    /// Acquires and updates on the global storage. 
    /// In production this function should be only called by `profile::try_add_or_init_profile_reward_share`.
    /// So we can ensure the share amount is synced between the reserve and every profile.
    public(friend) fun try_add_reserve_reward_share<FarmingType>(
        reserve_type_info: TypeInfo,
        shares: u128
    ) acquires Reserves {
        let reserves = borrow_global_mut<Reserves>(@aries);
        if (reserve_ref_has_farm(reserves, reserve_type_info, std_type<FarmingType>())) {
            let farm = borrow_reserve_farm_mut(reserves, reserve_type_info, std_type<FarmingType>());
            reserve_farm::add_share(farm, shares);

            aptos_std::event::emit(SyncReserveFarmEvent {
                reserve_type: reserve_type_info,
                farm_type: std_type<FarmingType>(),
                farm: reserve_farm::reserve_farm_raw(farm),
            });
        };
    }

    public(friend) fun try_remove_reserve_reward_share<FarmingType>(
        reserve_type_info: TypeInfo,
        shares: u128
    ) acquires Reserves {
        let reserves = borrow_global_mut<Reserves>(@aries);
        if (reserve_ref_has_farm(reserves, reserve_type_info, std_type<FarmingType>())) {
            let farm = borrow_reserve_farm_mut(reserves, reserve_type_info, std_type<FarmingType>());
            reserve_farm::remove_share(farm, shares);

            aptos_std::event::emit(SyncReserveFarmEvent {
                reserve_type: reserve_type_info,
                farm_type: std_type<FarmingType>(),
                farm: reserve_farm::reserve_farm_raw(farm),
            });
        };
    }

    /// A portion of liquidation bonus will be reserved into the protocol treasury.
    public fun charge_liquidation_fee<Coin0>(
        withdrawal_lp_coin: Coin<LP<Coin0>>
    ): Coin<LP<Coin0>> acquires Reserves, ReserveCoinContainer {
        let reserve_type_info = type_info<Coin0>();
        let liquidation_fee_millionth = reserve_config::liquidation_fee_hundredth_bips(&reserve_config(reserve_type_info));
        let fee_lp_amount = math_utils::mul_millionth_u64(coin::value(&withdrawal_lp_coin), liquidation_fee_millionth);
        let fee_lp_coins = coin::extract(&mut withdrawal_lp_coin, fee_lp_amount);
        let fee_coins = redeem(fee_lp_coins);
        let reserve_coins = borrow_global_mut<ReserveCoinContainer<Coin0>>(@aries); 
        coin::merge(&mut reserve_coins.fee, fee_coins);

        withdrawal_lp_coin
    }

    /// A portion of withdrawn asset will be reserved into the protocol treasury as fee.
    public fun charge_withdrawal_fee<Coin0>(
        withdrawal_coin: Coin<Coin0>
    ): Coin<Coin0> acquires Reserves, ReserveCoinContainer {
        let reserve_type_info = type_info<Coin0>();
        let withdraw_fee_millionth = reserve_config::withdraw_fee_hundredth_bips(&reserve_config(reserve_type_info));
        let fee_amount = math_utils::mul_millionth_u64(coin::value(&withdrawal_coin), withdraw_fee_millionth);
        let fee_coins = coin::extract(&mut withdrawal_coin, fee_amount);
        let reserve_coins = borrow_global_mut<ReserveCoinContainer<Coin0>>(@aries);
        coin::merge(&mut reserve_coins.fee, fee_coins);

        withdrawal_coin
    }

    fun emit_sync_reserve_detail_event<Coin0>(detail: &ReserveDetails) {
        aptos_std::event::emit(SyncReserveDetailEvent<Coin0> {
            total_lp_supply: reserve_details::total_lp_supply(detail),
            total_cash_available: reserve_details::total_cash_available(detail),
            initial_exchange_rate_decimal: decimal::raw(reserve_details::initial_exchange_rate(detail)),
            reserve_amount_decimal: decimal::raw(reserve_details::reserve_amount_raw(detail)),
            total_borrowed_share_decimal: decimal::raw(reserve_details::total_borrowed_share(detail)),
            total_borrowed_decimal: decimal::raw(reserve_details::total_borrowed(detail)),
            interest_accrue_timestamp: reserve_details::interest_accrue_timestamp(detail),
        })
    }

    // Specifications

    use aptos_framework::coin::{CoinInfo};
    use aptos_framework::optional_aggregator;

    spec module {
    }

    spec fun spec_reserve_balance<Coin0>(): num {
        let coin_store = global<ReserveCoinContainer<Coin0>>(@aries);
        coin::value<Coin0>(coin_store.underlying_coin)
    }

    spec fun spec_reserve_lp_supply<Coin0>(): num {
        let maybe_supply = global<CoinInfo<Coin0>>(@aries).supply;
        let supply = option::borrow(maybe_supply);
        optional_aggregator::read(supply)
    }
}