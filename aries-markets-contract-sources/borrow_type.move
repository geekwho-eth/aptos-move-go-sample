//! Borrow type constants.
module aries::borrow_type {
    const NORMAL_BORROW_TYPE: u8 = 0;

    const FLASH_BORROW_TYPE: u8 = 1;

    #[view]
    public fun normal_borrow_type(): u8 {
        NORMAL_BORROW_TYPE
    }

    #[view]
    public fun flash_borrow_type(): u8 {
        FLASH_BORROW_TYPE
    }

    #[view]
    public fun normal_borrow_type_str(): std::string::String {
        std::string::utf8(b"NORMAL_BORROW_TYPE")
    }

    #[view]
    public fun flash_borrow_type_str(): std::string::String {
        std::string::utf8(b"FLASH_BORROW_TYPE")
    }

    #[view]
    public fun borrow_type_str(borrow_type: u8): std::string::String {
        if (borrow_type == normal_borrow_type()) {
            normal_borrow_type_str()
        } else if (borrow_type == flash_borrow_type()) {
            flash_borrow_type_str()
        } else {
            std::string::utf8(b"UNKNOWN_BORROW_TYPE")
        }
    }
}