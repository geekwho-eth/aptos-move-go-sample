# Aptos Move Go 示例项目

## 项目简介

本项目是一个基于 [Aptos](https://aptos.dev/) 区块链的 Go 语言示例项目，展示了如何使用 Aptos Go SDK 与 Aptos 区块链进行交互。项目主要包含以下功能：

- 调用链上 View 函数以查询数据。
- 解析链上返回的数据结构。
- 使用 Aptos Go SDK 构建和发送请求。

## 文件结构

- `ariesmarket/call_view_func.go`  
  包含调用链上 View 函数的示例代码，展示了如何查询用户是否注册以及可领取的奖励金额。

## 主要功能

### ariesmarkets 主网合约调用示例

### 1. 查询用户是否注册

函数 `callViewFuncIsRegistered` 用于调用链上 View 函数，检查指定用户是否已注册。

### 2. 查询可领取奖励金额

函数 `callViewFuncClaimableRewardAmounts` 用于调用链上 View 函数，查询用户的可领取奖励金额，并解析返回的数据。

### 3.1 查询用户存入以及奖励的金额明细

函数 `callViewFuncProfileDeposit` 用于调用链上 View 函数，查询用户存入以及奖励的金额明细，并解析返回的数据。

### 3.2 数据解析

函数 `parseProfileDepositData` 用于解析链上返回的复杂数据结构。

### 4. Hex 解码工具

函数 `decodeHexToStr` 用于将十六进制字符串解码为普通字符串，便于解析链上返回的编码数据。

## 使用方法

1. 确保已安装 Go 语言环境。
2. 克隆本项目到本地：

   ```bash
   git clone https://github.com/geekwho-eth/aptos-move-go-sample.git
   ```

3. 安装依赖：

   ```bash
   go mod tidy
   ```

4. 修改代码中的 Aptos 节点 URL 和其他参数以适配您的环境。
5. 运行示例代码：

   ```bash
   go run ariesmarket/call_view_func.go
   ```

## 依赖

- [Aptos Go SDK](https://github.com/aptos-labs/aptos-go-sdk)

## 注意事项

- 确保提供的模块地址、函数名和用户地址是有效的。
- 如果需要与主网交互，请确保使用有效的主网节点 URL。

## 贡献

欢迎提交 Issue 或 Pull Request 来改进本项目。

## 许可证

本项目基于 MIT 许可证开源。
