module aries::profile {
    use std::option::{Self, Option};
    use std::string::{Self};
    use std::signer;
    use std::vector;

    use aptos_std::type_info::{Self, TypeInfo};
    use aptos_std::simple_map::{Self as ref_map};
    use aptos_std::event::{Self};
    use aptos_std::string_utils;

    use aptos_framework::account;
    
    use aries::reserve::{Self};
    use aries_config::reserve_config::{DepositFarming, BorrowFarming};
    use aries::profile_farm::{Self, ProfileFarm};
    use aries::utils;
    use decimal::decimal::{Self, Decimal};
    use util_types::iterable_table::{Self, IterableTable};
    use util_types::pair::{Self, Pair};
    use oracle::oracle;
    use util_types::map::{Self, Map};
    use aries::emode_category::{Self};

    friend aries::controller;
    #[test_only]
    friend aries::profile_tests;

    //
    // Errors.
    //

    /// When there is no collateral that can be remove from this user.
    const EPROFILE_NO_DEPOSIT_RESERVE: u64 = 0;

    /// When there is not enough collateral LP token that can be removed in the user `Profile`.
    const EPROFILE_NOT_ENOUGH_COLLATERAL: u64 = 1;

    /// When there is no corresponding bororw reserve.
    const EPROFILE_NO_BORROWED_RESERVE: u64 = 2;

    /// When the user already have a profile during creation.
    const EPROFILE_ALREADY_EXIST: u64 = 3;

    /// When the user doesn't have a profile.
    const EPROFILE_NOT_EXIST: u64 = 4;

    /// When the debt exceeds borrowing power.
    const EPROFILE_NEGATIVE_EQUITY: u64 = 5;

    /// When the profile name duplicates.
    const EPROFILE_DUPLICATE_NAME: u64 = 6;

    /// When the profile is healthy and cannot be liquidated.
    const EPROFILE_IS_HEALTHY: u64 = 7;

    /// When the rounded coin/LP coin amount is 0.
    const EPROFILE_ZERO_AMOUNT: u64 = 8;

    /// When trying to repay 0 amount.
    const EPROFILE_REPAY_ZERO_AMOUNT: u64 = 9;

    /// When the FarmingType is not Deposit or Borrow
    const EPROFILE_INVALID_FARMING_TYPE: u64 = 10;

    /// When the emode cateogry of the borrowing reserve is not same as profile.
    const EPROFILE_EMODE_DIFF_WITH_RESERVE: u64 = 11;

    /// Constants

    const LIQUIDATION_CLOSE_AMOUNT: u64 = 2;

    const LIQUIDATION_CLOSE_FACTOR_PERCENTAGE: u128 = 50;

    /// Core data structures

    struct Profiles has key {
        profile_signers: ref_map::SimpleMap<string::String, account::SignerCapability>,
        referrer: Option<address>,
    }

    /// This is a resource that records a user's all deposits and borrows, 
    /// Mainly used for book keeping purpose.
    /// Note that, the key is reserve type info from `reserve::type_info<CoinType>()`.
    struct Profile has key {
        /// All reserves that the user has deposited into.
        deposited_reserves: IterableTable<TypeInfo, Deposit>,
        /// All reserves that the user has deposited into that has deposit farming
        deposit_farms: IterableTable<TypeInfo, ProfileFarm>,
        /// All reserves that the user has borrowed from.
        borrowed_reserves: IterableTable<TypeInfo, Loan>,
        /// All reserves that the user has borrowed from that has borrow farming
        borrow_farms: IterableTable<TypeInfo, ProfileFarm>,
    }

    struct Deposit has store, drop {
        /// The amount of LP tokens that is stored as collateral.
        collateral_amount: u64
    }

    struct Loan has store, drop {
        /// Normalized borrow share amount.
        borrowed_share: Decimal
    }

    /// A hot potato struct to make sure equity is checked for a given `Profile`.
    struct CheckEquity {
        /// The address of the user.
        user_addr: address,
        /// The name of the user's `Profile`.
        profile_name: string::String
    }

    #[event]
    struct SyncProfileDepositEvent has drop, store {
        user_addr: address,
        profile_name: string::String,
        reserve_type: TypeInfo,
        collateral_amount: u64,
        farm: Option<profile_farm::ProfileFarmRaw>,
    }

    #[event]
    struct SyncProfileBorrowEvent has drop, store {
        user_addr: address,
        profile_name: string::String,
        reserve_type: TypeInfo,
        borrowed_share_decimal: u128,
        farm: Option<profile_farm::ProfileFarmRaw>,
    }

    fun move_profiles_to(account: &signer, profiles: Profiles) {
        let addr = signer::address_of(account);
        assert!(!exists<Profiles>(addr), EPROFILE_ALREADY_EXIST);
        move_to(account, profiles);
    }
    
    public fun init(account: &signer) {
        move_profiles_to(
            account,
            Profiles {
                profile_signers: ref_map::create(),
                referrer: option::none(),
            }
        );
    }

    public fun init_with_referrer(account: &signer, referrer: address) {
        move_profiles_to(
            account, 
            Profiles {
                profile_signers: ref_map::create(),
                referrer: option::some(referrer)
            }
        );
    }

    public fun new(account: &signer, profile_name: string::String) acquires Profiles {
        let addr = signer::address_of(account);
        assert!(exists<Profiles>(addr), EPROFILE_NOT_EXIST);
        let profiles = borrow_global_mut<Profiles>(addr);
        let full_profile_name = get_profile_name_str(profile_name);

        assert!(
            !ref_map::contains_key(
                &profiles.profile_signers,
                &full_profile_name
            ),
            EPROFILE_DUPLICATE_NAME
        );

        let (profile_signer, profile_signer_cap) = account::create_resource_account(
            account, *string::bytes(&full_profile_name));

        ref_map::add(
            &mut profiles.profile_signers,
            full_profile_name,
            profile_signer_cap
        );

        move_to(
            &profile_signer,
            Profile {
                deposited_reserves: iterable_table::new(),
                deposit_farms: iterable_table::new(),
                borrowed_reserves: iterable_table::new(),
                borrow_farms: iterable_table::new(),
            }
        )
    }

    #[view]
    public fun is_registered(user_addr: address): bool {
        exists<Profiles>(user_addr)
    }

    #[view]
    public fun profile_exists(user_addr: address, profile_name: string::String): bool acquires Profiles {
        if (is_registered(user_addr)) {
            let profiles = borrow_global<Profiles>(user_addr);
            let registered_name= get_profile_name_str(profile_name);

            if (ref_map::contains_key(&profiles.profile_signers, &registered_name)) {
                true
            } else {
                false
            }
        } else {
            false
        }
    }

    #[view]
    public fun get_profile_address(user_addr: address, profile_name: string::String): address acquires Profiles {
        signer::address_of(&get_profile_account(user_addr, &profile_name))
    }

    #[view]
    public fun get_profile_name_str(profile_name: string::String): string::String {
        let name_str = string::utf8(b"profile");
        string::append(&mut name_str, profile_name);
        name_str
    }

    #[view]
    public fun get_user_referrer(user_addr: address): Option<address> acquires Profiles {
        assert!(exists<Profiles>(user_addr), EPROFILE_NOT_EXIST);
        let profiles = borrow_global<Profiles>(user_addr);
        profiles.referrer
    }

    #[view]
    /// Return profile deposit position of the specified `ReserveType`
    /// return (u64, u64): (collateral_lp_amount, underlying_coin_amount)
    public fun profile_deposit<ReserveType>(user_addr: address, profile_name: string::String): (u64, u64) acquires Profiles, Profile {
        let reserve_type = type_info::type_of<ReserveType>();
        let collateral_amount = get_deposited_amount(user_addr, &profile_name, reserve_type);
        let underlying_amount = reserve::get_underlying_amount_from_lp_amount(reserve_type, collateral_amount);
        (collateral_amount, underlying_amount)
    }

    #[view]
    /// Return profile loan position of the specified `ReserveType`
    /// return (u128, u128): (borrowed_share_decimal, borrowed_amount_decimal)
    public fun profile_loan<ReserveType>(user_addr: address, profile_name: string::String): (u128, u128) acquires Profiles, Profile {
        let profile_account = get_profile_account(user_addr, &profile_name);
        let profile = borrow_global_mut<Profile>(signer::address_of(&profile_account));

        let reserve_type = type_info::type_of<ReserveType>();
        let borrowed_share = if (iterable_table::contains(&profile.borrowed_reserves, reserve_type)) {
            iterable_table::borrow(&profile.borrowed_reserves, reserve_type).borrowed_share
        } else {
            decimal::zero()
        };

        (
            decimal::raw(borrowed_share),
            decimal::raw(reserve::get_borrow_amount_from_share_dec(reserve_type, borrowed_share))
        )
    }

    #[view]
    public fun profile_farm<ReserveType, FarmingType>(user_addr: address, profile_name: string::String): Option<profile_farm::ProfileFarmRaw> acquires Profiles, Profile {
        let profile_account = get_profile_account(user_addr, &profile_name);
        let profile = borrow_global_mut<Profile>(signer::address_of(&profile_account));
        let reserve_type = type_info::type_of<ReserveType>();
        let farming_type = type_info::type_of<FarmingType>();

        let farms = borrow_farms(profile, farming_type);
        if (iterable_table::contains(farms, reserve_type)) {
            let f = iterable_table::borrow(farms, reserve_type);
            let raw = profile_farm::profile_farm_raw(f);
            let reserve_rewards = reserve::reserve_farm_map<ReserveType, FarmingType>();
            profile_farm::accumulate_profile_farm_raw(&mut raw, &reserve_rewards);
            option::some(raw)
        } else {
            option::none()
        }
    }

    #[view]
    /// Return reward detail of specified (Reserve, Farming, RewardCoin)
    /// # Returns
    ///
    /// * `u128`: uncliamed reward amount in decimal(`@aries::decimal::Decimal`)
    /// * `u128`: last reward per share distributed in decimal
    public fun profile_farm_coin<ReserveType, FarmingType, RewardCoin>(user_addr: address, profile_name: string::String): (u128, u128) acquires Profiles, Profile {
        let profile_account = get_profile_account(user_addr, &profile_name);
        let profile = borrow_global_mut<Profile>(signer::address_of(&profile_account));
        let reserve_type = type_info::type_of<ReserveType>();
        let reward_type = type_info::type_of<RewardCoin>();

        let farms = borrow_farms(profile, type_info::type_of<FarmingType>());
        if (iterable_table::contains(farms, reserve_type)) {
            let farm = iterable_table::borrow(farms, reserve_type);
            let raw = profile_farm::profile_farm_reward_raw(farm, reward_type);
            let (_, current_reward_per_share, _, _) = reserve::reserve_farm_coin<ReserveType, FarmingType, RewardCoin>();
            profile_farm::accumulate_profile_reward_raw(
                &mut raw, 
                profile_farm::get_share(farm), 
                decimal::from_scaled_val(current_reward_per_share)
            );
            profile_farm::unwrap_profile_reward_raw(raw)
        } else {
            (0, 0)
        }
    }

    fun get_profile_account(user_addr: address, profile_name: &string::String): signer acquires Profiles {
        assert!(exists<Profiles>(user_addr), EPROFILE_NOT_EXIST);
        let profiles = borrow_global<Profiles>(user_addr);
        let full_profile_name = get_profile_name_str(*profile_name);
        assert!(ref_map::contains_key(&profiles.profile_signers, &full_profile_name), 0);

        let signer_cap = ref_map::borrow(
            &profiles.profile_signers,
            &full_profile_name
        );
        account::create_signer_with_capability(signer_cap)
    }

    /// The total bororwing power assuming no borrow.
    public fun get_total_borrowing_power(addr: address, profile_name: &string::String): Decimal acquires Profiles, Profile {
        let profile_addr = signer::address_of(&get_profile_account(addr, profile_name));
        let profile = borrow_global<Profile>(profile_addr);
        get_total_borrowing_power_from_profile_inner(profile, &emode_category::profile_emode(profile_addr))
    }

    // [Deprecated] use `get_total_borrowing_power_from_profile_inner` instead.
    public fun get_total_borrowing_power_from_profile(profile: &Profile): Decimal {
        get_total_borrowing_power_from_profile_inner(profile, &option::none())
    }

    public(friend) fun get_total_borrowing_power_from_profile_inner(profile: &Profile, profile_emode_id: &Option<string::String>): Decimal {
        let borrowing_power = decimal::zero();
        let key = iterable_table::head_key(&profile.deposited_reserves);
        while (option::is_some(&key)) {
            let type_info = *option::borrow(&key);
            let (val, _, next) = iterable_table::borrow_iter(
                &profile.deposited_reserves, type_info);

            let ltv_pct: u8 = asset_ltv(profile_emode_id, &type_info);
            let ltv = decimal::from_percentage((ltv_pct as u128));

            let price: Decimal = asset_price(profile_emode_id, &type_info);
            let actual_amount = reserve::get_underlying_amount_from_lp_amount(
                type_info,
                val.collateral_amount
            );
            let total_value = decimal::mul(
                decimal::from_u64(actual_amount),
                price
            );

            borrowing_power = decimal::add(
                borrowing_power, 
                decimal::mul(
                    total_value,
                    ltv
                )
            );
            key = next;
        };

        borrowing_power
    }

    // [Deprecated] use `get_liquidation_borrow_value_inner` instead.
    public fun get_liquidation_borrow_value(profile: &Profile): Decimal {
        get_liquidation_borrow_value_inner(profile, &option::none())
    }

    public(friend) fun get_liquidation_borrow_value_inner(profile: &Profile, profile_emode_id: &Option<string::String>): Decimal {
        let maintenance_margin = decimal::zero();
        let key = iterable_table::head_key(&profile.deposited_reserves);
        while (option::is_some(&key)) {
            let type_info = *option::borrow(&key);
            let (val, _, next) = iterable_table::borrow_iter(
                &profile.deposited_reserves, type_info);

            let liquidation_thereshold_pct: u8 = asset_liquidation_threshold(profile_emode_id, &type_info);
            let liquidation_thereshold = decimal::from_percentage((liquidation_thereshold_pct as u128));

            let price: Decimal = asset_price(profile_emode_id, &type_info);
            let actual_amount = reserve::get_underlying_amount_from_lp_amount(
                type_info,
                val.collateral_amount
            );
            let total_value = decimal::mul(
                decimal::from_u64(actual_amount),
                price
            );

            maintenance_margin = decimal::add(
                maintenance_margin,
                decimal::mul(
                    total_value,
                    liquidation_thereshold
                )
            );
            key = next;
        };

        maintenance_margin
    }

    /// Caller needs to ensure the interest is accrued before calling this.
    public fun get_adjusted_borrowed_value(
        user_addr: address, profile_name: &string::String
    ): Decimal acquires Profiles, Profile {
        let profile_addr = signer::address_of(&get_profile_account(user_addr, profile_name));
        let profile = borrow_global<Profile>(profile_addr);
        get_adjusted_borrowed_value_fresh_for_profile(profile, &emode_category::profile_emode(profile_addr))
    }

    /// Get the risk-adjusted borrow value
    ///
    /// This takes into account the `borrow_factor` which is based on an asset's
    /// volatility.
    fun get_adjusted_borrowed_value_fresh_for_profile(profile: &Profile, profile_emode_id: &Option<string::String>): Decimal {
        let total_risk_adjusted_borrow_value = decimal::zero();
        let key = iterable_table::head_key(&profile.borrowed_reserves);
        while (option::is_some(&key)) {
            let type_info = *option::borrow(&key);
            let (val, _, next) = iterable_table::borrow_iter(&profile.borrowed_reserves, type_info);

            let price: Decimal = asset_price(profile_emode_id, &type_info);
            let borrowed_amount = reserve::get_borrow_amount_from_share_dec(type_info, val.borrowed_share);
            let borrow_value = decimal::mul(borrowed_amount, price);
            let borrow_factor_pct = asset_borrow_factor(profile_emode_id, &type_info);
            let risked_ajusted_borrow_value = decimal::div(
                borrow_value, 
                decimal::from_percentage((borrow_factor_pct as u128))
            );

            total_risk_adjusted_borrow_value = decimal::add(
                total_risk_adjusted_borrow_value, 
                risked_ajusted_borrow_value
            );
            key = next;
        };
        total_risk_adjusted_borrow_value
    }


    /// Get the borrowing power that is still available, measured in dollars.
    public fun available_borrowing_power(
        user_addr: address, profile_name: &string::String
    ): Decimal acquires Profiles, Profile {
        let profile_addr = signer::address_of(&get_profile_account(user_addr, profile_name));
        let profile = borrow_global_mut<Profile>(profile_addr);
        let profile_emode = emode_category::profile_emode(profile_addr);

        let total_borrowed_value = get_adjusted_borrowed_value_fresh_for_profile(profile, &profile_emode);
        let total_borrowing_power = get_total_borrowing_power_from_profile_inner(profile, &profile_emode);
        assert!(decimal::gte(total_borrowing_power, total_borrowed_value), EPROFILE_NEGATIVE_EQUITY);
        decimal::sub(total_borrowing_power, total_borrowed_value)
    }

    public(friend) fun read_check_equity_data(check_equity: &CheckEquity): (address, string::String) {
        (check_equity.user_addr, check_equity.profile_name)
    }

    /// Check to see if there is enough collateral after `borrow` and `remove_collateral`.
    public fun check_enough_collateral(check_equity: CheckEquity) acquires Profiles, Profile {
        let CheckEquity {
            user_addr,
            profile_name
        } = check_equity;
        assert!(has_enough_collateral(user_addr, profile_name), EPROFILE_NEGATIVE_EQUITY);
    }

    public fun has_enough_collateral(user_addr: address, profile_name: string::String): bool acquires Profiles, Profile {
        let profile_addr = signer::address_of(&get_profile_account(user_addr, &profile_name));
        let profile = borrow_global_mut<Profile>(profile_addr);
        let profile_emode = emode_category::profile_emode(profile_addr);
        has_enough_collateral_for_profile(profile, &profile_emode)
    }

    public(friend) fun has_enough_collateral_for_profile(profile: &Profile, profile_emode_id: &Option<string::String>): bool {
        let adjusted_borrow_value = get_adjusted_borrowed_value_fresh_for_profile(profile, profile_emode_id);
        let borrowing_power = get_total_borrowing_power_from_profile_inner(profile, profile_emode_id);
        decimal::lte(adjusted_borrow_value, borrowing_power)
    }

    public fun get_deposited_amount(
        user_addr: address,
        profile_name: &string::String,
        reserve_type_info: TypeInfo
    ): u64 acquires Profiles, Profile {
        let profile_account = get_profile_account(user_addr, profile_name);
        let profile = borrow_global_mut<Profile>(signer::address_of(&profile_account));
        if (!iterable_table::contains<TypeInfo, Deposit>(&profile.deposited_reserves, reserve_type_info)) {
            0
        } else {
            let deposited_reserve = iterable_table::borrow<TypeInfo, Deposit>(
                &mut profile.deposited_reserves,
                reserve_type_info
            );
            deposited_reserve.collateral_amount
        }
    }

    public fun get_borrowed_amount(
        user_addr: address,
        profile_name: &string::String,
        reserve_type_info: TypeInfo
    ): Decimal acquires Profiles, Profile {
        let profile_account = get_profile_account(user_addr, profile_name);
        let profile = borrow_global_mut<Profile>(signer::address_of(&profile_account));
        if (!iterable_table::contains<TypeInfo, Loan>(&profile.borrowed_reserves, reserve_type_info)) {
            decimal::zero()
        } else {
            let loan = iterable_table::borrow_mut<TypeInfo, Loan>(
                &mut profile.borrowed_reserves,
                reserve_type_info
            );
            reserve::get_borrow_amount_from_share_dec(reserve_type_info, loan.borrowed_share)
        }
    }

    /// Caller needs to make sure that the LP token is actually transferred.
    public(friend) fun add_collateral(
        user_addr: address,
        profile_name: &string::String,
        reserve_type_info: TypeInfo,
        amount: u64
    ) acquires Profiles, Profile {
        let profile_account = get_profile_account(user_addr, profile_name);
        let profile = borrow_global_mut<Profile>(signer::address_of(&profile_account));
        add_collateral_profile(profile, reserve_type_info, amount);

        emit_deposit_event(user_addr, profile_name, profile, reserve_type_info);
    }

    fun add_collateral_profile(
        profile: &mut Profile,
        reserve_type_info: TypeInfo,
        amount: u64
    ) {
        assert!(amount > 0, EPROFILE_ZERO_AMOUNT);
        assert!(!iterable_table::contains(&profile.borrowed_reserves, reserve_type_info), 0);

        let deposited_reserve = iterable_table::borrow_mut_with_default<TypeInfo, Deposit>(
            &mut profile.deposited_reserves,
            reserve_type_info,
            Deposit {
                collateral_amount: 0
            }
        );
        deposited_reserve.collateral_amount = deposited_reserve.collateral_amount + amount;

        // We keep deposit share the same as collateralized LP coin amount. 
        // Need to be in sync with the amount we record in reserve farming.
        try_add_or_init_profile_reward_share<DepositFarming>(
            profile,
            reserve_type_info,
            (amount as u128)
        );
    }

    public(friend) fun deposit(
        user_addr: address,
        profile_name: &string::String,
        reserve_type_info: TypeInfo,
        amount: u64,
        repay_only: bool
    ): (u64, u64) acquires Profile, Profiles {
        let profile_account = get_profile_account(user_addr, profile_name);
        let profile = borrow_global_mut<Profile>(signer::address_of(&profile_account));
        let (repay_amount, deposit_amount) = deposit_profile(profile, reserve_type_info, amount, repay_only);

        emit_deposit_event(user_addr, profile_name, profile, reserve_type_info);
        (repay_amount, deposit_amount)
    }

    /// Returns the (repay amount, deposit amount)
    /// `repay_only` means that we only repay the debt, if there is no debt we do nothing.
    fun deposit_profile(
        profile: &mut Profile,
        reserve_type_info: TypeInfo,
        amount: u64,
        repay_only: bool,
    ): (u64, u64) {
        let repay_amount = if (iterable_table::contains(&profile.borrowed_reserves, reserve_type_info)) {
            repay_profile(profile, reserve_type_info, amount)
        } else {
            0
        };

        let deposit_amount = if (repay_only || amount <= repay_amount) {
            0
        } else {
            let amount_after_repay = amount - repay_amount;
            let lp_amount = reserve::get_lp_amount_from_underlying_amount(reserve_type_info, amount_after_repay);
            if (lp_amount > 0) {
                add_collateral_profile(profile, reserve_type_info, lp_amount);
                amount_after_repay
            } else {
                // In this case, user will get 0 LP coin and we will not take coins from his wallet.
                0
            }
        };

        (repay_amount, deposit_amount)
    }

    /// Callers will do the actual transfer, this function here is just for book keeping.
    /// We return a struct `CheckEquity` to enforce that health check is enforced on the caller
    /// side to make sure that it is healthy even after `remove_collateral`.
    public(friend) fun remove_collateral(
        user_addr: address,
        profile_name: &string::String,
        reserve_type_info: TypeInfo,
        amount: u64
    ): CheckEquity acquires Profiles, Profile {
        let profile_account = get_profile_account(user_addr, profile_name);
        let profile = borrow_global_mut<Profile>(signer::address_of(&profile_account));
        remove_collateral_profile(profile, reserve_type_info, amount);
        emit_deposit_event(user_addr, profile_name, profile, reserve_type_info);
        CheckEquity {user_addr, profile_name: *profile_name}
    }

    /// Returns: removed reward shares
    fun remove_collateral_profile(
        profile: &mut Profile,
        reserve_type_info: TypeInfo,
        amount: u64
    ): u128 {
        assert!(!iterable_table::contains<TypeInfo, Loan>(&profile.borrowed_reserves, reserve_type_info), EPROFILE_NO_BORROWED_RESERVE);
        assert!(
            iterable_table::contains<TypeInfo, Deposit>(
                &profile.deposited_reserves, reserve_type_info
            ),
            EPROFILE_NO_DEPOSIT_RESERVE
        );
        let deposited_reserve = iterable_table::borrow_mut<TypeInfo, Deposit>(
            &mut profile.deposited_reserves,
            reserve_type_info
        );
        assert!(
            deposited_reserve.collateral_amount >= amount, 
            EPROFILE_NOT_ENOUGH_COLLATERAL
        );
        deposited_reserve.collateral_amount = deposited_reserve.collateral_amount - amount;

        if (deposited_reserve.collateral_amount == 0) {
            iterable_table::remove(
                &mut profile.deposited_reserves, reserve_type_info
            );
        };

        try_subtract_profile_reward_share<DepositFarming>(
            profile,
            reserve_type_info,
            (amount as u128)
        )
    }

    public(friend) fun withdraw(
        user_addr: address,
        profile_name: &string::String,
        reserve_type_info: TypeInfo,
        amount: u64,
        allow_borrow: bool,
    ): (u64, u64, CheckEquity) acquires Profile, Profiles {
        withdraw_internal(user_addr, profile_name, reserve_type_info, amount, allow_borrow, 0)
    }

    public(friend) fun withdraw_flash_loan(
        user_addr: address,
        profile_name: &string::String,
        reserve_type_info: TypeInfo,
        amount: u64,
        allow_borrow: bool,
    ): (u64, u64, CheckEquity) acquires Profile, Profiles {
        withdraw_internal(user_addr, profile_name, reserve_type_info, amount, allow_borrow, 1)
    }

    /// We return a struct hot potato `CheckEquity` to enforce health check after withdraw. The design makes 
    /// it possible to `withdraw`, do some trading on DEXes, then `deposit` and finally use `has_enough_collateral`
    /// to consumes the `CheckEquity`.
    fun withdraw_internal(
        user_addr: address,
        profile_name: &string::String,
        reserve_type_info: TypeInfo,
        amount: u64,
        allow_borrow: bool,
        borrow_type: u8
    ): (u64, u64, CheckEquity) acquires Profile, Profiles {
        let profile_addr = signer::address_of(&get_profile_account(user_addr, profile_name));
        let profile = borrow_global_mut<Profile>(profile_addr);
        let profile_emode = emode_category::profile_emode(profile_addr); 
        let (withdrawal_lp_amount, borrow_amount) = withdraw_profile(
            profile, 
            &profile_emode,
            reserve_type_info, 
            amount, 
            allow_borrow, 
            borrow_type
        );
        emit_borrow_event(user_addr, profile_name, profile, reserve_type_info);
        (withdrawal_lp_amount, borrow_amount, CheckEquity {user_addr, profile_name: *profile_name})
    }

    /// Returns the (withdraw amount in terms of LP tokens, borrow amount).
    /// In the case of u64::max, we do not borrow, just withdraw all.
    fun withdraw_profile(
        profile: &mut Profile,
        profile_emode_id: &Option<string::String>,
        reserve_type_info: TypeInfo,
        amount: u64,
        allow_borrow: bool,
        borrow_type: u8
    ): (u64, u64) {
        let (withdraw_lp_amount, remaining_borrow_amount) = if (iterable_table::contains(&profile.deposited_reserves, reserve_type_info)) {
            let deposited_reserve = iterable_table::borrow_mut<TypeInfo, Deposit>(
                &mut profile.deposited_reserves,
                reserve_type_info
            );
            let deposited_amount = reserve::get_underlying_amount_from_lp_amount(
                reserve_type_info, deposited_reserve.collateral_amount);

            if (deposited_amount >= amount) {
                let lp_amount = reserve::get_lp_amount_from_underlying_amount(reserve_type_info, amount);
                remove_collateral_profile(profile, reserve_type_info, lp_amount);
                (lp_amount, 0)
            } else {
                let lp_amount = deposited_reserve.collateral_amount;
                remove_collateral_profile(profile, reserve_type_info, lp_amount);
                (lp_amount, amount - deposited_amount)
            }
        } else {
            (0, amount)
        };

        if (allow_borrow && remaining_borrow_amount > 0) {
            borrow_profile(profile, profile_emode_id, reserve_type_info, remaining_borrow_amount, borrow_type);
        } else {
            remaining_borrow_amount = 0;
        };

        (withdraw_lp_amount, remaining_borrow_amount)
    }

    public fun max_borrow_amount(
        user_addr: address,
        profile_name: &string::String,
        reserve_type_info: TypeInfo,
    ): u64 acquires Profiles, Profile {
        let profile_emode = emode_category::profile_emode(signer::address_of(&get_profile_account(user_addr, profile_name)));
        if (!can_borrow_asset(&profile_emode, &reserve_type_info)) {
            0
        } else {
            let available_borrowing_power = available_borrowing_power(user_addr, profile_name);
            let price = asset_price(&profile_emode, &reserve_type_info);
            let borrow_factor = asset_borrow_factor(&profile_emode, &reserve_type_info);
            let max_borrow_asset_value = decimal::mul(available_borrowing_power, decimal::from_percentage((borrow_factor as u128)));
            decimal::as_u64(decimal::div(max_borrow_asset_value, price))
        }
    }

    fun borrow_profile(
        profile: &mut Profile,
        profile_emode_id: &Option<string::String>,
        reserve_type_info: TypeInfo,
        amount: u64,
        borrow_type: u8
    ) {
        assert!(!iterable_table::contains(&profile.deposited_reserves, reserve_type_info), 0);
        assert!(can_borrow_asset(profile_emode_id, &reserve_type_info), EPROFILE_EMODE_DIFF_WITH_RESERVE);

        let fee_amount = reserve::calculate_borrow_fee_using_borrow_type(
            reserve_type_info,
            amount,
            borrow_type
        );
        let borrowed_share = reserve::get_share_amount_from_borrow_amount(reserve_type_info, amount + fee_amount);
        
        let borrowed_reserve = iterable_table::borrow_mut_with_default(
            &mut profile.borrowed_reserves,
            reserve_type_info,
            Loan {
                borrowed_share: decimal::zero()
            }
        );
        borrowed_reserve.borrowed_share = decimal::add(borrowed_reserve.borrowed_share, borrowed_share);

        // We keep deposit share the same as collateralized LP coin amount. 
        // Need to be in sync with the amount we record in reserve farming.
        try_add_or_init_profile_reward_share<BorrowFarming>(
            profile,
            reserve_type_info,
            decimal::as_u128(borrowed_share)
        );
    }

    fun repay_profile(
        profile: &mut Profile,
        reserve_type_info: TypeInfo,
        amount: u64
    ): u64 {
        assert!(amount > 0, EPROFILE_REPAY_ZERO_AMOUNT);
        assert!(!iterable_table::contains(&profile.deposited_reserves, reserve_type_info), 0);
        assert!(
            iterable_table::contains(
                &profile.borrowed_reserves, reserve_type_info
            ), 
            EPROFILE_NO_BORROWED_RESERVE
        );

        let borrowed_reserve = iterable_table::borrow_mut(
            &mut profile.borrowed_reserves,
            reserve_type_info
        );

        let (actual_repay_amount, settle_share_amount) = reserve::calculate_repay(reserve_type_info, amount, borrowed_reserve.borrowed_share);

        borrowed_reserve.borrowed_share = decimal::sub(borrowed_reserve.borrowed_share, settle_share_amount);

        if (decimal::eq(borrowed_reserve.borrowed_share, decimal::zero())) {
            iterable_table::remove(
                &mut profile.borrowed_reserves,
                reserve_type_info
            );
        };

        // We remove borrow reward share the same with borrowed share. 
        // It should be the same as the amount removed in reserve farming.
        try_subtract_profile_reward_share<BorrowFarming>(
            profile,
            reserve_type_info,
            decimal::as_u128(settle_share_amount)
        );

        actual_repay_amount
    }

    public(friend) fun liquidate(
        user_addr: address,
        profile_name: &string::String,
        repay_reserve_type_info: TypeInfo,
        withdraw_reserve_type_info: TypeInfo,
        repay_amount: u64
    ): (u64, u64) acquires Profiles, Profile {
        assert!(repay_amount > 0, 0);
        let profile_addr = signer::address_of(&get_profile_account(user_addr, profile_name));
        let profile = borrow_global_mut<Profile>(profile_addr);
        let profile_emode = emode_category::profile_emode(profile_addr);

        let (actual_repay_amount, withdraw_amount) = liquidate_profile(
            profile, 
            &profile_emode,
            repay_reserve_type_info, 
            withdraw_reserve_type_info, 
            repay_amount
        );

        emit_deposit_event(user_addr, profile_name, profile, withdraw_reserve_type_info);
        emit_borrow_event(user_addr, profile_name, profile, repay_reserve_type_info);

        (actual_repay_amount, withdraw_amount)
    }

    // TODO: Consider adding dynamic liquidation bonus.
    /// Returns the (actual_repay_amount, actual_withdraw_amount) and update the `Profile`.
    fun liquidate_profile(
        profile: &mut Profile,
        profile_emode_id: &Option<string::String>,
        repay_reserve_type_info: TypeInfo,
        withdraw_reserve_type_info: TypeInfo,
        repay_amount: u64
    ): (u64, u64) {
        let total_borrowed_value = get_adjusted_borrowed_value_fresh_for_profile(profile, profile_emode_id);
        let liquidation_borrowed_value = get_liquidation_borrow_value_inner(profile, profile_emode_id);

        assert!(decimal::gte(total_borrowed_value, liquidation_borrowed_value), EPROFILE_IS_HEALTHY);
        assert!(iterable_table::contains(&profile.borrowed_reserves, repay_reserve_type_info), EPROFILE_NO_BORROWED_RESERVE);
        assert!(iterable_table::contains(&profile.deposited_reserves, withdraw_reserve_type_info), EPROFILE_NO_DEPOSIT_RESERVE);
        
        let repay_reserve = iterable_table::borrow_mut(
            &mut profile.borrowed_reserves,
            repay_reserve_type_info
        );
        
        let withdraw_reserve = iterable_table::borrow_mut(
            &mut profile.deposited_reserves,
            withdraw_reserve_type_info
        );

        let borrowed_amount = reserve::get_borrow_amount_from_share_dec(repay_reserve_type_info, repay_reserve.borrowed_share);
        let liquidation_bonus_bips = decimal::from_bips(
            (asset_liquidation_bonus_bips(profile_emode_id, &withdraw_reserve_type_info) as u128)
        );
        let bonus_rate = decimal::add(decimal::one(), liquidation_bonus_bips);
        let max_amount = decimal::min(decimal::from_u64(repay_amount), borrowed_amount);
        let borrowed_asset_price = asset_price(profile_emode_id, &repay_reserve_type_info);
        let withdraw_asset_price = asset_price(profile_emode_id, &withdraw_reserve_type_info);
        let collateral_amount = reserve::get_underlying_amount_from_lp_amount(
            withdraw_reserve_type_info,
            withdraw_reserve.collateral_amount
        );
        let collateral_value = decimal::mul(
            decimal::from_u64(collateral_amount),
            withdraw_asset_price
        );

        let (
            actual_repay_amount,
            withdraw_amount,
            settled_share_amount
        ) = if (decimal::lt(borrowed_amount, decimal::from_u64(LIQUIDATION_CLOSE_AMOUNT))) {
            // The case when the borrow amount is very small, in this case we try to close it out.
            let liquidation_value = decimal::mul(borrowed_amount, borrowed_asset_price);
            let bonus_liquidation_value = decimal::mul(liquidation_value, bonus_rate);
            
            // An extreme case could be borrowing 1.5 lamport of BTC and one of the collateral is 1 lamport of SBR.
            // When the collateral is not enough for all the repay, so only a fraction of the amount that user intended to 
            // repay is used.
            if (decimal::gte(bonus_liquidation_value, collateral_value)) {
                let repay_pct = decimal::div(collateral_value, bonus_liquidation_value);
                (
                    decimal::ceil_u64(decimal::mul(max_amount, repay_pct)),
                    withdraw_reserve.collateral_amount,
                    repay_reserve.borrowed_share
                )
            } else {
                // When there is enough collateral, we use up all the repay amount.
                let withdraw_pct = decimal::div(bonus_liquidation_value, collateral_value);
                (
                    decimal::ceil_u64(max_amount),
                    decimal::floor_u64(decimal::mul_u64(
                        withdraw_pct,
                        withdraw_reserve.collateral_amount
                    )),
                    repay_reserve.borrowed_share,
                )
            }
        } else { // When the borrow is large enough and we need to take into consideration of fractionalised liquidation.
            let max_liquidation_value_for_repay_reserve = decimal::mul(borrowed_asset_price, max_amount);
            let fractionalised_max_liqudiation_value = decimal::mul(
                total_borrowed_value,
                decimal::from_percentage(LIQUIDATION_CLOSE_FACTOR_PERCENTAGE) // LIQUIDATION_CLOSE_FACTOR
            );
            let max_liquidation_value = decimal::min(
                max_liquidation_value_for_repay_reserve, 
                fractionalised_max_liqudiation_value
            );

            let max_liquidation_amount = decimal::div(max_liquidation_value, borrowed_asset_price);
            let bonus_liquidation_value = decimal::mul(
                max_liquidation_value, 
                bonus_rate
            );

            if (decimal::gte(bonus_liquidation_value, collateral_value)) {
                let repay_percentage = decimal::div(collateral_value, bonus_liquidation_value);
                let settled_amount = decimal::mul(max_liquidation_amount, repay_percentage);
                let repay_amount = decimal::ceil_u64(settled_amount);
                let withdraw_amount = withdraw_reserve.collateral_amount;
                let settled_share = decimal::min(
                    reserve::get_share_amount_from_borrow_amount_dec(repay_reserve_type_info, settled_amount),
                    repay_reserve.borrowed_share
                );
                (repay_amount, withdraw_amount, settled_share)
            } else {
                let withdraw_percentage = decimal::div(bonus_liquidation_value, collateral_value);
                let settled_amount = max_liquidation_amount;
                let repay_amount = decimal::ceil_u64(settled_amount);
                let withdraw_amount = decimal::floor_u64(
                    decimal::mul_u64(withdraw_percentage, withdraw_reserve.collateral_amount)
                );
                let settled_share = decimal::min(
                    reserve::get_share_amount_from_borrow_amount_dec(repay_reserve_type_info, settled_amount),
                    repay_reserve.borrowed_share
                );
                (repay_amount, withdraw_amount, settled_share)
            }
        };

        repay_reserve.borrowed_share = decimal::sub(
            repay_reserve.borrowed_share,
            settled_share_amount
        );
        withdraw_reserve.collateral_amount = withdraw_reserve.collateral_amount - withdraw_amount;

        if (decimal::eq(repay_reserve.borrowed_share, decimal::zero())) {
            iterable_table::remove(
                &mut profile.borrowed_reserves,
                repay_reserve_type_info
            );
        };

        if (withdraw_reserve.collateral_amount == 0) {
            iterable_table::remove(
                &mut profile.deposited_reserves,
                withdraw_reserve_type_info
            );
        };

        try_subtract_profile_reward_share<BorrowFarming>(
            profile,
            repay_reserve_type_info,
            decimal::as_u128(settled_share_amount)
        );
        
        try_subtract_profile_reward_share<DepositFarming>(
            profile,
            withdraw_reserve_type_info,
            (withdraw_amount as u128)
        );

        (actual_repay_amount, withdraw_amount)
    }

    public(friend) fun claim_reward<FarmingType>(
        user_addr: address,
        name: &string::String,
        reserve_type_info: TypeInfo, // reserve::type_info<T>() for T
        reward_type: TypeInfo,
    ): u64 acquires Profiles, Profile {
        claim_reward_ti(
            user_addr,
            name,
            reserve_type_info,
            type_info::type_of<FarmingType>(),
            reward_type
        )
    }

    public(friend) fun claim_reward_ti(
        user_addr: address,
        name: &string::String,
        reserve_type_info: TypeInfo, // reserve::type_info<T>() for T
        farming_type: TypeInfo,
        reward_type: TypeInfo,
    ): u64 acquires Profiles, Profile {
        let profile_account = get_profile_account(user_addr, name);
        let profile = borrow_global_mut<Profile>(signer::address_of(&profile_account));
        let farms = borrow_farms_mut(profile, farming_type);
        assert!(iterable_table::contains(farms, reserve_type_info), 0);
        let profile_farm = iterable_table::borrow_mut(farms, reserve_type_info);
        let reserve_rewards = reserve::get_reserve_rewards_ti(reserve_type_info, farming_type);
        let claimable_amount = profile_farm::claim_reward(profile_farm, &reserve_rewards, reward_type);

        if (farming_type == type_info::type_of<DepositFarming>()) {
            emit_deposit_event(user_addr, name, profile, reserve_type_info);
        } else {
            assert!(farming_type == type_info::type_of<BorrowFarming>(), 0);
            emit_borrow_event(user_addr, name, profile, reserve_type_info);
        };

        claimable_amount
    }

    fun borrow_farms(
        profile: &Profile,
        farming_type: TypeInfo,
    ): &IterableTable<TypeInfo, ProfileFarm> {
        if (farming_type == type_info::type_of<DepositFarming>()) {
            &profile.deposit_farms 
        } else {
            if (farming_type == type_info::type_of<BorrowFarming>()) {
                &profile.borrow_farms 
            } else {
                abort(0)
            }
        }
    }

    fun borrow_farms_mut(
        profile: &mut Profile,
        farming_type: TypeInfo,
    ): &mut IterableTable<TypeInfo, ProfileFarm> {
        if (farming_type == type_info::type_of<DepositFarming>()) {
            &mut profile.deposit_farms 
        } else {
            if (farming_type == type_info::type_of<BorrowFarming>()) {
                &mut profile.borrow_farms 
            } else {
                abort(0)
            }
        }
    }

    public fun try_add_or_init_profile_reward_share<FarmingType>(
        profile: &mut Profile,
        reserve_type_info: TypeInfo,
        share_amount: u128
    ) {
        if (reserve::reserve_has_farm<FarmingType>(reserve_type_info)) {
            let reserve_rewards = reserve::get_reserve_rewards<FarmingType>(reserve_type_info);
            let farms = borrow_farms_mut(profile, type_info::type_of<FarmingType>());
            if (!iterable_table::contains(farms, reserve_type_info)) {
                iterable_table::add(farms, reserve_type_info, profile_farm::new(&reserve_rewards));
            };
            let profile_farm = iterable_table::borrow_mut(farms, reserve_type_info);
            profile_farm::add_share(profile_farm, &reserve_rewards, share_amount);
            reserve::try_add_reserve_reward_share<FarmingType>(reserve_type_info, share_amount);
        };
    }
    
    /// There are three consequences for this operation:
    /// 1. There is no corresponding reserve reward or profile reward entry. So nothing will happen.
    /// 2. There are more or equal profile reward shares than the input share amount. The reward will be partially reduced.
    /// 3. There are less profile reward shares than the input share amount. 
    ///    This is possible when the account has deposited/borrowed before the reserve having liquidity farming incentives.
    ///    We will clear the profile shares in this case.
    /// 
    /// Returns: amount of the removed shares
    public fun try_subtract_profile_reward_share<FarmingType>(
        profile: &mut Profile,
        reserve_type_info: TypeInfo,
        share_amount: u128
    ): u128 {
        let removed_share = 0;
        if (reserve::reserve_has_farm<FarmingType>(reserve_type_info)) {
            let farms = borrow_farms_mut(profile, type_info::type_of<FarmingType>());
            // User's profile might contain or not contain the reserve's type.
            // Because we might register and add rewards for a reserve after the users already deposited/borrowed assets. 
            // Under these cases, they have not obtained farming shares (since it was not registered in the reserve back then),
            // and does not have a profile farm entry corresponding to the reserve's type.
            if (iterable_table::contains(farms, reserve_type_info)) {
                let reserve_rewards = reserve::get_reserve_rewards<FarmingType>(reserve_type_info);
                let profile_farm = iterable_table::borrow_mut(farms, reserve_type_info);
                removed_share = profile_farm::try_remove_share(profile_farm, &reserve_rewards, share_amount);
                reserve::try_remove_reserve_reward_share<FarmingType>(reserve_type_info, removed_share);
            };
        };
        removed_share
    }

    /// Returns (reserve_type, farming_type)
    fun list_farm_reward_keys_of_coin<FarmingType, RewardCoin>(
        profile: &Profile,
    ): vector<Pair<TypeInfo, TypeInfo>> {
        let ret: vector<Pair<TypeInfo, TypeInfo>> = vector::empty();
        let farm = if (utils::type_eq<FarmingType, DepositFarming>()) {
            &profile.deposit_farms 
        } else {
            if (utils::type_eq<FarmingType, BorrowFarming>()) {
                &profile.borrow_farms 
            } else {
                abort(0)
            }
        };
        
        let farming_type = type_info::type_of<FarmingType>();
        let reward_type = type_info::type_of<RewardCoin>();
        let key = iterable_table::head_key(farm);
        while (option::is_some(&key)) {
            let reserve_type = *option::borrow(&key);
            let (p_farm, _, next)= iterable_table::borrow_iter(farm, reserve_type);
            if (profile_farm::has_reward(p_farm, reward_type)) {
                vector::push_back(&mut ret, pair::new(reserve_type, farming_type));
            };
            key = next;
        };
        ret
    }

    public fun list_claimable_reward_of_coin<RewardCoin>(
        user_addr: address,
        name: &string::String,
    ): vector<Pair<TypeInfo, TypeInfo>> acquires Profiles, Profile {
        let profile_account = get_profile_account(user_addr, name);
        let profile = borrow_global<Profile>(signer::address_of(&profile_account));
        let ret: vector<Pair<TypeInfo, TypeInfo>> = vector::empty();

        vector::append(&mut ret, list_farm_reward_keys_of_coin<DepositFarming, RewardCoin>(profile));
        vector::append(&mut ret, list_farm_reward_keys_of_coin<BorrowFarming, RewardCoin>(profile));

        ret
    }

    // Read the aggregated claimable rewards amount of the specified profile
    // Both DepositFarming and BorrowFarming will be returned
    // returns: vector<TypeInfo> is a list of reward coins
    //          vector<u64> is a list of reward amount with the same order as above
    #[view]
    public fun claimable_reward_amounts(
        user_addr: address, 
        name: string::String
    ): (vector<TypeInfo>, vector<u64>) acquires Profiles, Profile {
        let profile_account = get_profile_account(user_addr, &name);
        let profile = borrow_global<Profile>(signer::address_of(&profile_account));

        let deposit_rewards_claimable = profile_farms_claimable<DepositFarming>(profile);
        let borrow_rewards_claimable = profile_farms_claimable<BorrowFarming>(profile);

        let (deposit_reward_coins, deposit_reward_amounts) = map::to_vec_pair(deposit_rewards_claimable);
        let len = vector::length(&deposit_reward_coins);
        let i = 0;
        while (i < len) {
            let coin_type = *vector::borrow(&deposit_reward_coins, i);
            let amount = *vector::borrow(&deposit_reward_amounts, i);
            if (map::contains(&borrow_rewards_claimable, coin_type)) {
                amount = amount + map::get(&borrow_rewards_claimable, coin_type);
                map::upsert(&mut borrow_rewards_claimable, coin_type, amount);
            } else {
                map::add(&mut borrow_rewards_claimable, coin_type, amount);
            };

            i = i + 1;
        };

        map::to_vec_pair(borrow_rewards_claimable)
    }

    // Read the aggregated claimable rewards amount of the specified profile and farming type
    // returns: vector<TypeInfo> is a list of reward coins
    //          vector<u64> is a list of reward amount with the same order as above
    #[view]
    public fun claimable_reward_amount_on_farming<FarmingType>(
        user_addr: address, 
        name: string::String
    ): (vector<TypeInfo>, vector<u64>) acquires Profiles, Profile {
        let profile_account = get_profile_account(user_addr, &name);
        let profile = borrow_global<Profile>(signer::address_of(&profile_account));

        let rewards_claimable = profile_farms_claimable<FarmingType>(profile);
        map::to_vec_pair(rewards_claimable)
    }

    fun profile_farms_claimable<FarmingType>(profile: &Profile): Map<TypeInfo, u64> {
        let farms = if (utils::type_eq<FarmingType, DepositFarming>()) {
            &profile.deposit_farms 
        } else {
            assert!(utils::type_eq<FarmingType, BorrowFarming>(), EPROFILE_INVALID_FARMING_TYPE);
            &profile.borrow_farms 
        };

        let rewards_claimable = map::new();
        let reserve_key = iterable_table::head_key(farms);
        while (option::is_some(&reserve_key)) {
            let reserve_type = *option::borrow(&reserve_key);
            let (p_farm, _, next)= iterable_table::borrow_iter(farms, reserve_type);
            profile_farm::aggregate_all_claimable_rewards(p_farm, &mut rewards_claimable);
            reserve_key = next;
        };

        rewards_claimable
    }


    #[test_only]
    public fun profile_deposit_positions(
        user_addr: address, 
        profile_name: &string::String
    ): u64 acquires Profile, Profiles {
        let profile_account = get_profile_account(user_addr, profile_name);
        let profile = borrow_global<Profile>(signer::address_of(&profile_account));
        iterable_table::length(&profile.deposited_reserves)
    }

    fun emit_deposit_event(
        user_addr: address, 
        profile_name: &string::String, 
        profile: &Profile,
        reserve_type: TypeInfo,
    ) {
        let collateral_amount = if (iterable_table::contains(&profile.deposited_reserves, reserve_type)) {
            iterable_table::borrow(&profile.deposited_reserves, reserve_type).collateral_amount
        } else {
            0
        };
        let farm = if (iterable_table::contains(&profile.deposit_farms, reserve_type)) {
            let f = iterable_table::borrow(&profile.deposit_farms, reserve_type);
            option::some(profile_farm::profile_farm_raw(f))
        } else {
            option::none()
        };
        event::emit(SyncProfileDepositEvent {
            user_addr: user_addr,
            profile_name: *profile_name,
            reserve_type: reserve_type,
            collateral_amount: collateral_amount,
            farm: farm,
        })
    }

    fun emit_borrow_event(
        user_addr: address, 
        profile_name: &string::String, 
        profile: &Profile,
        reserve_type: TypeInfo,
    ) {
        let borrowed_share = if (iterable_table::contains(&profile.borrowed_reserves, reserve_type)) {
            iterable_table::borrow<TypeInfo, Loan>(&profile.borrowed_reserves, reserve_type).borrowed_share
        } else {
            decimal::zero()
        };
        let farm = if (iterable_table::contains(&profile.borrow_farms, reserve_type)) {
            let f = iterable_table::borrow(&profile.borrow_farms, reserve_type);
            option::some(profile_farm::profile_farm_raw(f))
        } else {
            option::none()
        };
        event::emit(SyncProfileBorrowEvent {
            user_addr: user_addr,
            profile_name: *profile_name,
            reserve_type: reserve_type,
            borrowed_share_decimal: decimal::raw(borrowed_share),
            farm: farm,
        })
    }

    #[view]
    /// Returns whether the profile is eligible for the specified emode.
    /// # Returns
    ///
    /// * `bool`: is eligible or not. (will be `true` if the profile is alredy in emode)
    /// * `bool`: has enough collateral or not if the profile enter the emode.
    /// * `vector<string::String>`: which reserves make profile ineligible for the emode.
    public fun is_eligible_for_emode(
        user_addr: address, 
        profile_name: string::String, 
        emode_id: string::String
    ): (bool, bool, vector<string::String>) acquires Profiles, Profile {
        let profile_addr = signer::address_of(&get_profile_account(user_addr, &profile_name));
        let profile = borrow_global<Profile>(profile_addr);

        if (emode_category::profile_emode(profile_addr) == option::some(emode_id)) {
            (true, has_enough_collateral_for_profile(profile, &option::some(emode_id)), vector::empty())
        } else {
            let ineligible_reserves = vector::empty();
            let borrowed_key = iterable_table::head_key(&profile.borrowed_reserves);
            while (option::is_some(&borrowed_key)) {
                let borrowed_type = *option::borrow(&borrowed_key);
                let (_, _, next) = iterable_table::borrow_iter(&profile.borrowed_reserves, borrowed_type);

                if (!emode_category::reserve_in_emode_t(&emode_id, borrowed_type)) {
                    vector::push_back(&mut ineligible_reserves, type_info_to_name(borrowed_type));
                };
                borrowed_key = next;
            };

            if (
                vector::length(&ineligible_reserves) > 0 || 
                !has_enough_collateral_for_profile(profile, &option::some(emode_id))
            ) {
                (false, false, ineligible_reserves)
            } else {
                (true, true, ineligible_reserves)
            }
        }
    }

    public(friend) fun set_emode(user_addr: address, profile_name: &string::String, emode_id_x: Option<string::String>) acquires Profiles, Profile {
        let profile_addr = signer::address_of(&get_profile_account(user_addr, profile_name));
        let profile = borrow_global<Profile>(profile_addr);

        // if user is trying to set another category than default we require that
        // either the user is not borrowing, or it's borrowing assets of the emode id
        if (option::is_some(&emode_id_x)) {
            let borrowed_reserves = &profile.borrowed_reserves;
            let borrowed_key = iterable_table::head_key(borrowed_reserves);
            let emode_id = option::extract(&mut emode_id_x);
            while (option::is_some(&borrowed_key)) {
                let borrowed_type = *option::borrow(&borrowed_key);
                let (_, _, next) = iterable_table::borrow_iter(borrowed_reserves, borrowed_type);

                assert!(emode_category::reserve_in_emode_t(&emode_id, borrowed_type), EPROFILE_EMODE_DIFF_WITH_RESERVE);

                borrowed_key = next;
            };

            // check existence and enter emode
            emode_category::profile_enter_emode(profile_addr, emode_id);
        } else {
            emode_category::profile_exit_emode(profile_addr);
        };

        assert!(has_enough_collateral_for_profile(profile, &emode_id_x), EPROFILE_NOT_ENOUGH_COLLATERAL);
    }

    public(friend) fun asset_borrow_factor(_profile_emode_id: &Option<string::String>, reserve_type: &TypeInfo): u8 {
        reserve::borrow_factor(*reserve_type)
    }

    public(friend) fun asset_ltv(profile_emode_id: &Option<string::String>, reserve_type: &TypeInfo): u8 {
        let reserve_emode = emode_category::reserve_emode_t(*reserve_type);
        if (emode_is_matching(profile_emode_id, &reserve_emode)) {
            emode_category::emode_loan_to_value(option::extract(&mut reserve_emode))
        } else {
            reserve::loan_to_value(*reserve_type)
        }
    }

    public(friend) fun asset_liquidation_threshold(profile_emode_id: &Option<string::String>, reserve_type: &TypeInfo): u8 {
        let reserve_emode = emode_category::reserve_emode_t(*reserve_type);
        if (emode_is_matching(profile_emode_id, &reserve_emode)) {
            emode_category::emode_liquidation_threshold(option::extract(&mut reserve_emode))
        } else {
            reserve::liquidation_threshold(*reserve_type)
        }
    }

    public(friend) fun asset_liquidation_bonus_bips(profile_emode_id: &Option<string::String>, reserve_type: &TypeInfo): u64 {
        let reserve_emode = emode_category::reserve_emode_t(*reserve_type);
        if (emode_is_matching(profile_emode_id, &reserve_emode)) {
            emode_category::emode_liquidation_bonus_bips(option::extract(&mut reserve_emode))
        } else {
            reserve::liquidation_bonus_bips(*reserve_type)
        }
    }

    public(friend) fun asset_price(profile_emode_id: &Option<string::String>, reserve_type: &TypeInfo): Decimal {
        let reserve_emode = emode_category::reserve_emode_t(*reserve_type);
        let oracle_type = *reserve_type;
        if (emode_is_matching(profile_emode_id, &reserve_emode)) {
            let emode_oracle = emode_category::emode_oracle_key_type(option::extract(&mut reserve_emode));
            if (option::is_some(&emode_oracle)) {
                oracle_type = option::extract(&mut emode_oracle);
            }
        };
        oracle::get_price(oracle_type)
    }

    public(friend) fun can_borrow_asset(profile_emode_id: &Option<string::String>, reserve_type: &TypeInfo): bool {
        let reserve_emode = emode_category::reserve_emode_t(*reserve_type);
        if (option::is_some(profile_emode_id)) {
            // Only can borrow assets that belong to the same emode category.
            emode_is_matching(profile_emode_id, &reserve_emode)
        } else {
            true
        }
    }

    public(friend) fun emode_is_matching(profile_emode_id: &Option<string::String>, reserve_emode_id: &Option<string::String>): bool {
        if (option::is_some(profile_emode_id) && 
            option::is_some(reserve_emode_id) &&
            *option::borrow(profile_emode_id) == *option::borrow(reserve_emode_id)
        ) {
            true
        } else {
            false
        }
    }

    fun type_info_to_name(typ: TypeInfo): string::String {
        string_utils::format3(
            &b"{}::{}::{}", 
            type_info::account_address(&typ), 
            string::utf8(type_info::module_name(&typ)), 
            string::utf8(type_info::struct_name(&typ))
        )
    }
}
