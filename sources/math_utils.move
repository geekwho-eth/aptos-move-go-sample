//! This modules contains some frequently used math calculation functions for the 
module aries::math_utils {
    use decimal::decimal::{Self, Decimal};

    /// Max `u64` value.
    const U64_MAX: u64 = 18446744073709551615;

    public fun mul_millionth_u64(val: u64, millionth_val: u64): u64 {
        decimal_mul_as_u64(
            decimal::from_u64(val),
            decimal::from_millionth((millionth_val as u128))
        )
    }

    public fun mul_percentage_u64(val: u64, percentage_val: u64): u64 {
        decimal_mul_as_u64(
            decimal::from_u64(val),
            decimal::from_percentage((percentage_val as u128))
        )
    }

    fun decimal_mul_as_u64(a: Decimal, b: Decimal): u64 {
        decimal::as_u64(decimal::mul(a, b))
    }

    public fun u64_max(): u64 {
        U64_MAX
    }
}