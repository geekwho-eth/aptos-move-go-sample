module aries::emode_category {
    use std::signer;
    use std::option::{Self, Option};
    use std::string::{String, Self};
    use aptos_std::type_info::{Self, TypeInfo};
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_std::table_with_length::{Self, TableWithLength};

    friend aries::controller;
    friend aries::reserve;
    friend aries::profile;

    #[test_only]
    friend aries::profile_tests;
    #[test_only]
    friend aries::controller_test;
    #[test_only]
    friend aries::test_utils;
    #[test_only]
    friend aries::emode_category_tests;

    /// --- Errors ---
    
    /// Admin mismatch.
    const EADMIN_MISMATCH: u64 = 1;
    /// Admin mismatch.
    const EEMODE_STORE_ALREADY_EXIST: u64 = 2;
    /// Invalid emode id.
    const EINVALID_EMODE_ID: u64 = 3;
    /// EMode doesn't exist.
    const EEMODE_NOT_EXIST: u64 = 4;
    /// Reserve has been set to `emode`.
    const ERESERVE_IN_EMODE: u64 = 5;
    /// Profile has been set to `emode`.
    const EPROFILE_IN_EMODE: u64 = 6;
    /// Invalid emode asset configuration.
    const EEMODE_CONFIG_VIOLATION: u64 = 7;

    struct DummyOracleKey {}

    struct EModeCategories has key {
        admin: address,
        /// Mapping from `category id` to `EMode` configuration.
        /// Using `String` as the type of `category id` for better readability.
        categories: SimpleMap<String, EMode>,
        profile_emodes: SmartTable<address, String>,
        reserve_emodes: TableWithLength<TypeInfo, String>
    }

    struct EMode has store, drop, copy {
        /// EMode label for readability.
        label: String,
        /// Price oracle key type.
        oracle_key_type: Option<TypeInfo>,
        /// Loan to value ratio.(80 means 80%)
        loan_to_value: u8,
        /// Liquidation threshold.(75 means 75%)
        liquidation_threshold: u8,
        /// The bonus basis point that the liquidator get.(200 means 2%)
        liquidation_bonus_bips: u64
    }

    // --- Initiliaze ---

    public(friend) fun init(account: &signer, admin: address) {
        assert!(signer::address_of(account) == @aries, EADMIN_MISMATCH);
        assert!(!exists<EModeCategories>(signer::address_of(account)), EEMODE_STORE_ALREADY_EXIST);
        move_to(
            account, 
            EModeCategories {
                admin: admin,
                categories: simple_map::new(),
                profile_emodes: smart_table::new(),
                reserve_emodes: table_with_length::new(),
            }
        );
    }

    // --- Admin Operations ---
    public(friend) fun set_emode_category<OracleType>(
        account: &signer, 
        id: String,
        label: String,
        loan_to_value: u8,
        liquidation_threshold: u8,
        liquidation_bonus_bips: u64
    ) acquires EModeCategories {
        check_config(
            loan_to_value,
            liquidation_threshold,
            liquidation_bonus_bips
        );
        assert!(string::length(&id) > 0, EINVALID_EMODE_ID);

        let bundle = borrow_global_mut<EModeCategories>(@aries);
        assert!(signer::address_of(account) == bundle.admin, EADMIN_MISMATCH);

        let oracle_key_type = if (type_info::type_of<OracleType>() == type_info::type_of<DummyOracleKey>()) {
            option::none()
        } else {
            option::some(type_info::type_of<OracleType>())
        };

        if (simple_map::contains_key(&bundle.categories, &id)) {
            let emode = simple_map::borrow_mut(&mut bundle.categories, &id);
            emode.loan_to_value = loan_to_value;
            emode.liquidation_threshold = liquidation_threshold;
            emode.liquidation_bonus_bips = liquidation_bonus_bips;
            emode.oracle_key_type = oracle_key_type;
            emode.label = label;
        } else {
            simple_map::add(
                &mut bundle.categories, 
                id, 
                EMode {
                    label: label,
                    oracle_key_type: oracle_key_type,
                    loan_to_value: loan_to_value,
                    liquidation_threshold: liquidation_threshold,
                    liquidation_bonus_bips: liquidation_bonus_bips
                }
            );
        }
    }

    public(friend) fun reserve_enter_emode<ReserveType>(account: &signer, emode_id: String) acquires EModeCategories {
        let bundle = borrow_global_mut<EModeCategories>(@aries);
        assert!(signer::address_of(account) == bundle.admin, EADMIN_MISMATCH);

        assert_emode_exist(&bundle.categories, &emode_id);

        let reserve_type = type_info::type_of<ReserveType>();
         
        assert!(!table_with_length::contains(&bundle.reserve_emodes, reserve_type), ERESERVE_IN_EMODE);
        table_with_length::add(&mut bundle.reserve_emodes, reserve_type, emode_id);
    }

    public(friend) fun reserve_exit_emode<ReserveType>(account: &signer) acquires EModeCategories {
        let bundle = borrow_global_mut<EModeCategories>(@aries);
        assert!(signer::address_of(account) == bundle.admin, EADMIN_MISMATCH);

        let reserve_type = type_info::type_of<ReserveType>();
        let exist_emode_id = table_with_length::borrow(&bundle.reserve_emodes, reserve_type);

        assert_emode_exist(&bundle.categories, exist_emode_id);
        table_with_length::remove(&mut bundle.reserve_emodes, reserve_type);
    }

    public(friend) fun profile_enter_emode(profile_account: address, emode_id: String) acquires EModeCategories {
        let bundle = borrow_global_mut<EModeCategories>(@aries);

        assert_emode_exist(&bundle.categories, &emode_id);

        assert!(!smart_table::contains(&bundle.profile_emodes, profile_account), EPROFILE_IN_EMODE);
        smart_table::add(&mut bundle.profile_emodes, profile_account, emode_id);
    }

    public(friend) fun profile_exit_emode(profile_account: address) acquires EModeCategories {
        let bundle = borrow_global_mut<EModeCategories>(@aries);
        let exist_emode_id = smart_table::borrow(&bundle.profile_emodes, profile_account);

        assert_emode_exist(&bundle.categories, exist_emode_id);
        smart_table::remove(&mut bundle.profile_emodes, profile_account);
    }

    public(friend) fun reserve_emode_t(reserve_type: TypeInfo): Option<String> acquires EModeCategories {
        let bundle = borrow_global<EModeCategories>(@aries);
        if (table_with_length::contains(&bundle.reserve_emodes, reserve_type)) {
            option::some(*table_with_length::borrow(&bundle.reserve_emodes, reserve_type))
        } else {
            option::none()
        }
    }

    public(friend) fun reserve_in_emode_t(emode_id: &String, reserve_type: TypeInfo): bool acquires EModeCategories {
        let bundle = borrow_global<EModeCategories>(@aries);
        if (table_with_length::contains(&bundle.reserve_emodes, reserve_type)) {
            *table_with_length::borrow(&bundle.reserve_emodes, reserve_type) == *emode_id
        } else {
            false
        }
    }

    public(friend) fun emode_loan_to_value(emode_id: String): u8 acquires EModeCategories {
        let bundle = borrow_global<EModeCategories>(@aries);

        simple_map::borrow(&bundle.categories, &emode_id).loan_to_value
    }

    public(friend) fun emode_liquidation_bonus_bips(emode_id: String): u64 acquires EModeCategories {
        let bundle = borrow_global<EModeCategories>(@aries);

        simple_map::borrow(&bundle.categories, &emode_id).liquidation_bonus_bips
    }

    public(friend) fun emode_liquidation_threshold(emode_id: String): u8 acquires EModeCategories {
        let bundle = borrow_global<EModeCategories>(@aries);

        simple_map::borrow(&bundle.categories, &emode_id).liquidation_threshold
    }

    public(friend) fun emode_oracle_key_type(emode_id: String): Option<TypeInfo> acquires EModeCategories {
        let bundle = borrow_global<EModeCategories>(@aries);

        simple_map::borrow(&bundle.categories, &emode_id).oracle_key_type
    }

    public(friend) fun extract_emode(emode: EMode): (String, Option<TypeInfo>, u8, u8, u64) {
        (emode.label, emode.oracle_key_type, emode.loan_to_value, emode.liquidation_threshold, emode.liquidation_bonus_bips)
    }

    fun assert_emode_exist(categories: &SimpleMap<String, EMode>, emodeId: &String) {
        assert!(simple_map::contains_key(categories, emodeId), EEMODE_NOT_EXIST);
    }

    fun check_config(
        loan_to_value: u8,
        liquidation_threshold: u8,
        liquidation_bonus_bips: u64
    ) {
        assert!(0 <= loan_to_value && loan_to_value <= 100, EEMODE_CONFIG_VIOLATION);
        assert!(0 <= liquidation_threshold && liquidation_threshold <= 100, EEMODE_CONFIG_VIOLATION);
        assert!(loan_to_value < liquidation_threshold, EEMODE_CONFIG_VIOLATION);
        assert!(0 <= liquidation_bonus_bips && liquidation_bonus_bips <= 10000, EEMODE_CONFIG_VIOLATION);
    }

    // --- VIEW FUNCTIONS ---

    #[view]
    public fun profile_emode(profile_account: address): Option<String> acquires EModeCategories {
        let bundle = borrow_global<EModeCategories>(@aries);
        if (smart_table::contains(&bundle.profile_emodes, profile_account)) {
            option::some(*smart_table::borrow(&bundle.profile_emodes, profile_account))
        } else {
            option::none()
        }
    }

    #[view]
    public fun reserve_emode<ReserveType>(): Option<String> acquires EModeCategories {
        reserve_emode_t(type_info::type_of<ReserveType>())
    }

    #[view]
    public fun reserve_in_emode<ReserveType>(emode_id: String): bool acquires EModeCategories {
        reserve_in_emode_t(&emode_id, type_info::type_of<ReserveType>())
    }

    #[view]
    public fun emode_config(emode_id: String): EMode acquires EModeCategories {
        let bundle = borrow_global<EModeCategories>(@aries);

        *simple_map::borrow(&bundle.categories, &emode_id)
    }

    #[view]
    public fun emode_categoies_ids(): vector<String> acquires EModeCategories {
        let registry = borrow_global<EModeCategories>(@aries);
        simple_map::keys(&registry.categories)
    }
}