package ariesmarket

import (
	"log"
	"testing"

	aptos "github.com/aptos-labs/aptos-go-sdk"
	. "github.com/smartystreets/goconvey/convey"
)

func Test_callViewFuncIsRegistered(t *testing.T) {
	Convey("Scenario: 测试 callViewFuncIsRegistered", t, func() {
		Convey("Background: 执行 callViewFuncIsRegistered", func() {
			moduleAddress := "0x9770fa9c725cbd97eb50b2be5f7416efdfd1f1554beb0750d4dae4c64e860da3"
			moduleName := "profile"
			functionName := "is_registered"
			userAddress := "0x50c24e02543868a0047f7765883456b88aba823f7263d616efdfd4e8143863d7"
			got := callViewFuncIsRegistered(moduleAddress, moduleName, functionName, userAddress)
			log.Println(got)
			So(got, ShouldBeTrue)

			userAddress = "0x292a8072c5d6d530ac63b17d79c7a9d5fa513430af0648b19cc01eaaefd25f68"
			got = callViewFuncIsRegistered(moduleAddress, moduleName, functionName, userAddress)
			log.Println(got)
			So(got, ShouldBeTrue)
		})
	})
}

func Test_callViewFuncClaimableRewardAmounts(t *testing.T) {
	Convey("Scenario: 测试 callViewFuncClaimableRewardAmounts", t, func() {
		Convey("Background: 执行 callViewFuncClaimableRewardAmounts", func() {
			moduleAddress := "0x9770fa9c725cbd97eb50b2be5f7416efdfd1f1554beb0750d4dae4c64e860da3"
			moduleName := "profile"
			functionName := "claimable_reward_amounts"
			userAddress := "0x292a8072c5d6d530ac63b17d79c7a9d5fa513430af0648b19cc01eaaefd25f68"
			// 该参数为自己在帐户中心创建的帐户名，需替换为上面地址对应的
			profileName := "Main Account"
			got := callViewFuncClaimableRewardAmounts(moduleAddress, moduleName, functionName, userAddress, profileName)
			So(got, ShouldNotBeEmpty)
		})
	})
}

func Test_callViewFuncProfileDeposit(t *testing.T) {
	Convey("Scenario: 测试 callViewFuncProfileDeposit", t, func() {
		Convey("Background: 执行 callViewFuncProfileDeposit", func() {
			moduleAddress := "0x9770fa9c725cbd97eb50b2be5f7416efdfd1f1554beb0750d4dae4c64e860da3"
			moduleName := "profile"
			functionName := "profile_deposit"
			// https://explorer.aptoslabs.com/txn/2718467710/events?network=mainnet
			userAddress := "0x292a8072c5d6d530ac63b17d79c7a9d5fa513430af0648b19cc01eaaefd25f68"
			// 该参数为自己在帐户中心创建的帐户名，需替换为上面地址对应的 profile name
			profileName := "Main Account"

			// APT
			typeTag := []aptos.TypeTag{aptos.AptosCoinTypeTag}
			got := callViewFuncProfileDeposit(
				moduleAddress,
				moduleName,
				functionName,
				userAddress,
				profileName,
				typeTag,
			)
			So(got, ShouldNotBeEmpty)

			// USDC
			//usdcCoin := "0x9770fa9c725cbd97eb50b2be5f7416efdfd1f1554beb0750d4dae4c64e860da3::wrapped_coins::WrappedUSDC"

			var typeTagAddr aptos.AccountAddress
			usdcAddr := "0x9770fa9c725cbd97eb50b2be5f7416efdfd1f1554beb0750d4dae4c64e860da3"
			if err := typeTagAddr.ParseStringRelaxed(usdcAddr); err != nil {
				log.Printf("invalid module address: %v err: %s", moduleAddress, err)
			}

			coinTypeTag := aptos.TypeTag{
				Value: &aptos.StructTag{
					Address: typeTagAddr,
					Module:  "wrapped_coins",
					Name:    "WrappedUSDC",
				},
			}
			typeTag = []aptos.TypeTag{coinTypeTag}
			got = callViewFuncProfileDeposit(
				moduleAddress,
				moduleName,
				functionName,
				userAddress,
				profileName,
				typeTag,
			)
			So(got, ShouldNotBeEmpty)

			// USDT
			//usdtCoin := "0x9770fa9c725cbd97eb50b2be5f7416efdfd1f1554beb0750d4dae4c64e860da3::fa_to_coin_wrapper::WrappedUSDT"

			coinTypeTag = aptos.TypeTag{
				Value: &aptos.StructTag{
					Address: typeTagAddr,
					Module:  "fa_to_coin_wrapper",
					Name:    "WrappedUSDT",
				},
			}

			typeTag = []aptos.TypeTag{coinTypeTag}
			got = callViewFuncProfileDeposit(
				moduleAddress,
				moduleName,
				functionName,
				userAddress,
				profileName,
				typeTag,
			)
			So(got, ShouldNotBeEmpty)
		})
	})
}
