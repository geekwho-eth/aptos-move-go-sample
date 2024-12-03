//! A module that does various bookkeeping including interest accumulation, fee calculation and others.
//! The actual `Coin` transfer should happen on the caller side.
module aries::reserve_details {
    use std::timestamp;

    use aries_config::reserve_config::{Self, ReserveConfig};
    use aries_config::interest_rate_config::{Self, InterestRateConfig};
    use aries::math_utils;

    use decimal::decimal::{Self, Decimal};

    //
    // Errors.
    //

    /// When deposit limit has been exceeded.
    const ERESERVE_DETAILS_EXCEED_DEPOSIT_LIMIT: u64 = 0;

    /// When the borrow limit exceeds.
    const ERESERVE_DETAILS_BORROW_LIMIT_EXCEED: u64 = 1;

    /// When there is not enough cash for `ReserveDetails`.
    const ERESERVE_DETAILS_NOT_ENOUGH_CASH: u64 = 2;

    /// When there is not enough cash for `ReserveDetails`.
    const ERESERVE_DETAILS_DATA_CORRUPTED: u64 = 3;

    /// When the current timestamp is behind the last interest accrue timestamp.
    const ERESERVE_DETAILS_INVALID_TS: u64 = 4;

    /// When there is other reserve operations during an open flash loan besides closing it.
    const ERESERVE_DETAILS_FLASH_LOAN_INTERFERED: u64 = 5;

    /// When redeeming from reserve is not allowed.
    const ERESERVE_DETAILS_FORBID_WITHDRAW: u64 = 6;

    /// When there is no liquidity farm registered for the FarmingType.
    const ERESERVE_DETAILS_FARM_NOT_FOUND: u64 = 7;

    // The main purpose of this struct is to enable us to look things up via `TypeInfo`,
    // instead of generic. Some of the fields are duplicate for this purpose.
    struct ReserveDetails has store, copy, drop {
        /// Total number of LP tokens minted.
        total_lp_supply: u128,

        /// Total cash available. This should always be the same as `value(underlying_coin)`.
        total_cash_available: u128,

        /// The initial exchange rate between LP tokens and underlying assets.
        initial_exchange_rate: Decimal,

        /// Reserve amount.
        reserve_amount: Decimal,

        /// The normalized value for total borrowed share.
        total_borrowed_share: Decimal,

        /// Total amount of outstanding debt.
        total_borrowed: Decimal,

        /// The timestamp second that the interest get accrue last time.
        interest_accrue_timestamp: u64,

        /// Reserve related configuration.
        reserve_config: ReserveConfig,

        /// Interest rate configuration.
        interest_rate_config: InterestRateConfig,
    }

    public fun new(
        total_lp_supply: u128,
        total_cash_available: u128,
        initial_exchange_rate: Decimal,
        reserve_amount: Decimal,
        total_borrowed_share: Decimal,
        total_borrowed: Decimal,
        interest_accrue_timestamp: u64,
        reserve_config: ReserveConfig,
        interest_rate_config: InterestRateConfig,
    ): ReserveDetails {
        ReserveDetails {
            total_lp_supply,
            total_cash_available,
            initial_exchange_rate,
            reserve_amount,
            total_borrowed_share,
            total_borrowed,
            interest_accrue_timestamp,
            reserve_config,
            interest_rate_config
        }
    }

    public fun new_fresh(
        initial_exchange_rate: Decimal,
        reserve_config: ReserveConfig,
        interest_rate_config: InterestRateConfig
    ): ReserveDetails {
        new(
            0, // total_lp_supply
            0, // total_cash_available
            initial_exchange_rate,
            decimal::zero(), // reserve_amount
            decimal::zero(), // total_borrowed_share
            decimal::zero(), // total_borrowed
            timestamp::now_seconds(), // interest_accrue_timestamp
            reserve_config,
            interest_rate_config
        )
    }

    public fun total_cash_available(reserve_details: &ReserveDetails): u128 {
        reserve_details.total_cash_available
    }

    public fun set_total_cash_available(reserve_details: &mut ReserveDetails, total_cash_available: u128) {
        reserve_details.total_cash_available = total_cash_available
    }

    public fun total_lp_supply(reserve_details: &ReserveDetails): u128 {
        reserve_details.total_lp_supply
    }

    public fun total_borrow_amount(reserve_details: &mut ReserveDetails): Decimal {
        accrue_interest(reserve_details);
        reserve_details.total_borrowed
    }
    #[test_only]
    public fun set_total_borrow_amount(reserve_details: &mut ReserveDetails, new_amount: Decimal) {
        reserve_details.total_borrowed = new_amount;
    }

    public fun total_borrowed_share(reserve_details: &ReserveDetails): Decimal {
        reserve_details.total_borrowed_share
    }
    #[test_only]
    public fun set_total_borrow_share(reserve_details: &mut ReserveDetails, new_amount: Decimal) {
        reserve_details.total_borrowed_share = new_amount;
    }

    public fun reserve_amount(reserve_details: &mut ReserveDetails): Decimal {
        accrue_interest(reserve_details);
        reserve_details.reserve_amount
    }
    #[test_only]
    public fun set_reserve_amount(reserve_details: &mut ReserveDetails, new_amount: Decimal) {
        reserve_details.reserve_amount = new_amount;
    }

    public fun reserve_amount_raw(reserve_details: &ReserveDetails): Decimal {
        reserve_details.reserve_amount
    }

    public fun withdraw_reserve_amount(reserve_details: &mut ReserveDetails): u64 {
        let reserve_amount = reserve_amount(reserve_details);
        let withdraw_amount = decimal::floor_u64(reserve_amount);
        reserve_details.reserve_amount = decimal::sub(reserve_amount, decimal::from_u64(withdraw_amount));
        reserve_details.total_cash_available = reserve_details.total_cash_available - (withdraw_amount as u128);
        withdraw_amount
    }

    public fun initial_exchange_rate(details: &ReserveDetails): Decimal {
        details.initial_exchange_rate
    }

    public fun total_borrowed(details: &ReserveDetails): Decimal {
        details.total_borrowed
    }

    public fun interest_accrue_timestamp(details: &ReserveDetails): u64 {
        details.interest_accrue_timestamp
    }

    public fun reserve_config(reserve_details: &ReserveDetails): ReserveConfig {
        reserve_details.reserve_config
    }

    public fun update_reserve_config(reserve_details: &mut ReserveDetails, reserve_config: ReserveConfig) {
        reserve_details.reserve_config = reserve_config;
    }

    public fun interest_rate_config(reserve_details: &ReserveDetails): InterestRateConfig {
        reserve_details.interest_rate_config
    }

    public fun update_interest_rate_config(reserve_details: &mut ReserveDetails, interest_rate_config: InterestRateConfig) {
        reserve_details.interest_rate_config = interest_rate_config;
    }

    fun is_within_deposit_limit(reserve_details: &ReserveDetails): bool {
        let deposit_limit = reserve_config::deposit_limit(&reserve_details.reserve_config);
        let total_liquidity = decimal::as_u128(reserve_details.total_borrowed) + reserve_details.total_cash_available - decimal::as_u128(reserve_details.reserve_amount);

        (total_liquidity as u64) <= deposit_limit
    }

    fun is_within_borrow_limit(reserve_details: &ReserveDetails): bool {
        let borrow_limit = reserve_config::borrow_limit(&reserve_details.reserve_config);
        decimal::as_u64(reserve_details.total_borrowed) <= borrow_limit
    }

    public fun allow_collateral(reserve_details: &ReserveDetails): bool {
        reserve_config::allow_collateral(&reserve_details.reserve_config)
    }

    fun accrue_interest(reserve_details: &mut ReserveDetails) {
        let current_time_second = timestamp::now_seconds();

        assert!(
            current_time_second >= reserve_details.interest_accrue_timestamp, 
            ERESERVE_DETAILS_INVALID_TS
        );
        if (current_time_second == reserve_details.interest_accrue_timestamp) {
            return
        };

        let time_delta = current_time_second - reserve_details.interest_accrue_timestamp;
        let interest_factor = interest_rate_config::get_borrow_rate_for_seconds(
            time_delta,
            &reserve_details.interest_rate_config,
            reserve_details.total_borrowed, 
            reserve_details.total_cash_available,
            reserve_details.reserve_amount,
        );

        let interest_accumulated  = decimal::mul(interest_factor, reserve_details.total_borrowed);
        let reserve_ratio = decimal::from_percentage((reserve_config::reserve_ratio(&reserve_details.reserve_config) as u128));
        let interest_reserved = decimal::mul(interest_accumulated, reserve_ratio);

        let total_borrow_new = decimal::add(reserve_details.total_borrowed, interest_accumulated);
        let reserve_amount_new = decimal::add(reserve_details.reserve_amount, interest_reserved);

        reserve_details.interest_accrue_timestamp = current_time_second;
        reserve_details.total_borrowed = total_borrow_new;
        reserve_details.reserve_amount = reserve_amount_new;
    }

    public fun mint(
        reserve_details: &mut ReserveDetails,
        amount: u64
    ): u64 {
        accrue_interest(reserve_details);
        let lp_amount = get_lp_amount_from_underlying_amount(reserve_details, amount);

        mint_fresh(reserve_details, amount, lp_amount);
        assert!(is_within_deposit_limit(reserve_details), ERESERVE_DETAILS_EXCEED_DEPOSIT_LIMIT);

        lp_amount
    }

    fun mint_fresh(
        reserve_details: &mut ReserveDetails,
        underlying_amount: u64,
        lp_amount: u64,
    ) {
        reserve_details.total_cash_available = reserve_details.total_cash_available + (underlying_amount as u128);
        reserve_details.total_lp_supply = reserve_details.total_lp_supply + (lp_amount as u128);
    }

    public fun redeem(
        reserve_details: &mut ReserveDetails,
        lp_amount: u64
    ): u64 {
        assert!(reserve_config::allow_redeem(&reserve_details.reserve_config), ERESERVE_DETAILS_FORBID_WITHDRAW);

        accrue_interest(reserve_details);
        let amount = get_underlying_amount_from_lp_amount(reserve_details, lp_amount);
        redeem_fresh(reserve_details, lp_amount, amount);
        amount
    }

    fun redeem_fresh(
        reserve_details: &mut ReserveDetails,
        lp_amount: u64,
        underlying_amount: u64
    ) {
        assert!(
            reserve_details.total_cash_available >= (underlying_amount as u128), 
            ERESERVE_DETAILS_NOT_ENOUGH_CASH
        );
        assert!(
            reserve_details.total_lp_supply >= (lp_amount as u128), 
            ERESERVE_DETAILS_DATA_CORRUPTED
        );

        reserve_details.total_cash_available = reserve_details.total_cash_available - (underlying_amount as u128);
        reserve_details.total_lp_supply = reserve_details.total_lp_supply - (lp_amount as u128);
    }

    public fun borrow(reserve_details: &mut ReserveDetails, amount: u64) {
        accrue_interest(reserve_details);
        borrow_fresh(reserve_details, amount);
        assert!(is_within_borrow_limit(reserve_details), ERESERVE_DETAILS_BORROW_LIMIT_EXCEED);
    }

    // Increment the total borrow amount for reserve assuming that interest is accrued already.
    fun borrow_fresh(reserve_details: &mut ReserveDetails, amount: u64) {
        let borrow_share_amount = get_share_amount_from_borrow_amount(reserve_details, decimal::from_u64(amount));
        assert!(reserve_details.total_cash_available >= (amount as u128), ERESERVE_DETAILS_NOT_ENOUGH_CASH);
        reserve_details.total_cash_available = reserve_details.total_cash_available - (amount as u128);
        reserve_details.total_borrowed = decimal::add(reserve_details.total_borrowed, decimal::from_u64(amount));
        reserve_details.total_borrowed_share = decimal::add(reserve_details.total_borrowed_share, borrow_share_amount);
    }

    public fun repay(reserve_details: &mut ReserveDetails, amount: u64): (u64, Decimal) {
        accrue_interest(reserve_details);
        repay_fresh(reserve_details, amount)
    }

    // Decrement the total borrow amount for reserve assuming that the borrow interest is accrued already.
    // Returns the actual amount that got repaid.
    fun repay_fresh(reserve_details: &mut ReserveDetails, amount: u64): (u64, Decimal) {
        let total_borrowed_share = reserve_details.total_borrowed_share;
        let (actual_repay_amount, settled_share_amount) = calculate_repay(reserve_details, amount, total_borrowed_share);
        let settled_borrow_amount = get_borrow_amount_from_share_amount(reserve_details, settled_share_amount);

        reserve_details.total_cash_available = reserve_details.total_cash_available + (actual_repay_amount as u128);
        reserve_details.total_borrowed = decimal::sub(reserve_details.total_borrowed, decimal::min(reserve_details.total_borrowed, settled_borrow_amount));
        reserve_details.total_borrowed_share = decimal::sub(reserve_details.total_borrowed_share, settled_share_amount);

        (actual_repay_amount, settled_share_amount)
    }

    public fun calculate_borrow_fee(reserve_details: &ReserveDetails, borrow_amount: u64): u64 {
        let bororw_fee_millionth = reserve_config::borrow_fee_hundredth_bips(&reserve_config(reserve_details));
        math_utils::mul_millionth_u64(borrow_amount, bororw_fee_millionth)
    }

    public fun total_user_liquidity(reserve_details: &mut ReserveDetails): Decimal {
        accrue_interest(reserve_details);
        let cash_plus_borrows = decimal::add(
            reserve_details.total_borrowed, 
            decimal::from_u128(reserve_details.total_cash_available)
        );
        decimal::sub(
            cash_plus_borrows, 
            reserve_details.reserve_amount
        )
    }

    #[test_only]
    public fun get_exchange_rate(reserve_details: &mut ReserveDetails): Decimal {
        get_underlying_amount_from_lp_amount_frac(reserve_details, 1)
    }

    public fun get_underlying_amount_from_lp_amount_frac(
        reserve_details: &mut ReserveDetails,
        lp_amount: u64
    ): Decimal {
        accrue_interest(reserve_details);
        let total_lp_supply = reserve_details.total_lp_supply;
        if (total_lp_supply == 0) {
            decimal::mul(
                decimal::from_u64(lp_amount),
                reserve_details.initial_exchange_rate
            )
        } else {
            decimal::mul_div(
                decimal::from_u64(lp_amount), 
                total_user_liquidity(reserve_details),
                decimal::from_u128(total_lp_supply)
            )
        }
    }

    public fun get_underlying_amount_from_lp_amount(
        reserve_details: &mut ReserveDetails,
        lp_amount: u64
    ): u64 {
        decimal::floor_u64(
            get_underlying_amount_from_lp_amount_frac(reserve_details, lp_amount)
        )
    }

    public fun get_lp_amount_from_underlying_amount(
        reserve_details: &mut ReserveDetails,
        underlying_amount: u64
    ): u64 {
        accrue_interest(reserve_details);
        let total_lp_supply = reserve_details.total_lp_supply;
        let lp_amount = if (total_lp_supply == 0) {
            decimal::div(
                decimal::from_u64(underlying_amount),
                reserve_details.initial_exchange_rate
            )
        } else {
            decimal::mul_div(
                decimal::from_u64(underlying_amount),
                decimal::from_u128(total_lp_supply),
                total_user_liquidity(reserve_details)
            )
        };
        decimal::floor_u64(lp_amount)
    }

    public fun get_borrow_exchange_rate(reserve_details: &mut ReserveDetails): Decimal {
        get_borrow_amount_from_share_amount(reserve_details, decimal::one())
    }

    public fun get_borrow_amount_from_share_amount(
        reserve_details: &mut ReserveDetails,
        share_amount: Decimal
    ): Decimal {
        accrue_interest(reserve_details);
        
        let total_borrowed_amount = reserve_details.total_borrowed;
        if (decimal::eq(total_borrowed_amount, decimal::zero())) {
            share_amount
        } else {
            decimal::mul_div(
                total_borrowed_amount,
                share_amount,
                reserve_details.total_borrowed_share
            )
        }
    }

    public fun get_share_amount_from_borrow_amount(
        reserve_details: &mut ReserveDetails,
        borrow_amount: Decimal
    ): Decimal {
        accrue_interest(reserve_details);

        let total_borrowed_amount = reserve_details.total_borrowed;
        if (decimal::eq(total_borrowed_amount, decimal::zero())) {
            borrow_amount
        } else {
            decimal::mul_div(
                reserve_details.total_borrowed_share,
                borrow_amount, 
                total_borrowed_amount, 
            )
        }
    }

    /// Return the amount that actually will be repaid and the borrowed *share* amount settled.
    /// The invariant is that `settle_share_amount` is always within [0, borrowed_share].
    public fun calculate_repay(reserve_details: &mut ReserveDetails, repay_amount: u64, borrowed_share: Decimal): (u64, Decimal) {
        let repay_share_amount = get_share_amount_from_borrow_amount(reserve_details, decimal::from_u64(repay_amount));

        if (decimal::lte(repay_share_amount, borrowed_share)) {
            (repay_amount, repay_share_amount)
        } else {
            let actual_repay_amount = get_borrow_amount_from_share_amount(reserve_details, borrowed_share);
            (decimal::ceil_u64(actual_repay_amount), borrowed_share)
        }
    }

    public fun calculate_flash_loan_fee(reserve_details: &ReserveDetails, borrow_amount: u64): u64 {
        let flash_loan_fee_hundredth_bips = reserve_config::flash_loan_fee_hundredth_bips(&reserve_config(reserve_details));
        math_utils::mul_millionth_u64(borrow_amount, flash_loan_fee_hundredth_bips)
    }
}