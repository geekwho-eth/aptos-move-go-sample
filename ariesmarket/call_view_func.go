package ariesmarket

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"reflect"
	"strconv"
	"strings"

	"github.com/aptos-labs/aptos-go-sdk/bcs"

	aptos "github.com/aptos-labs/aptos-go-sdk"
)

func callViewFuncIsRegistered(moduleAddress, moduleName, functionName, userAddress string) bool {
	// Create an Aptos client
	client, err := aptos.NewClient(aptos.MainnetConfig) // Replace with your Aptos node URL
	if err != nil {
		log.Printf("Failed to create Aptos client: %v", err)
		return false
	}
	// Define the function arguments according to the ABI
	accountAddress := aptos.AccountAddress{}
	err = accountAddress.ParseStringRelaxed(userAddress)
	if err != nil {
		log.Printf("ParseStringRelaxed get err %s", err)
		return false
	}

	callFunc := fmt.Sprintf("%s::%s::%s", moduleAddress, moduleName, functionName)
	log.Printf("call %s", callFunc)

	parseModuleAddress := aptos.AccountAddress{}
	_ = parseModuleAddress.ParseStringRelaxed(moduleAddress)

	payload := &aptos.ViewPayload{
		Module: aptos.ModuleId{
			Address: parseModuleAddress, // 模块地址
			Name:    moduleName,         // 模块
		},
		Function: functionName, // 调用函数
		ArgTypes: []aptos.TypeTag{},
		Args:     [][]byte{accountAddress[:]},
	}

	vals, err := client.View(payload)
	if err != nil {
		log.Printf("调用 view 函数失败: %v", err)
		return false
	}

	got, ok := vals[0].(bool)
	if !ok {
		log.Println("call View return convert fail")
		return false
	}
	return got
}

type Reward struct {
}

type TypeInfo struct {
	AccountAddress string `json:"account_address"`
	ModuleName     string `json:"module_name"`
	StructName     string `json:"struct_name"`
}

func callViewFuncClaimableRewardAmounts(moduleAddress, moduleName, functionName, userAddress, profileName string) Reward {
	var reward Reward
	// Create an Aptos client
	client, err := aptos.NewClient(aptos.MainnetConfig) // Replace with your Aptos node URL
	if err != nil {
		log.Printf("Failed to create Aptos client: %v", err)
		return reward
	}
	// Define the function arguments according to the ABI
	userAddr := aptos.AccountAddress{}
	err = userAddr.ParseStringRelaxed(userAddress)
	if err != nil {
		log.Printf("invalid user address: %v err: %s", userAddress, err)
		return reward
	}

	// 3. 构造字符串参数（Move 中的 0x1::string::String）
	stringArg := []byte(profileName)

	accountNameBytes, err := bcs.SerializeBytes(stringArg)
	if err != nil {
		log.Printf("SerializeBytes get err %s", err)
		return reward
	}

	var modAddr aptos.AccountAddress
	if err := modAddr.ParseStringRelaxed(moduleAddress); err != nil {
		log.Printf("invalid module address: %v err: %s", moduleAddress, err)
		return reward
	}

	payload := &aptos.ViewPayload{
		Module: aptos.ModuleId{
			Address: modAddr,    // 模块地址
			Name:    moduleName, // 模块
		},
		Function: functionName, // 调用函数
		Args:     [][]byte{userAddr[:], accountNameBytes},
		//ArgTypes: []aptos.TypeTag{aptos.AptosCoinTypeTag},
	}

	resp, err := client.View(payload)
	if err != nil {
		log.Printf("调用 view 函数失败: %v", err)
		return reward
	}

	parseClaimableRewardAmountsData(resp)

	return reward
}

func parseClaimableRewardAmountsData(resp []any) {
	if len(resp) != 2 {
		log.Println("Unexpected view return count")
		return
	}
	rawTypeInfos, ok := resp[0].([]interface{})
	if !ok {
		log.Println("Invalid type info vector")
		return
	}
	typeInfos := []TypeInfo{}
	for _, item := range rawTypeInfos {
		bytesItem, _ := json.Marshal(item)
		var info TypeInfo
		_ = json.Unmarshal(bytesItem, &info)
		// decode hex to string if needed
		info.ModuleName = decodeHexToStr(info.ModuleName)
		info.StructName = decodeHexToStr(info.StructName)
		typeInfos = append(typeInfos, info)
	}
	log.Printf("typeInfos %+v", typeInfos)

	// ✅ 解析 vector<u64>
	rawU64s, ok := resp[1].([]interface{})
	if !ok {
		log.Println("Invalid u64 vector")
		return
	}
	u64s := []uint64{}
	for _, v := range rawU64s {
		strVal, _ := v.(string)
		u, _ := strconv.ParseUint(strVal, 10, 64)
		u64s = append(u64s, u)
	}
	log.Printf("u64s %+v", u64s)
}

func decodeHexToStr(hexStr string) string {
	if strings.HasPrefix(hexStr, "0x") {
		hexStr = hexStr[2:]
	}
	bytes, err := hex.DecodeString(hexStr)
	if err != nil {
		return hexStr
	}
	return string(bytes)
}

func callViewFuncProfileDeposit(moduleAddress, moduleName, functionName, userAddress, profileName string, typeTag []aptos.TypeTag) Reward {
	var reward Reward
	// Create an Aptos client
	client, err := aptos.NewClient(aptos.MainnetConfig) // Replace with your Aptos node URL
	if err != nil {
		log.Printf("Failed to create Aptos client: %v", err)
		return reward
	}
	// Define the function arguments according to the ABI
	userAddr := aptos.AccountAddress{}
	err = userAddr.ParseStringRelaxed(userAddress)
	if err != nil {
		log.Printf("invalid user address: %v err: %s", userAddress, err)
		return reward
	}

	// 3. 构造字符串参数（Move 中的 0x1::string::String）
	stringArg := []byte(profileName)

	accountNameBytes, err := bcs.SerializeBytes(stringArg)
	if err != nil {
		log.Printf("SerializeBytes get err %s", err)
		return reward
	}

	var modAddr aptos.AccountAddress
	if err := modAddr.ParseStringRelaxed(moduleAddress); err != nil {
		log.Printf("invalid module address: %v err: %s", moduleAddress, err)
		return reward
	}

	payload := &aptos.ViewPayload{
		Module: aptos.ModuleId{
			Address: modAddr,    // 模块地址
			Name:    moduleName, // 模块
		},
		Function: functionName, // 调用函数
		Args:     [][]byte{userAddr[:], accountNameBytes},
		ArgTypes: typeTag,
	}

	resp, err := client.View(payload)
	if err != nil {
		log.Printf("调用 view 函数失败: %v", err)
		return reward
	}

	parseProfileDepositData(resp)

	return reward
}

func parseProfileDepositData(resp []any) {
	if len(resp) != 2 {
		log.Println("Unexpected view return count")
		return
	}
	log.Printf("resp %+v", resp)
	fmt.Printf("resp 的类型 (reflect.TypeOf): %v\n", reflect.TypeOf(resp[0]))
	// ✅ 解析 vector<u64>
	u64s, ok := resp[0].(string)
	if !ok {
		log.Println("Invalid u64 vector")
		return
	}
	log.Printf("u64s %+v", u64s)

	// ✅ 解析 vector<u64>
	u64s, ok = resp[1].(string)
	if !ok {
		log.Println("Invalid u64 vector")
		return
	}
	log.Printf("u64s %+v", u64s)
}
