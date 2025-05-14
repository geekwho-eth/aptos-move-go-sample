module aries::controller {
    use std::signer;
    use std::option::{Self, Option};
    use std::string::{Self, String};

    use aptos_std::event::{Self};
    use aptos_std::type_info::{Self, TypeInfo};

    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::fungible_asset::{Metadata};
    use aptos_framework::object::{Object};


    use oracle::oracle;

    use aries::controller_config;
    use decimal::decimal;
    use aries_config::interest_rate_config;
    use aries::reserve::{Self, LP};
    use aries_config::reserve_config;
    use aries::reserve_farm;
    use aries::reward_container;
    use aries::profile;
    use aries::utils;
    use aries::emode_category;
    use aries::fa_to_coin_wrapper;

    //
    // Errors.
    //

    /// When the minimum output amount is not satisfied from controller.
    const ECONTROLLER_SWAP_MINIMUM_OUT_NOT_MET: u64 = 0;
    /// When the deposit amount is zero.
    const ECONTROLLER_DEPOSIT_ZERO_AMOUNT: u64 = 1;
    /// When the account is not Aries Markets Account. 
    const ECONTROLLER_NOT_ARIES: u64 = 2;

    #[event]
    struct AddReserveEvent<phantom CoinType> has drop, store  {
        signer_addr: address,
        initial_exchange_rate_decimal: u128,
        reserve_conf: reserve_config::ReserveConfig,
        interest_rate_conf: interest_rate_config::InterestRateConfig,
    }
    
    #[event]
    struct RegisterUserEvent has drop, store {
        user_addr: address,
        default_profile_name: string::String,
        referrer_addr: option::Option<address>,
    }

    #[event]
    struct AddSubaccountEvent has drop, store {
        user_addr: address,
        profile_name: string::String,
    }

    #[event]
    struct MintLPShareEvent<phantom CoinType> has drop, store {
        user_addr: address,
        amount: u64,
        lp_amount: u64,
    }

    #[event]
    struct RedeemLPShareEvent<phantom CoinType> has drop, store {
        user_addr: address,
        amount: u64,
        lp_amount: u64,
    }

    #[event]
    struct AddLPShareEvent<phantom CoinType> has drop, store {
        user_addr: address,
        profile_name: string::String,
        lp_amount: u64,
    }

    #[event]
    struct RemoveLPShareEvent<phantom CoinType> has drop, store {
        user_addr: address,
        profile_name: string::String,
        lp_amount: u64,
    }

    #[event]
    struct DepositEvent<phantom CoinType> has drop, store {
        sender: address,
        receiver: address,
        profile_name: string::String,
        amount_in: u64,
        repay_only: bool,
        repay_amount: u64,
        deposit_amount: u64,
    }

    #[event]
    struct WithdrawEvent<phantom CoinType> has drop, store {
        sender: address,
        profile_name: string::String,
        amount_in: u64,
        allow_borrow: bool,
        withdraw_amount: u64,
        borrow_amount: u64,
    }

    #[event]
    struct LiquidateEvent<phantom RepayCoin, phantom WithdrawCoin> has drop, store {
        liquidator: address,
        liquidatee: address,
        liquidatee_profile_name: string::String,
        repay_amount_in: u64,
        redeem_lp: bool,
        repay_amount: u64,
        withdraw_lp_amount: u64,
        liquidation_fee_amount: u64,
        redeem_lp_amount: u64,
    }

    #[event]
    struct DepositRepayForEvent<phantom CoinType> has drop, store {
        receiver: address,
        receiver_profile_name: string::String,
        deposit_amount: u64,
        repay_amount: u64,
    }

    #[event]
    struct SwapEvent<phantom InCoin, phantom OutCoin> has drop, store {
        sender: address,
        profile_name: string::String,
        amount_in: u64,
        amount_min_out: u64,
        allow_borrow: bool,
        in_withdraw_amount: u64,
        in_borrow_amount: u64,
        out_deposit_amount: u64,
        out_repay_amount: u64,
    }

    #[event]
    struct UpsertPrivilegedReferrerConfigEvent has drop, store {
        signer_addr: address,
        claimant_addr: address,
        fee_sharing_percentage: u8,
    }

    #[event]
    struct AddRewardEvent<phantom ReserveCoin, phantom FarmingType, phantom RewardCoin> has drop, store {
        signer_addr: address,
        amount: u64,
    }

    #[event]
    struct RemoveRewardEvent<phantom ReserveCoin, phantom FarmingType, phantom RewardCoin> has drop, store {
        signer_addr: address,
        amount: u64,
    }

    #[event]
    struct ClaimRewardEvent<phantom RewardCoin> has drop, store {
        user_addr: address,
        profile_name: string::String,
        reserve_type: TypeInfo,
        farming_type: TypeInfo,
        reward_amount: u64,
    }

    #[event]
    struct UpdateRewardConfigEvent<phantom ReserveCoin, phantom FarmingType, phantom RewardCoin> has drop, store {
        signer_addr: address,
        config: reserve_farm::RewardConfig,
    }

    #[event]
    struct UpdateReserveConfigEvent<phantom CoinType> has drop, store {
        signer_addr: address,
        config: reserve_config::ReserveConfig, 
    }

    #[event]
    struct UpdateInterestRateConfigEvent<phantom CoinType> has drop, store {
        signer_addr: address,
        config: interest_rate_config::InterestRateConfig,
    }

    #[event]
    struct BeginFlashLoanEvent<phantom CoinType> has drop, store {
        user_addr: address,
        profile_name: string::String,
        amount_in: u64,
        withdraw_amount: u64,
        borrow_amount: u64,
    }

    #[event]
    struct EndFlashLoanEvent<phantom CoinType> has drop, store {
        user_addr: address,
        profile_name: string::String,
        amount_in: u64,
        repay_amount: u64,
        deposit_amount: u64,
    }

    #[event]
    struct ProfileEModeSet has drop, store {
        user_addr: address,
        profile_name: string::String,
        // An empty string indicates exiting emode, 
        // while any other non-empty string represents an active emode configuration.
        emode_id: string::String,
    }

    #[event]
    struct EModeCategorySet has drop, store {
        signer_addr: address,
        id: string::String,
        label: string::String,
        loan_to_value: u8,
        liquidation_threshold: u8,
        liquidation_bonus_bips: u64,
        oracle_key_type: string::String,
    }

    #[event]
    struct ReserveEModeSet has drop, store {
        signer_addr: address,
        reserve_str: string::String,
        // An empty string indicates exiting emode, 
        // while any other non-empty string represents an active emode configuration.
        emode_id: string::String,
    }

    /// Deployment: we can just use a normal human owned account (will need to make sure that 
    /// this account is only used for deployment) and transfer the authentication key to a 
    /// multisig/another account later on.
    public entry fun init(account: &signer, admin_addr: address) {
        controller_config::init_config(account, admin_addr);
        reserve::init(account);
        oracle::init(account, admin_addr);
        emode_category::init(account, admin_addr);
    }

    public entry fun init_reward_container<Coin0>(account: &signer) {
        assert!(signer::address_of(account) == @aries, ECONTROLLER_NOT_ARIES);
        reward_container::init_container<Coin0>(account);
    }

    public entry fun init_emode(account: &signer) {
        emode_category::init(account, signer::address_of(account));
    }

    public entry fun init_wrapper_fa_signer(account: &signer) {
        fa_to_coin_wrapper::init(account);
    }

    public entry fun init_wrapper_coin<WCoin>(account: &signer, metadata: Object<Metadata>) {
        fa_to_coin_wrapper::add_fa<WCoin>(account, metadata);
    }

    /// Need to have a corresponding Wrapped Coin.
    public entry fun deposit_fa<WCoin>(
        account: &signer,
        profile_name: vector<u8>,
        amount: u64,
    ) {
        let coin = fa_to_coin_wrapper::fa_to_coin<WCoin>(account, amount);
        deposit_and_repay_for(signer::address_of(account), &string::utf8(profile_name), coin);
    }

    /// Need to have a corresponding Wrapped Coin.
    public entry fun withdraw_fa<WCoin>(
        account: &signer,
        profile_name: vector<u8>,
        amount: u64,
        allow_borrow: bool,
    ) {
        withdraw<WCoin>(account, profile_name, amount, allow_borrow);
        // In the case when `WCoin` is "leaked", it might cause more `WCoin` gets converted to FA.
        let amount = coin::balance<WCoin>(signer::address_of(account));
        let coin = coin::withdraw<WCoin>(account, amount);
        fa_to_coin_wrapper::coin_to_fa<WCoin>(coin, account);
    }

    public entry fun add_reserve<Coin0>(admin: &signer) {
        controller_config::assert_is_admin(signer::address_of(admin));
        // TODO: change to use `lp_store` since it won't always be the same as the `admin`.
        // TODO: change to custom configuration.
        reserve::create<Coin0>(
            admin,
            decimal::one(),
            reserve_config::default_config(),
            interest_rate_config::default_config()
        );

        event::emit(AddReserveEvent<Coin0> {
            signer_addr: signer::address_of(admin),
            initial_exchange_rate_decimal: decimal::raw(decimal::one()),
            reserve_conf: reserve_config::default_config(),
            interest_rate_conf: interest_rate_config::default_config()
        });
    }

    #[test_only]
    public entry fun add_reserve_for_test<Coin0>(admin: &signer) {
        controller_config::assert_is_admin(signer::address_of(admin));
        reserve::create<Coin0>(
            admin,
            decimal::one(),
            reserve_config::default_test_config(),
            interest_rate_config::default_config()
        )
    }

    /// Register the user and also create a default `Profile` with the given name.
    /// We requires that a name is given instead of a default name such as "main" because it might be
    /// possible for user to already have a `ResourceAccount` that collides with our default name.
    public entry fun register_user(
        account: &signer,
        default_profile_name: vector<u8>
    ) {
        profile::init(account);
        profile::new(account, string::utf8(default_profile_name));

        event::emit(RegisterUserEvent {
            user_addr: signer::address_of(account),
            default_profile_name: string::utf8(default_profile_name),
            referrer_addr: option::none(),
        })
    }

    public entry fun register_user_with_referrer(
        account: &signer, 
        default_profile_name: vector<u8>,
        referrer_addr: address
    ) {
        profile::init_with_referrer(account, referrer_addr);
        profile::new(account, string::utf8(default_profile_name));

        event::emit(RegisterUserEvent {
            user_addr: signer::address_of(account),
            default_profile_name: string::utf8(default_profile_name),
            referrer_addr: option::some(referrer_addr),
        })
    }

    /// Add a new `Profile` to a given user.
    public entry fun add_subaccount(
        account: &signer,
        profile_name: vector<u8>,
    ) {
        let profile_name = string::utf8(profile_name);
        profile::new(account, profile_name);

        event::emit(AddSubaccountEvent {
            user_addr: signer::address_of(account),
            profile_name: profile_name,
        })
    }

    /// Mint yield bearing LP tokens for a given user. The minted LP tokens does not increase the borrowing power.
    /// Instead it will be return to user's wallet. If the users would like to increase their borrowing power,
    /// they should use the `deposit` entry function below.
    public entry fun mint<Coin0>(
        account: &signer,
        amount: u64,
    ) {
        let coin = coin::withdraw<Coin0>(account, amount);
        let lp_coin = reserve::mint<Coin0>(coin);
        let lp_amount = coin::value(&lp_coin);

        utils::deposit_coin<LP<Coin0>>(account, lp_coin);

        event::emit(MintLPShareEvent<Coin0> {
            user_addr: signer::address_of(account),
            amount: amount,
            lp_amount: lp_amount,
        })
    }

    /// Redeem the yield bearing LP tokens from a given user.
    public entry fun redeem<Coin0>(
        account: &signer,
        amount: u64,
    ) {
        let lp_coin = coin::withdraw<LP<Coin0>>(account, amount);
        let coin = reserve::redeem<Coin0>(lp_coin);
        let coin_amount = coin::value(&coin);

        utils::deposit_coin<Coin0>(account, coin);

        event::emit(RedeemLPShareEvent<Coin0> {
            user_addr: signer::address_of(account),
            amount: coin_amount,
            lp_amount: amount,
        })
    }

    /// Contribute the yield bearing tokens to increase user's borrowing power.
    /// This function should rarely be used. Use `deposit` directly for simplicity.
    public entry fun add_collateral<Coin0>(
        account: &signer,
        profile_name: vector<u8>,
        amount: u64,
    ) {
        let addr = signer::address_of(account);
        profile::add_collateral(
            addr, &string::utf8(profile_name), reserve::type_info<Coin0>(), amount);

        let lp_coin = coin::withdraw<LP<Coin0>>(account, amount);
        reserve::add_collateral<Coin0>(lp_coin);

        event::emit(AddLPShareEvent<Coin0> {
            user_addr: signer::address_of(account),
            profile_name: string::utf8(profile_name),
            lp_amount: amount,
        })
    }

    /// Withdraw the yield bearing tokens to user's wallet.
    /// This function should rarely be used. Use `withdraw` directly for simplicity.
    public entry fun remove_collateral<Coin0>(
        account: &signer,
        profile_name: vector<u8>,
        amount: u64,
    ) {
        let addr = signer::address_of(account);
        let check_equity = profile::remove_collateral(
            addr, &string::utf8(profile_name), reserve::type_info<Coin0>(), amount);
        profile::check_enough_collateral(check_equity);

        let lp_coin = reserve::remove_collateral<Coin0>(amount);
        utils::deposit_coin<LP<Coin0>>(account, lp_coin);

        event::emit(RemoveLPShareEvent<Coin0> {
            user_addr: signer::address_of(account),
            profile_name: string::utf8(profile_name),
            lp_amount: amount,
        })
    }

    /// Deposit funds into the Aries protocol, this can result in two scenarios:
    ///
    /// 1. User has an existing `Coin0` loan: the amount will first used to repay the loan then the
    ///    remaining part contribute to the collateral.
    ///
    /// 2. User doesn't have an existing loan: all the amount will be contributed to collateral.
    ///
    /// When the amount is `u64::max`, we will repay all the debt without deposit to Aries. This is
    /// so that we don't leave any dust when users try to repay all.
    public entry fun deposit<Coin0>(
        account: &signer,
        profile_name: vector<u8>,
        amount: u64,
        repay_only: bool,
    ) {
        assert!(amount > 0, ECONTROLLER_DEPOSIT_ZERO_AMOUNT);
        let addr = signer::address_of(account);
        deposit_for<Coin0>(account, profile_name, amount, addr, repay_only);
    }

    /// Deposit fund on behalf of someone else, useful when a given profile is insolvent and third party can step in
    /// to repay on behalf of the owner. 
    public fun deposit_for<Coin0>(
        account: &signer,
        profile_name: vector<u8>,
        amount: u64,
        receiver_addr: address,
        repay_only: bool,
    ) {
        let (repay_amount, deposit_amount) = profile::deposit(
            receiver_addr, 
            &string::utf8(profile_name),
            reserve::type_info<Coin0>(), 
            amount,
            repay_only
        );
        let repay_coin = coin::withdraw<Coin0>(account, repay_amount);
        let deposit_coin = coin::withdraw<Coin0>(account, deposit_amount);
        deposit_coin_to_reserve<Coin0>(repay_coin, deposit_coin);

        event::emit(DepositEvent<Coin0> {
            sender: signer::address_of(account),
            receiver: receiver_addr,
            profile_name: string::utf8(profile_name),
            amount_in: amount,
            repay_only: repay_only,
            repay_amount: repay_amount,
            deposit_amount: deposit_amount,
        });
    }

    /// [Deprecated] use `deposit_and_repay_for` instead
    public fun deposit_coin_for<Coin0>(
        addr: address,
        profile_name: &string::String,
        coin: Coin<Coin0>,
    ) {
        deposit_and_repay_for(addr, profile_name, coin);
    }

    public fun deposit_and_repay_for<Coin0>(
        addr: address,
        profile_name: &string::String,
        coin: Coin<Coin0>,
    ): (u64, u64) {
        // We will disable `repay_only` in this case. 
        // Because it would cause remaining coins to be reclaimed after repay. 
        // We cannot drop them and would not add a new address parameter to reclaim them. 
        let (repay_amount, deposit_amount) = profile::deposit(
            addr, profile_name, reserve::type_info<Coin0>(), coin::value(&coin), false
        );

        let repay_coin = coin::extract(&mut coin, repay_amount);
        assert!(coin::value(&coin) == deposit_amount, 0);
        deposit_coin_to_reserve<Coin0>(repay_coin, coin);

        event::emit(DepositRepayForEvent<Coin0> {
            receiver: addr,
            receiver_profile_name: *profile_name,
            deposit_amount: deposit_amount,
            repay_amount: repay_amount,
        });

        (deposit_amount, repay_amount)
    }

    fun deposit_coin_to_reserve<Coin0>(
        repay_coin: Coin<Coin0>,
        deposit_coin: Coin<Coin0>,
    ) {
        let repay_remaining_coin = reserve::repay<Coin0>(repay_coin);
        coin::destroy_zero<Coin0>(repay_remaining_coin);
        if (coin::value(&deposit_coin) > 0) {
            let lp_coin = reserve::mint<Coin0>(deposit_coin);
            reserve::add_collateral<Coin0>(lp_coin);
        } else {
            coin::destroy_zero(deposit_coin);
        }
    }

    /// Withdraw fund into the Aries protocol, there are two scenarios:
    ///
    /// 1. User have an existing `Coin0` deposit: the existing deposit will be withdrawn first, if
    /// it is not enough and user `allow_borrow`, a loan will be taken out.
    ///
    /// 2. User doesn't have an existing `Coin0` deposit: if user `allow_borrow`, a loan will be taken out.
    ///
    /// When the amount is `u64::max`, we will repay all the deposited funds from Aries. This is so
    /// that we don't leave any dust when users try to withdraw all.
    public entry fun withdraw<Coin0>(
        account: &signer,
        profile_name: vector<u8>,
        amount: u64,
        allow_borrow: bool,
    ) {
        let addr = signer::address_of(account);
        let profile_name_str = string::utf8(profile_name);
        let (withdraw_amount, borrow_amount, check_equity) = profile::withdraw(
            addr, &profile_name_str, reserve::type_info<Coin0>(), amount, allow_borrow);
        let referrer = profile::get_user_referrer(addr);

        let withdraw_coin = withdraw_from_reserve(
            withdraw_amount,
            borrow_amount,
            referrer
        );

        let actual_withdraw_amount = coin::value(&withdraw_coin);
        utils::deposit_coin<Coin0>(account, withdraw_coin);
        profile::check_enough_collateral(check_equity);

        event::emit(WithdrawEvent<Coin0> {
            sender: signer::address_of(account),
            profile_name: string::utf8(profile_name),
            amount_in: amount,
            allow_borrow: allow_borrow,
            withdraw_amount: actual_withdraw_amount,
            borrow_amount: borrow_amount,
        });
    }

    fun withdraw_from_reserve<Coin0>(
        withdraw_amount: u64,
        borrow_amount: u64,
        maybe_referrer: Option<address>,
    ): Coin<Coin0> {
        let withdraw_coin = if (withdraw_amount == 0) {
            coin::zero()
        } else {
            let lp_coin = reserve::remove_collateral<Coin0>(withdraw_amount);
            reserve::redeem<Coin0>(lp_coin)
        };

        let borrowed_coin = if (borrow_amount == 0) {
            coin::zero()
        } else {
            reserve::borrow<Coin0>(borrow_amount, maybe_referrer)
        };
        coin::merge<Coin0>(&mut borrowed_coin, withdraw_coin);
        borrowed_coin
    }

    fun liquidate_impl<RepayCoin, WithdrawCoin>(
        liquidator_account: &signer,
        liquidatee_addr: address,
        liquidatee_profile_name: vector<u8>,
        amount: u64,
        redeem_lp: bool
    ) {
        let (actual_repay_amount, withdraw_amount) = profile::liquidate(
            liquidatee_addr,
            &string::utf8(liquidatee_profile_name),
            reserve::type_info<RepayCoin>(), 
            reserve::type_info<WithdrawCoin>(), 
            amount
        );

        let coin = coin::withdraw<RepayCoin>(liquidator_account, actual_repay_amount);
        let remaining_coin = reserve::repay<RepayCoin>(coin);
        let collateral_lp_coin = reserve::remove_collateral<WithdrawCoin>(withdraw_amount);
        let collateral_lp_coin_after_fee = reserve::charge_liquidation_fee(collateral_lp_coin);

        // update amount repaid
        actual_repay_amount = actual_repay_amount - coin::value(&remaining_coin);
        let liquidation_fee_amount = withdraw_amount - coin::value(&collateral_lp_coin_after_fee);

        utils::deposit_coin<RepayCoin>(liquidator_account, remaining_coin);

        let redeem_lp_amount = if (redeem_lp) {
            let redeemed_coin = reserve::redeem(collateral_lp_coin_after_fee);
            let redeemed_amount = coin::value(&redeemed_coin);
            utils::deposit_coin<WithdrawCoin>(liquidator_account, redeemed_coin);
            redeemed_amount
        } else {
            utils::deposit_coin(liquidator_account, collateral_lp_coin_after_fee);
            0
        };

        event::emit(LiquidateEvent<RepayCoin, WithdrawCoin> {
            liquidator: signer::address_of(liquidator_account),
            liquidatee: liquidatee_addr,
            liquidatee_profile_name: string::utf8(liquidatee_profile_name),
            repay_amount_in: amount,
            redeem_lp: redeem_lp,
            repay_amount: actual_repay_amount,
            withdraw_lp_amount: withdraw_amount,
            liquidation_fee_amount: liquidation_fee_amount,
            redeem_lp_amount: redeem_lp_amount,
        })
    }

    public entry fun liquidate<RepayCoin, WithdrawCoin>(
        liquidator_account: &signer,
        liquidatee_addr: address,
        liquidatee_profile_name: vector<u8>,
        amount: u64
    ) {
       liquidate_impl<RepayCoin, WithdrawCoin>(liquidator_account, liquidatee_addr, liquidatee_profile_name, amount, false);
    }

    public entry fun liquidate_and_redeem<RepayCoin, WithdrawCoin>(
        liquidator_account: &signer,
        liquidatee_addr: address,
        liquidatee_profile_name: vector<u8>,
        amount: u64
    ) {
       liquidate_impl<RepayCoin, WithdrawCoin>(liquidator_account, liquidatee_addr, liquidatee_profile_name, amount, true);
    }


    public entry fun hippo_swap<
        InCoin, Y, Z, OutCoin, E1, E2, E3
    >(
        account: &signer,
        profile_name: vector<u8>,
        allow_borrow: bool,
        amount: u64,
        minimum_out: u64,
        num_steps: u8,
        first_dex_type: u8,
        first_pool_type: u64,
        first_is_x_to_y: bool, // first trade uses normal order
        second_dex_type: u8,
        second_pool_type: u64,
        second_is_x_to_y: bool, // second trade uses normal order
        third_dex_type: u8,
        third_pool_type: u64,
        third_is_x_to_y: bool, // second trade uses normal order
    ) {

        let addr = signer::address_of(account);
        let profile_name_str = string::utf8(profile_name);
        let referrer = profile::get_user_referrer(addr);

        let (withdraw_amount, borrow_amount, check_equity) = profile::withdraw(
            addr, &profile_name_str, reserve::type_info<InCoin>(), amount, allow_borrow);
        let input_coin = withdraw_from_reserve<InCoin>(
            withdraw_amount,
            borrow_amount,
            referrer
        );
        let (option_coin1, option_coin2, option_coin3, output_coin) = hippo_aggregator::aggregator::swap_direct<
            InCoin, Y, Z, OutCoin, E1, E2, E3
        >(
            num_steps,
            first_dex_type,
            first_pool_type,
            first_is_x_to_y,
            second_dex_type,
            second_pool_type,
            second_is_x_to_y,
            third_dex_type,
            third_pool_type,
            third_is_x_to_y,
            input_coin
        );

        assert!(coin::value(&output_coin) >= minimum_out, ECONTROLLER_SWAP_MINIMUM_OUT_NOT_MET);

        consume_coin_dust(account, option_coin1);
        consume_coin_dust(account, option_coin2);
        consume_coin_dust(account, option_coin3);

        let (deposit_amount, repay_amount) = deposit_and_repay_for<OutCoin>(addr, &profile_name_str, output_coin);
        profile::check_enough_collateral(check_equity);

        event::emit(SwapEvent<InCoin, OutCoin> {
            sender: addr,
            profile_name: profile_name_str,
            amount_in: amount,
            amount_min_out: minimum_out,
            allow_borrow: allow_borrow,
            in_withdraw_amount: withdraw_amount,
            in_borrow_amount: borrow_amount,
            out_deposit_amount: deposit_amount,
            out_repay_amount: repay_amount,
        });
    }

    fun consume_coin_dust<X>(account: &signer, coin_option: Option<coin::Coin<X>>) {
        if (option::is_some(&coin_option)) {
            let coin = std::option::destroy_some(coin_option);
            if (coin::value(&coin) > 0) {
                utils::deposit_coin(account, coin);
            } else {
                coin::destroy_zero(coin);
            }
        } else {
            option::destroy_none(coin_option)
        }
    }

    public entry fun register_or_update_privileged_referrer(
        admin: &signer,
        claimant_addr: address,
        fee_sharing_percentage: u8
    ) {
        controller_config::register_or_update_privileged_referrer(
            admin,
            claimant_addr,
            fee_sharing_percentage
        );

        event::emit(UpsertPrivilegedReferrerConfigEvent {
            signer_addr: signer::address_of(admin),
            claimant_addr: claimant_addr,
            fee_sharing_percentage: fee_sharing_percentage,
        });
    }

    public entry fun add_reward<ReserveCoin, FarmingType, RewardCoin>(
        admin: &signer,
        amount: u64
    ) {
        controller_config::assert_is_admin(signer::address_of(admin));
        let admin_addr = signer::address_of(admin);
        assert!(coin::balance<RewardCoin>(admin_addr) >= amount, 0);
        reserve::add_reward<ReserveCoin, FarmingType, RewardCoin>(amount);
        let reward_coin = coin::withdraw<RewardCoin>(admin, amount);
        // TODO: init reward container on demand
        reward_container::add_reward<ReserveCoin, FarmingType, RewardCoin>(reward_coin);

        event::emit(AddRewardEvent<ReserveCoin, FarmingType, RewardCoin> {
            signer_addr: signer::address_of(admin),
            amount: amount,
        });
    }

    public entry fun remove_reward<ReserveCoin, FarmingType, RewardCoin>(
        admin: &signer,
        amount: u64
    ) {
        controller_config::assert_is_admin(signer::address_of(admin));
        reserve::remove_reward<ReserveCoin, FarmingType, RewardCoin>(amount);
        let removed_coin = reward_container::remove_reward<ReserveCoin, FarmingType, RewardCoin>(amount);
        utils::deposit_coin<RewardCoin>(admin, removed_coin);

        event::emit(RemoveRewardEvent<ReserveCoin, FarmingType, RewardCoin> {
            signer_addr: signer::address_of(admin),
            amount: amount,
        });
    }

    public entry fun claim_reward<ReserveCoin, FarmingType, RewardCoin>(
        account: &signer,
        profile_name: vector<u8>,
    ) {
        claim_reward_ti<RewardCoin>(
            account,
            profile_name,
            reserve::type_info<ReserveCoin>(),
            type_info::type_of<FarmingType>(),
        );
    }

    public entry fun claim_reward_for_profile<ReserveCoin, FarmingType, RewardCoin>(
        account: &signer,
        profile_name: string::String,
    ) {
        claim_reward_ti<RewardCoin>(
            account,
            *string::bytes(&profile_name),
            reserve::type_info<ReserveCoin>(),
            type_info::type_of<FarmingType>(),
        );
    }

    public fun claim_reward_ti<RewardCoin>(
        account: &signer,
        profile_name: vector<u8>,
        reserve_type: TypeInfo,
        farming_type: TypeInfo,
    ) {
        let addr = signer::address_of(account);
        let profile_name = string::utf8(profile_name);
        let claimable_amount = profile::claim_reward_ti(
            addr,
            &profile_name,
            reserve_type,
            farming_type,
            type_info::type_of<RewardCoin>()
        );
        let reward_coin = reward_container::remove_reward_ti<RewardCoin>(
            reserve_type,
            farming_type,
            claimable_amount
        );
        utils::deposit_coin<RewardCoin>(account, reward_coin);

        event::emit(ClaimRewardEvent<RewardCoin> {
            user_addr: signer::address_of(account),
            profile_name: profile_name,
            reserve_type: reserve_type,
            farming_type: farming_type,
            reward_amount: claimable_amount,
        })
    }

    public entry fun update_reward_rate<ReserveCoin, FarmingType, RewardCoin>(
        admin: &signer,
        reward_per_day: u128,
    ) {
        controller_config::assert_is_admin(signer::address_of(admin));
        let new_config = reserve_farm::new_reward_config(reward_per_day);
        reserve::update_reward_config<ReserveCoin, FarmingType, RewardCoin>(new_config);

        event::emit(UpdateRewardConfigEvent<ReserveCoin, FarmingType, RewardCoin> {
            signer_addr: signer::address_of(admin),
            config: new_config,
        });
    }

    public entry fun update_reserve_config<Coin0>(
        admin: &signer,
        loan_to_value: u8,
        liquidation_threshold: u8,
        liquidation_bonus_bips: u64,
        liquidation_fee_hundredth_bips: u64,
        borrow_factor: u8,
        reserve_ratio: u8,
        borrow_fee_hundredth_bips: u64,
        withdraw_fee_hundredth_bips: u64,
        deposit_limit: u64,
        borrow_limit: u64,
        allow_collateral: bool,
        allow_redeem: bool,
        flash_loan_fee_hundredth_bips: u64
    ) {
        controller_config::assert_is_admin(signer::address_of(admin));
        let new_reserve_config = reserve_config::new_reserve_config(
            loan_to_value,
            liquidation_threshold,
            liquidation_bonus_bips,
            liquidation_fee_hundredth_bips,
            borrow_factor,
            reserve_ratio,
            borrow_fee_hundredth_bips,
            withdraw_fee_hundredth_bips,
            deposit_limit,
            borrow_limit,
            allow_collateral,
            allow_redeem,
            flash_loan_fee_hundredth_bips
        );
        reserve::update_reserve_config<Coin0>(new_reserve_config);

        event::emit(UpdateReserveConfigEvent<Coin0> {
            signer_addr: signer::address_of(admin),
            config: new_reserve_config,
        });
    }

    public entry fun admin_sync_available_cash<Coin0>(admin: &signer) {
        controller_config::assert_is_admin(signer::address_of(admin));
        reserve::sync_cash_available<Coin0>();
    }

    public entry fun update_interest_rate_config<Coin0>(
        admin: &signer,
        min_borrow_rate: u64,
        optimal_borrow_rate: u64,
        max_borrow_rate: u64,
        optimal_utilization: u64
    ) {
        controller_config::assert_is_admin(signer::address_of(admin));
        let new_interest_rate_config = interest_rate_config::new_interest_rate_config(
            min_borrow_rate,
            optimal_borrow_rate,
            max_borrow_rate,
            optimal_utilization
        );
        reserve::update_interest_rate_config<Coin0>(new_interest_rate_config);

        event::emit(UpdateInterestRateConfigEvent<Coin0> {
            signer_addr: signer::address_of(admin),
            config: new_interest_rate_config,
        });
    }

    public entry fun withdraw_borrow_fee<Coin0>(
        admin: &signer
    ) {
        controller_config::assert_is_admin(signer::address_of(admin));
        let fee_coin = reserve::withdraw_borrow_fee<Coin0>();
        utils::deposit_coin<Coin0>(admin, fee_coin);
    }

    public entry fun withdraw_reserve_fee<Coin0>(
        admin: &signer
    ) {
        controller_config::assert_is_admin(signer::address_of(admin));
        let fee_coin = reserve::withdraw_reserve_fee<Coin0>();
        utils::deposit_coin<Coin0>(admin, fee_coin);
    }

    public fun begin_flash_loan<Coin0>(
        account: &signer,
        profile_name: String,
        amount: u64,
    ): (profile::CheckEquity, Coin<Coin0>) {
        let user_addr = signer::address_of(account);
        let referrer = profile::get_user_referrer(user_addr);
        let (withdraw_amount, borrow_amount, check_equity) = profile::withdraw_flash_loan(
            user_addr, &profile_name, reserve::type_info<Coin0>(), amount, true);

        let withdraw_coin = flash_borrow_from_reserve(
            withdraw_amount,
            borrow_amount,
            referrer
        );

        event::emit(BeginFlashLoanEvent<Coin0> {
            user_addr: user_addr,
            profile_name: profile_name,
            amount_in: amount,
            withdraw_amount: withdraw_amount,
            borrow_amount: borrow_amount,
        });

        (check_equity, withdraw_coin)
    }

    fun flash_borrow_from_reserve<Coin0>(
        withdraw_amount: u64,
        borrow_amount: u64,
        maybe_referrer: Option<address>,
    ): Coin<Coin0> {
        let withdraw_coin = if (withdraw_amount == 0) {
            coin::zero()
        } else {
            let lp_coin = reserve::remove_collateral<Coin0>(withdraw_amount);
            reserve::redeem<Coin0>(lp_coin)
        };

        let borrowed_coin = reserve::flash_borrow<Coin0>(borrow_amount, maybe_referrer);
        coin::merge<Coin0>(&mut borrowed_coin, withdraw_coin);
        borrowed_coin
    }

    public fun end_flash_loan<Coin0>(
        receipt: profile::CheckEquity,
        repay_coin: Coin<Coin0>
    ) {
        let (user_addr, profile_name) = profile::read_check_equity_data(&receipt);

        let amount_in = coin::value(&repay_coin);
        let (deposit_amount, repay_amount) = deposit_and_repay_for<Coin0>(user_addr, &profile_name, repay_coin);
        profile::check_enough_collateral(receipt);

        event::emit(EndFlashLoanEvent<Coin0> {
            user_addr: user_addr,
            profile_name: profile_name,
            amount_in: amount_in,
            deposit_amount: deposit_amount,
            repay_amount: repay_amount,
        })
    }

    // --- EMode Admin Operations ---
    public entry fun set_emode_category<OracleType>(
        account: &signer, 
        id: String,
        label: String,
        loan_to_value: u8,
        liquidation_threshold: u8,
        liquidation_bonus_bips: u64
    ) {
        emode_category::set_emode_category<OracleType>(
            account, 
            id, 
            label, 
            loan_to_value, 
            liquidation_threshold, 
            liquidation_bonus_bips
        );

        event::emit(EModeCategorySet {
            signer_addr: signer::address_of(account),
            id: id,
            label: label,
            loan_to_value: loan_to_value,
            liquidation_threshold: liquidation_threshold,
            liquidation_bonus_bips: liquidation_bonus_bips,
            oracle_key_type: type_info::type_name<OracleType>(),
        });
    }

    public entry fun reserve_enter_emode<ReserveType>(account: &signer, emode_id: String) {
        emode_category::reserve_enter_emode<ReserveType>(account, emode_id);
        event::emit(ReserveEModeSet {
            signer_addr: signer::address_of(account),
            reserve_str: type_info::type_name<ReserveType>(),
            emode_id: emode_id,
        });
    }

    public entry fun reserve_exit_emode<ReserveType>(account: &signer) {
        emode_category::reserve_exit_emode<ReserveType>(account);

        event::emit(ReserveEModeSet {
            signer_addr: signer::address_of(account),
            reserve_str: type_info::type_name<ReserveType>(),
            emode_id: string::utf8(b""),
        });
    }

    // --- EMode User Operations ---
    public entry fun enter_emode(account: &signer, profile_name: String, emode_id: String) {
        let user_addr = signer::address_of(account); 
        profile::set_emode(user_addr, &profile_name, option::some(emode_id));
        event::emit(ProfileEModeSet {
            user_addr: user_addr,
            profile_name: profile_name,
            emode_id: emode_id,
        });
    }

    public entry fun exit_emode(account: &signer, profile_name: String) {
        let user_addr = signer::address_of(account); 
        profile::set_emode(user_addr, &profile_name, option::none());
        event::emit(ProfileEModeSet {
            user_addr: user_addr,
            profile_name: profile_name,
            emode_id: string::utf8(b""),
        });
    }
}
