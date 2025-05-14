//! Controller/Market-wide config storage & access handles
module aries::controller_config {
    use std::signer;
    use aries::referral::{Self, ReferralDetails};

    friend aries::controller;
    #[test_only]
    friend aries::referral_tests;
    #[test_only]
    friend aries::test_utils;

    /// `ControllerConfig` is not set.
    const ECONTROLLER_NO_CONFIG: u64 = 1;

    /// Reserve admin mismatch.
    const ECONTROLLER_ADMIN_MISMATCH: u64 = 2;

    /// When the account is not Aries Markets Account.
    const ERESERVE_NOT_ARIES: u64 = 3;

    struct ControllerConfig has key {
        admin: address,
        referral: ReferralDetails,
    }

    public(friend) fun init_config(account: &signer, admin: address) {
        assert!(signer::address_of(account) == @aries, ERESERVE_NOT_ARIES);
        move_to(
          account, 
          ControllerConfig{
            admin,
            referral: referral::new_referral_details()
          }
        );
    }

    fun assert_config_present() {
        assert!(exists<ControllerConfig>(@aries), ECONTROLLER_NO_CONFIG);
    }

    #[test_only]
    public fun config_present(addr: address): bool {
        exists<ControllerConfig>(addr)
    }

    public fun is_admin(addr: address): bool acquires ControllerConfig {
        assert_config_present();
        let config = borrow_global<ControllerConfig>(@aries);
        return config.admin == addr
    }

    public fun assert_is_admin(addr: address) acquires ControllerConfig {
        assert!(is_admin(addr), ECONTROLLER_ADMIN_MISMATCH);
    }

    public fun find_referral_fee_sharing_percentage(
        referrer: address
    ): u8 acquires ControllerConfig {
        assert_config_present();
        let config = borrow_global<ControllerConfig>(@aries);
        referral::find_fee_sharing_percentage(&config.referral, referrer)
    }

    public(friend) fun register_or_update_privileged_referrer(
        admin: &signer,
        claimant_addr: address, 
        fee_sharing_percentage: u8
    ) acquires ControllerConfig {
        assert_is_admin(signer::address_of(admin));

        let config = borrow_global_mut<ControllerConfig>(@aries);
        referral::register_or_update_privileged_referrer(
            &mut config.referral,
            claimant_addr,
            fee_sharing_percentage
        );
    }
}