//! The referral module for integrators and referrers.
module aries::referral {
    use std::option::{Self, Option};
    use aptos_std::table_with_length::{Self as table, TableWithLength};

    friend aries::controller_config;

    /// When cannot find a referral config with specified key
    const EREFERRAL_NOT_FOUND: u64 = 0;

    /// Approve-free fee sharing percentage.
    /// If we cannot find a custom config for an address, it has the default sharing percentage.
    const DEFAULT_FEE_SHARING_PERCENTAGE: u8 = 20;

    struct ReferralConfig has store, copy, drop {
        /// Percentage of fee to be distributed for borrowings with this referrer.
        fee_sharing_percentage: u8,
    }

    struct ReferralDetails has store {
        /// Maps referrer's address to configs
        configs: TableWithLength<address, ReferralConfig>
    }

    public fun fee_sharing_percentage(config: &ReferralConfig): u8 {
        config.fee_sharing_percentage
    }

    public fun new_referral_details(): ReferralDetails {
        ReferralDetails {
            configs: table::new()
        }
    }

    public(friend) fun register_or_update_privileged_referrer(
        referral_details: &mut ReferralDetails,
        claimant: address,
        fee_sharing_percentage: u8,
    ) {
        assert!(fee_sharing_percentage <= 100, 0);
        let referral_config = table::borrow_mut_with_default(
            &mut referral_details.configs,
            claimant,
            ReferralConfig {
                fee_sharing_percentage
            }
        );
        referral_config.fee_sharing_percentage = fee_sharing_percentage;
    }

    public fun find_referral_config(
        referral_details: &ReferralDetails, 
        referrer: address,
    ): Option<ReferralConfig> {
        if (table::contains(&referral_details.configs, referrer)) {
            let ret = *table::borrow(&referral_details.configs, referrer);
            option::some<ReferralConfig>(ret)
        } else {
            option::none<ReferralConfig>()
        }
    }

    public fun find_fee_sharing_percentage(
        referral_details: &ReferralDetails,
        referrer: address
    ): u8 {
        let maybe_config = find_referral_config(referral_details, referrer);
        if (option::is_some(&maybe_config)) {
            fee_sharing_percentage(option::borrow(&maybe_config))
        } else {
            DEFAULT_FEE_SHARING_PERCENTAGE
        }
    }
}