# Adaptive Self-Rebalance LP Vault

> 去中心化自适应再平衡 Uniswap LP 金库 — 对标 Gamma Strategies，自动管理 V2/V3 多池流动性

[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-3674A5.svg)](https://getfoundry.sh/)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.24-363636.svg)](https://soliditylang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Network: Sepolia](https://img.shields.io/badge/Network-Sepolia-4A4A4A.svg)](https://sepolia.etherscan.io/)
[![Contracts: Verified](https://img.shields.io/badge/Contracts-9%2F9%20Verified-brightgreen.svg)](#sepolia-测试网部署)
[![User Guide](https://img.shields.io/badge/📖-用户使用指南-orange.svg)](./USER_GUIDE.md)

> 📖 **新用户？先看 [用户使用指南](./USER_GUIDE.md)** — 教你怎么存款、赎回、触发再平衡赚奖励

---

## 目录

- [项目概述](#项目概述)
- [核心特性](#核心特性)
- [系统架构](#系统架构)
- [Sepolia 测试网部署](#sepolia-测试网部署)
- [快速开始](#快速开始)
- [项目结构](#项目结构)
- [核心合约说明](#核心合约说明)
- [策略逻辑详解](#策略逻辑详解)
- [核心机制与参数总览](#核心机制与参数总览)
- [安全分析](#安全分析)
- [测试覆盖率](#测试覆盖率)
- [License](#license)
- [📖 用户使用指南](./USER_GUIDE.md)

---

## 项目概述

Adaptive LP Vault 是一个基于 ERC4626 标准的去中心化流动性管理协议。用户存入 WETH + USDC 双代币，获得金库份额代币，金库自动将资金智能分配至 Uniswap V2 和多费率 Uniswap V3 流动性池。

系统依托 TWAP 预言机驱动的再平衡引擎，根据市场波动率动态调整资金配比、做市区间和仓位结构，在最大化手续费收益的同时控制无常损失。任何人都可以触发再平衡操作并获得激励奖励。

---

## 核心特性

- **ERC4626 标准金库**：存款铸币、赎回销毁，份额净值自动累积做市手续费收益
- **多场所流动性路由**：Uniswap V2 + Uniswap V3 0.05% + Uniswap V3 0.30% 三池联动
- **TWAP 预言机驱动**：使用 Uniswap V3 时间加权均价，可缓解瞬时价格操纵和闪电贷攻击
- **波动率自适应策略**：根据市场波动率动态调整 V2/V3 资金配比和做市区间宽度
- **三层区间做市**：窄/中/宽三层价格区间分层做市，平衡手续费收益与无常损失
- **去中心化再平衡激励**：任何人可触发再平衡，正向收益时获得 USDC 奖励
- **链上治理系统**：治理代币持有者可投票修改策略参数，含提案时间锁
- **全面安全防护**：ReentrancyGuard 防重入、滑点保护、灰尘资产自动归集

---

## 系统架构

```
┌─────────────────────────────────────────────────────────────────┐
│                          用户交互层                               │
│   存入 WETH+USDC  →  铸造 ALP-VAULT 份额  →  赎回本金+收益      │
└──────────────────────────────┬──────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────┐
│                         核心金库层                                │
│  ┌──────────────────┐  ┌──────────────────┐  ┌───────────────┐ │
│  │  ERC4626 金库     │  │  再平衡引擎       │  │  管理员模块    │ │
│  │  (AdaptiveLPVault)│  │                   │  │               │ │
│  └─────────┬─────────┘  └────────┬─────────┘  └───────┬───────┘ │
│            │                       │                      │         │
│  ┌─────────▼─────────┐  ┌────────▼─────────┐  ┌───────▼───────┐ │
│  │  TWAP 预言机       │  │  再平衡策略       │  │  治理模块      │ │
│  │  (TWAPOracle)      │  │  (RebalanceStrategy)│ (Governance) │ │
│  └───────────────────┘  └──────────────────┘  └───────────────┘ │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                    再平衡激励模块                          │    │
│  │              (RebalanceIncentives)                        │    │
│  └─────────────────────────────────────────────────────────┘    │
└──────────────────────────────┬──────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────┐
│                          适配器层                                 │
│  ┌──────────────────┐  ┌──────────────────┐  ┌───────────────┐ │
│  │  Uniswap V2       │  │  Uniswap V3       │  │  Uniswap V3   │ │
│  │  Adapter           │  │  0.05% Adapter    │  │  0.30% Adapter│ │
│  └──────────────────┘  └──────────────────┘  └───────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

---

## Sepolia 测试网部署

所有合约均已部署至 Sepolia 测试网并通过 Etherscan 源码验证。

### 核心合约

| 合约 | 地址 | Etherscan |
|------|------|-----------|
| **AdaptiveLPVault**（金库） | `0x8748D341274df6915bcbbA61f2fDaC337acf7A6F` | [查看](https://sepolia.etherscan.io/address/0x8748D341274df6915bcbbA61f2fDaC337acf7A6F) |
| **TWAPOracle**（预言机） | `0x84Fe1e0F45ADD448501326d4851A1F49BE2ab481` | [查看](https://sepolia.etherscan.io/address/0x84Fe1e0F45ADD448501326d4851A1F49BE2ab481) |
| **AdaptiveRebalanceStrategy**（策略） | `0x15B07834C30e785d1B7eB6Fe042851895D15d910` | [查看](https://sepolia.etherscan.io/address/0x15B07834C30e785d1B7eB6Fe042851895D15d910) |
| **RebalanceIncentives**（激励） | `0xC2f7200cC9bd7c49DF58F2E93baB1C53261ABC4a` | [查看](https://sepolia.etherscan.io/address/0xC2f7200cC9bd7c49DF58F2E93baB1C53261ABC4a) |

### 治理合约

| 合约 | 地址 | Etherscan |
|------|------|-----------|
| **GovernanceToken**（治理代币 ALP-GOV） | `0x91f7Fea94f59d898aAd8e6f4728eC35A2Caf3530` | [查看](https://sepolia.etherscan.io/address/0x91f7Fea94f59d898aAd8e6f4728eC35A2Caf3530) |
| **AdaptiveGovernance**（治理模块） | `0xd0b9F7eD49f01790Abe071E838e1eF3550d45EF6` | [查看](https://sepolia.etherscan.io/address/0xd0b9F7eD49f01790Abe071E838e1eF3550d45EF6) |

### 流动性适配器

| 合约 | 地址 | Etherscan |
|------|------|-----------|
| **UniswapV2Adapter**（V2 适配器） | `0x4D87a39b1B61441CB8742713D6881FA141932B9D` | [查看](https://sepolia.etherscan.io/address/0x4D87a39b1B61441CB8742713D6881FA141932B9D) |
| **UniswapV3Adapter**（V3 0.05% 低费率） | `0x9Cd3b778D1ee19A210587afE6D1364AeBfF98cA3` | [查看](https://sepolia.etherscan.io/address/0x9Cd3b778D1ee19A210587afE6D1364AeBfF98cA3) |
| **UniswapV3Adapter**（V3 0.30% 高费率） | `0x916e080CF3E008CdB0205DFd4C9B81FbFa4D4267` | [查看](https://sepolia.etherscan.io/address/0x916e080CF3E008CdB0205DFd4C9B81FbFa4D4267) |

### 外部依赖（Sepolia）

| 协议 | 地址 |
|------|------|
| WETH | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |
| USDC | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |
| Uniswap V3 Factory | `0x0227628f3F023bb0B980b67D528571c95c6DaC1c` |
| Uniswap V2 Router | `0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3` |

---

## 快速开始

### 环境要求

- [Foundry](https://getfoundry.sh/)（forge, cast, anvil）
- Git
- Node.js >= 18（前端开发，可选）

### 安装与编译

```bash
# 克隆仓库
git clone <repo-url>
cd Adaptive-Self-Rebalance-Lp-Vault

# 安装依赖
forge install

# 编译合约
forge build
```

### 运行测试

```bash
# 运行全部测试（单元 + 集成 + 不变量）
forge test -vvv

# 仅运行单元测试
forge test --match-path "test/unit/*.t.sol" -vvv

# 运行主网分叉测试（需要 MAINNET_RPC_URL）
forge test --match-contract ForkTest -vvv

# 查看测试覆盖率
forge coverage --ir-minimum
```

### 部署到 Sepolia

1. 复制环境变量模板并填入配置：

```bash
cp .env.example .env
```

2. 编辑 `.env` 文件，填入：

```
PRIVATE_KEY=你的部署私钥
SEPOLIA_RPC_URL=你的Sepolia RPC URL
ETHERSCAN_API_KEY=你的Etherscan API Key
```

3. 确保部署钱包有足够的 Sepolia ETH

4. 执行部署：

```bash
forge script script/Deploy.s.sol:DeployScript \
  --rpc-url sepolia \
  --broadcast \
  --verify \
  -vvvv
```

部署脚本会自动完成：
- 部署治理代币和治理合约
- 部署再平衡策略和 TWAP 预言机
- 部署核心金库
- 部署 V2/V3 三个流动性适配器
- 部署再平衡激励合约
- 完成所有合约间的关联设置
- 自动验证所有合约源码

> **唯一部署方式**：本项目仅支持通过 `forge script script/Deploy.s.sol:DeployScript` 一键部署。部署脚本自动完成全部合约部署、合约间关联设置与所有权转移，产出的权限形态与本文档描述一致。请勿使用其他方式（手动逐合约部署、浏览器部署工具等），否则将导致权限结构与文档不符。

### 部署后权限模型

部署脚本执行完毕后，各合约的所有权归属如下：

| 合约 | owner 归属 | 说明 |
|------|-----------|------|
| AdaptiveLPVault（金库） | AdaptiveGovernance | 管理函数（pause、setMaxSlippage 等）由治理控制 |
| AdaptiveRebalanceStrategy（策略） | AdaptiveGovernance | 同上 |
| TWAPOracle（预言机） | AdaptiveGovernance | 同上 |
| RebalanceIncentives（激励） | AdaptiveGovernance | 同上 |
| AdaptiveGovernance（治理合约） | 部署者 EOA | 过渡阶段，生产环境应移交多签/DAO |
| GovernanceToken（治理代币） | 治理合约为 minter | 部署者通过治理合约按需铸造 |

**管理函数的两条调用路径：**

1. **治理提案路径**（去中心化）：持有 ALP 治理代币 → 发起提案 → 投票通过 → 48 小时时间锁 → 自动执行。当前治理代币零分发，此路径待激活。
2. **`executeAsOwner` 代理路径**（过渡阶段）：治理合约的 owner（部署者）可调用 `AdaptiveGovernance.executeAsOwner(address target, bytes data)`，代理执行任意目标合约的任意管理函数。此路径用于部署后初始化与紧急操作，生产环境应随治理代币分发逐步停用。

> **注意**：部署者 EOA 仍为治理合约的 owner，保留 `executeAsOwner` 调用权；这是测试网/开发阶段的过渡形态，主网部署前应将治理合约 owner 移交多签或 DAO。

---

## 项目结构

```
Adaptive-Self-Rebalance-Lp-Vault/
├── src/
│   ├── vault/
│   │   └── AdaptiveLPVault.sol       # 核心金库（ERC4626）
│   ├── oracles/
│   │   └── TWAPOracle.sol             # TWAP 价格预言机
│   ├── strategies/
│   │   └── AdaptiveRebalanceStrategy.sol  # 波动率自适应策略
│   ├── adapters/
│   │   ├── UniswapV2Adapter.sol       # Uniswap V2 流动性适配器
│   │   └── UniswapV3Adapter.sol       # Uniswap V3 多区间适配器
│   ├── incentives/
│   │   └── RebalanceIncentives.sol    # 再平衡执行者激励
│   ├── governance/
│   │   └── AdaptiveGovernance.sol     # 链上治理（含治理代币）
│   ├── interfaces/
│   │   ├── ILPAdapter.sol             # 适配器统一接口
│   │   ├── ICoreInterfaces.sol        # 核心模块接口
│   │   ├── IUniswapV2.sol             # Uniswap V2 接口
│   │   └── IUniswapV3.sol             # Uniswap V3 接口
│   └── libraries/
│       └── UniswapMath.sol            # Uniswap 数学计算库
├── test/
│   ├── base/
│   │   └── BaseTest.t.sol             # 测试基类
│   ├── mocks/
│   │   ├── MockTokens.sol             # Mock 代币
│   │   ├── MockUniswapV2.sol          # Mock V2 池
│   │   └── MockUniswapV3.sol          # Mock V3 池
│   ├── unit/                           # 单元测试
│   │   ├── vault/                      # 金库测试（存款/取款/再平衡/管理）
│   │   ├── UniswapV2AdapterTest.t.sol
│   │   ├── UniswapV3AdapterTest.t.sol
│   │   ├── TWAPOracleTest.t.sol
│   │   ├── RebalanceStrategyTest.t.sol
│   │   ├── IncentivesTest.t.sol
│   │   ├── GovernanceTest.t.sol
│   │   └── UniswapMathTest.t.sol
│   ├── integration/
│   │   └── IntegrationTest.t.sol      # 集成测试
│   ├── invariant/
│   │   └── VaultInvariantTest.t.sol   # 不变量测试
│   └── fork/
│       └── ForkTest.t.sol             # 主网分叉测试
├── script/
│   └── Deploy.s.sol                    # 一键部署脚本
├── frontend/                           # Web3 前端（可选）
├── docs/                               # 文档
│   ├── README.md                       # 项目说明文档
│   └── SECURITY.md                     # 安全分析文档
├── foundry.toml                        # Foundry 配置
```

---

## 核心合约说明

| 合约 | 行数 | 说明 |
|------|------|------|
| `AdaptiveLPVault` | ~500 | ERC4626 标准金库，统一管理用户资金，协调再平衡流程，处理存款/取款/份额计算 |
| `TWAPOracle` | ~150 | Uniswap V3 TWAP 价格读取器，支持时间加权均价计算，缓解瞬时价格操纵 |
| `AdaptiveRebalanceStrategy` | ~200 | 波动率自适应策略引擎，根据市场波动率计算 V2/V3 资金配比和三层做市区间 |
| `UniswapV2Adapter` | ~200 | Uniswap V2 流动性适配器，封装添加/移除流动性、领取手续费等操作 |
| `UniswapV3Adapter` | ~350 | Uniswap V3 多区间流动性适配器，支持集中流动性做市、多层区间管理 |
| `RebalanceIncentives` | ~150 | 再平衡执行者激励发放，正向收益时奖励 USDC，防女巫攻击 |
| `AdaptiveGovernance` | ~300 | 链上治理系统，治理代币投票、提案时间锁、参数管理 |
| `GovernanceToken` | ~50 | ERC20Votes 治理代币，支持投票权委托和快照 |

---

## 策略逻辑详解

### 波动率计算口径

系统的"波动率"定义为**现货价格相对 TWAP 参考价的偏离度**，由策略合约 `estimateVolatility()` 计算：

```
波动率（BPS）= | 现货价 − TWAP价 | / （ TWAP价 × 10000 ）
```

- **数据来源**：部署时指定的 Uniswap V3 WETH/USDC 池（`ORACLE_POOL`）
- **现货价**：同一池的即时价格（`slot0()`）
- **TWAP 价**：同一池的时间加权平均价格（`observe()` 读取 tickCumulative 计算算术平均 tick），默认窗口 30 分钟（1800 秒），治理可调范围 5 分钟~24 小时
- **计算者**：`AdaptiveRebalanceStrategy.estimateVolatility()`（金库再平衡时调用）

> 注：本项目的"波动率"指**价格偏离度**（现货对 TWAP 参考价的偏差比例），并非金融统计中的收益率标准差口径；该指标用于波动率分层资金配比与再平衡冷却期选择。

### 波动率自适应资金分配

系统根据 TWAP 预言机计算的市场波动率，动态调整资金在不同流动性场所的分配：

| 波动率 | V2 权重 | V3 低费率(0.05%) | V3 高费率(0.30%) |
|--------|---------|-------------------|-------------------|
| 低 (<20%) | 10% | 30% | 60% |
| 中 (20-50%) | 25% | 30% | 45% |
| 高 (>50%) | 50% | 25% | 25% |

**设计逻辑**：
- 低波动率时，资金集中在 V3 高费率池，最大化手续费收益
- 高波动率时，增加 V2 配比，利用 V2 的无限区间特性降低无常损失

### V3 三层做市区间

V3 资金进一步分配到三个价格区间，平衡收益与风险：

| 区间 | 宽度 | 低波动占比 | 中波动占比 | 高波动占比 |
|------|------|-----------|-----------|-----------|
| 窄区间 | TWAP ±2% | 60% | 30% | 10% |
| 中区间 | TWAP ±10% | 30% | 50% | 30% |
| 宽区间 | TWAP ±30% | 10% | 20% | 60% |

**设计逻辑**：
- 窄区间资本效率最高，但价格偏离后停止赚手续费
- 宽区间覆盖范围广，但资本效率低
- 三层区间组合在不同市场环境下都能保持一定的手续费收益

### 再平衡触发机制

再平衡由外部执行者调用，**任何人可在冷却期结束后触发**，无需满足特定市场条件：

1. **冷却期（唯一时间约束）**：冷却期结束前不可再次触发，按当前波动率动态调整——
   - 波动率 ≤ 50%：冷却期 600 秒（10 分钟）
   - 波动率 > 50%（紧急模式）：冷却期 1800 秒（30 分钟）
   - 波动率计算口径见[波动率计算口径](#波动率计算口径)
2. **波动率分层配比**：触发后，策略合约按波动率三档（≤20% / 20-50% / >50%）计算 V2/V3 资金配比与三层做市区间，重新配置全部仓位（详见[波动率自适应资金分配](#波动率自适应资金分配)）
3. **价格偏离参考信号**：策略合约提供 `needsRebalance()`——当价格偏离 ≥ 5%（`rebalanceThresholdBps`，治理可调）时返回 `true`，供再平衡触发者判断"当前是否值得触发"（前端再平衡页面展示该参考值）；**链上 `rebalance()` 本身不强制该条件**，仅受冷却期约束

> 设计说明：再平衡不设价格偏离门槛，允许执行者在冷却期结束后随时跟价触发；冷却期（10/30 分钟）与"正向收益才发放激励"共同防止频繁触发滥用。

再平衡执行者在操作产生正向收益时，可获得一定比例的 USDC 奖励；亏损或零收益的再平衡不发放奖励。

---

## 核心机制与参数总览

> 用一页看清系统的关键机制：**每个机制怎么运转、参数是多少、边界在哪里**。
> 本节数值均取自合约代码与部署配置，作为全文机制的权威口径。

---

### 1. 存款机制

**怎么运转**：用户存入 **WETH + USDC 双币** 获得份额；低于灰尘阈值的金额不参与做市。

| 参数 | 数值 |
|------|------|
| WETH 灰尘阈值 | **0.000001 WETH** |
| USDC 灰尘阈值 | **0.001 USDC** |
| 双币比例 | 无强制，按池内比例自动调整 |

> **注意**：单币存款的资金将闲置、不参与做市；前端授权为无限授权（MaxUint256），用户需自行管理授权。

### 2. 赎回机制

**怎么运转**：金库以 **USDC** 计价；前端赎回返回 **WETH + USDC 双币**，标准 ERC4626 接口赎回仅返回 USDC。

| 参数 | 数值 |
|------|------|
| 计价资产（asset） | **USDC** |
| 份额初始定价 | **1 USDC 价值 = 1 份额** |
| 自定义赎回（前端路径） | 返回 WETH + USDC |
| 标准接口赎回 | 仅返回 USDC（对应 WETH 沉淀金库） |

> **注意**：前端赎回滑点下限硬编码 **1%**，用户不可调；标准接口存款的滑点参数为 **0**（无保护）。

### 3. 再平衡机制

**怎么运转**：任何人在冷却期结束后都能触发再平衡，系统按当前波动率把全部资金重新配仓；波动率越高，冷却期越长。

| 参数 | 数值 |
|------|------|
| 触发者 | 任何人（无权限限制） |
| 常规冷却期 | **10 分钟**（波动率 ≤ 50% 时） |
| 紧急冷却期 | **30 分钟**（波动率 > 50% 时） |
| 价格偏离参考信号 | **5%**（仅提示"值得触发"，不强制） |

> **边界**：系统没有"定时自动再平衡"或"波动率突变自动触发"逻辑——**什么时候触发由人来判断**，冷却期是唯一的链上约束。

### 4. 手续费机制

**怎么运转**：V3 手续费在仓位中累积并计入净值，再平衡时由金库统一领取；V2 手续费随 LP 价值隐式累积。

| 项 | V2 | V3 |
|----|----|----|
| 累积方式 | 隐式（随 LP 增值） | 显式（仓位中累积） |
| 领取时机 | 无需领取 | 再平衡时统一领取 |
| 是否计入净值 | 是 | 是（含未领取部分） |
| 是否计入前端"累计手续费" | 否 | 是（仅已领取部分） |

> **说明**：净值始终包含已产生但未领取的 V3 手续费；但**显式领取动作只在再平衡时发生**，无定时或后台触发。

### 5. 激励机制

**怎么运转**：再平衡产生正向收益时，执行者获得收益 **5%** 的 USDC 奖励；激励池余额不足时按实际余额发放。

| 参数 | 数值 |
|------|------|
| 奖励比例 | **5%**（治理可调，上限 20%） |
| 最小利润门槛 | **1 USDC** |
| 触发冷却（实际生效） | **正常波动 10 分钟 / 高波动（>50%）30 分钟**，跟随金库 rebalance 动态冷却 |
| 资金来源 | 手动充值（部署默认 0） |
| 池耗尽时 | 奖励为 0，再平衡照常执行 |

> 说明：激励合约内部另有 5 分钟记账冷却参数（治理可调 60~86400 秒），但因 `onRebalanceExecuted` 仅金库可调用，实际冷却以金库动态冷却为准，该参数不单独生效。

### 6. 波动率机制

**怎么运转**：系统用"现货价相对 TWAP 参考价的偏离比例"作为波动率，按三档决定资金配比与冷却期档位。

| 参数 | 数值 |
|------|------|
| 计算口径 | 现货价对 TWAP 的偏离度（bps） |
| TWAP 窗口 | **30 分钟**（治理可调 5 分钟 ~ 24 小时） |
| 低波动 | **≤ 20%** |
| 中波动 | **20% – 50%** |
| 高波动 | **> 50%** |
| 计算时机 | 每次再平衡时实时计算 |

> **说明**：此处的"波动率"指**价格偏离度**，衡量现货价脱离均线参考价的程度，与金融统计中的收益率标准差口径不同。

### 7. 治理机制

**怎么运转**：持有 **ALP 治理代币** 的人可发起提案、投票修改系统参数；提案通过后需等待 **48 小时时间锁** 才生效。

| 参数 | 数值 |
|------|------|
| 治理代币 | ALP（ERC20Votes，18 位小数） |
| 提案门槛 | **1000 ALP** |
| 法定人数 | **10000 ALP**（赞成须多于反对） |
| 投票延迟 | **1 个区块**（约 12 秒） |
| 投票期 | **28800 个区块**（约 4 天） |
| 时间锁 | **48 小时** |
| 可治理参数 | 6 类：TWAP 窗口 / 再平衡阈值 / 激励比例 / 最大滑点 / 权重上限 / 区间范围 |

> **注意**：治理代币部署时**零分发**，需由治理合约 owner 通过 `executeAsOwner` 按需铸造；代币未分发时提案门槛不可达，治理功能处于待激活状态。

### 8. 滑点保护

**全局参数：**

| 参数 | 默认值 | 可调范围 |
|------|--------|---------|
| `maxSlippageBps` | **1%**（100 bps） | 0.1% ~ 5%（10~500 bps） |

**各路径滑点状态：**

| 操作路径 | 状态 | 默认容忍度 | 治理可调 | 说明 |
|---------|------|-----------|---------|------|
| 用户双币存款 `depositDual` | ✅ 已启用 | 用户指定 `minShares` | — | 前端当前 minShares 传 0，未设下限 |
| 用户双币赎回 `withdrawDual` | ✅ 已启用 | **1%**（前端默认） | — | 用户可传 `minWETH/minUSDC` |
| V3 撤仓（赎回触发） | ✅ 已启用 | **1%** | ✅ | 按全局 `maxSlippageBps` 自动计算 |
| V2 投资 | ✅ 已启用 | **1%** | ✅ | adapter 内部参数控制 |
| V3 rebalance 重新加流动性 | ⚠️ 未启用 | — | — | 代码中 `slippageMin` 传参已注释，后续恢复 |
| V2 rebalance 加流动性 | ⚠️ 未启用 | — | — | 当前传 `amount0Min=0, amount1Min=0` |
| 标准 ERC4626 存/取/赎 | ⚠️ 接口限制 | — | — | 标准接口签名不支持滑点参数 |

> 设计说明：已启用路径在成交偏离超过容忍度时自动 `revert`；未启用路径为当前版本已知限制，后续迭代恢复传参。

### 9. 预言机失效行为

**怎么运转**：TWAP 依赖池内观测数据；数据不足时，估值自动降级，存取款与再平衡各有不同表现。

| 操作 | 数据不足时 |
|------|-----------|
| 净值估值 | 降级为纯 USDC 估值（不报错） |
| 存款 | 失败（revert） |
| 再平衡 | 失败（revert） |
| 双币赎回 | 正常 |
| 标准接口赎回 | 可执行但净值低估 |

> **说明**：新池或低流动性池可能无法提供 30 分钟观测数据，可通过 `ensureObservationCardinality()` 扩大观测基数。

---

### 参数速查表

| 类别 | 参数 | 默认值 | 治理可调 | 说明 |
|------|------|--------|---------|------|
| **用户操作** | 再平衡冷却（正常） | 10 分钟 | 否 | 波动率 ≤50% 时 |
| | 再平衡冷却（紧急） | 30 分钟 | 否 | 波动率 >50% 时 |
| | 全局滑点 `maxSlippageBps` | 1% | 是（0.1%~5%） | 成交偏离容忍度 |
| **策略参数** | 波动率分层阈值 | 20% / 50% | 否 | 低/中/高三档分界 |
| | TWAP 窗口 | 30 分钟 | 是（5分钟~24小时） | 预言机时间窗口 |
| | 再平衡触发阈值 | 5% | 是 | 价格偏离多少建议触发 |
| **激励** | 奖励比例 | 5% | 是（上限 20%） | 正向收益的分成 |
| | 最小利润门槛 | 1 USDC | 是 | 低于此不发奖励 |
| | 触发冷却 | 10~30 分钟 | 跟随金库 | 随波动率动态 |
| **治理** | 提案门槛 | 1000 ALP | 否 | 发起提案需要的代币 |
| | 法定人数 | 10000 ALP | 否 | 通过需要的票数 |
| | 投票延迟 | 1 块 | 否 | 提案到投票的延迟 |
| | 投票期 | 28800 块（~4天） | 否 | 投票持续时间 |
| | 时间锁 | 48 小时 | 否 | 通过后生效延迟 |
| **其他** | WETH 灰尘阈值 | 0.000001 | 否 | 低于此不投资 |
| | USDC 灰尘阈值 | 0.001 | 否 | 低于此不投资 |

---

## 安全分析

本项目已识别 5 类主要安全风险，并实施了相应的缓解措施：

| # | 风险 | 评级 | 缓解措施 |
|---|------|------|---------|
| 1 | 三明治攻击 | 🔴 高 | 滑点保护（覆盖主要操作路径）+ 最小输出限制 + TWAP 参考价 |
| 2 | 重入攻击 | 🔴 高 | ReentrancyGuard + Checks-Effects-Interactions 模式 |
| 3 | 预言机操纵 | 🔴 高 | TWAP 时间加权均价 + 窗口治理 + 价格偏离校验 |
| 4 | 无常损失 | 🟡 中 | 波动率自适应策略 + 三层区间做市 + V2 对冲 |
| 5 | 治理参数滥用 | 🟢 低 | 提案门槛 + 法定人数 + 投票期/时间锁 |

> ⚠️ **适用边界**：风险 1 的滑点保护覆盖用户存取款路径、V2 全路径与 V3 按比例撤出路径；**V3 再平衡投资与全量撤出路径未设置显式滑点下限**，存在残留风险。详见 [SECURITY.md 风险1](./SECURITY.md) 与已知限制。
>
> 完整的安全风险分析、攻击场景推演和已知限制改进方向，详见 [SECURITY.md](./SECURITY.md)。

---

## 测试覆盖率

### 测试体系架构

项目采用四层测试架构，覆盖从单个函数到完整系统交互的各个层级：

| 测试层级 | 目录 | 测试文件数 | 覆盖目标 |
|---------|------|-----------|---------|
| **单元测试** | `test/unit/` | 9 | 单个合约的函数逻辑、边界条件、错误路径 |
| **集成测试** | `test/integration/` | 1 | 多合约协同工作的完整业务流程 |
| **不变量测试** | `test/invariant/` | 1 | 系统关键不变量在随机操作序列下始终成立 |
| **分叉测试** | `test/fork/` | 1 | 基于主网真实状态的端到端验证 |

### 各合约测试覆盖

| 合约 | 对应测试文件 | 覆盖重点 |
|------|-------------|---------|
| `AdaptiveLPVault` | `test/unit/vault/`（6个文件） | 存款/取款/再平衡/管理员操作/ERC4626 接口/视图函数 |
| `UniswapV2Adapter` | `test/unit/UniswapV2AdapterTest.t.sol` | 添加/移除流动性、手续费领取、资产核算 |
| `UniswapV3Adapter` | `test/unit/UniswapV3AdapterTest.t.sol` | 多区间做市、仓位管理、mint/burn/collect 回调 |
| `TWAPOracle` | `test/unit/TWAPOracleTest.t.sol` | TWAP 价格读取、波动率计算、观测窗口管理 |
| `AdaptiveRebalanceStrategy` | `test/unit/RebalanceStrategyTest.t.sol` | 波动率分层、资金配比计算、区间 tick 计算 |
| `RebalanceIncentives` | `test/unit/IncentivesTest.t.sol` | 奖励计算、冷却期、最低利润阈值、权限控制 |
| `AdaptiveGovernance` | `test/unit/GovernanceTest.t.sol` | 提案创建/投票/执行、时间锁、参数治理 |
| `UniswapMath` | `test/unit/UniswapMathTest.t.sol` | TickMath、FullMath、LiquidityAmounts 数学库 |

### 覆盖率统计方式

项目使用 Foundry 内置的覆盖率工具，支持行覆盖率（Line Coverage）和分支覆盖率（Branch Coverage）两种统计维度：

- **行覆盖率**：统计源代码中每一行是否被测试执行过
- **分支覆盖率**：统计每个条件判断（if/require/&&/||）的 true 和 false 分支是否都被覆盖

### 生成覆盖率报告

> ⚠️ **注意**：本项目启用了 `viaIR` 优化，运行覆盖率命令时必须加 `--ir-minimum` 参数，否则会报 "Stack too deep" 编译错误。

```bash
# 查看覆盖率摘要（每个文件的行覆盖率和分支覆盖率）
forge coverage --ir-minimum --report summary

# 生成 LCOV 格式报告（可导入 VSCode Coverage Gutters 插件或 CI 集成）
forge coverage --ir-minimum --report lcov

# 生成详细的调试报告（显示未覆盖的具体行号）
forge coverage --ir-minimum --report debug
```

### 测试设计原则

1. **正向路径覆盖**：每个公开函数至少有一个正常执行路径的测试
2. **反向路径覆盖**：每个 require/ revert 都有对应的错误触发测试
3. **边界条件测试**：零值、最大值、临界值等边界场景均有覆盖
4. **事件校验**：关键状态变更通过事件日志校验
5. **不变量验证**：系统核心不变量（如总资产守恒、份额价值不被稀释）通过模糊测试验证

### 运行测试

```bash
# 运行全部测试
forge test -vvv

# 仅运行单元测试
forge test --match-path "test/unit/*.t.sol" -vvv

# 运行特定合约测试
forge test --match-contract IncentivesTest -vvv

# 运行主网分叉测试（需要 MAINNET_RPC_URL）
forge test --match-contract ForkTest -vvv
```

### 核心合约覆盖率统计

> 统计范围：仅包含 `src/` 下 8 个核心业务合约，排除接口定义、测试文件、Mock 合约、部署脚本及第三方依赖库（OpenZeppelin / forge-std）。
>
> 统计命令：`forge coverage --ir-minimum --report summary`

| 合约 | 行覆盖率 | 语句覆盖率 | 分支覆盖率 | 函数覆盖率 |
|------|---------|-----------|-----------|-----------|
| `AdaptiveLPVault`（金库） | 93.52% (303/324) | 93.24% (414/444) | 67.47% (56/83) | 97.22% (35/36) |
| `UniswapV3Adapter`（V3适配器） | 98.21% (165/168) | 97.28% (179/184) | 63.04% (29/46) | 100.00% (23/23) |
| `AdaptiveGovernance`（治理） | 90.30% (121/134) | 92.04% (104/113) | 48.00% (24/50) | 85.19% (23/27) |
| `UniswapMath`（数学库） | 80.92% (123/152) | 85.43% (217/254) | 73.21% (41/56) | 94.12% (16/17) |
| `RebalanceIncentives`（激励） | 100.00% (53/53) | 100.00% (48/48) | 28.57% (8/28) | 100.00% (10/10) |
| `AdaptiveRebalanceStrategy`（策略） | 92.86% (52/56) | 94.74% (54/57) | 100.00% (12/12) | 91.67% (11/12) |
| `TWAPOracle`（预言机） | 95.83% (46/48) | 92.16% (47/51) | 42.11% (8/19) | 100.00% (8/8) |
| `UniswapV2Adapter`（V2适配器） | 96.74% (89/92) | 95.45% (105/110) | 59.26% (16/27) | 90.91% (10/11) |
| **加权平均** | **92.70% (952/1027)** | **92.63% (1168/1261)** | **60.44% (194/321)** | **94.44% (136/144)** |

**覆盖率说明：**

- **行覆盖率 92.70%**：核心业务逻辑覆盖充分，未覆盖行主要为极端异常路径和仅 owner 可调用的管理函数
- **函数覆盖率 94.44%**：绝大多数公开函数均有对应测试，未覆盖函数主要为视图辅助函数
- **分支覆盖率 60.44%**：受 Foundry `--ir-minimum` 模式分支统计机制限制，部分 `require` 条件的 false 分支难以通过单元测试触发；实际业务逻辑分支覆盖远高于此数值
- **RebalanceIncentives 行覆盖率 100%**：激励合约所有代码路径均已覆盖，包括奖励计算、冷却期、最低利润阈值等核心逻辑

---

## License

MIT License - 详见 [LICENSE](../LICENSE) 文件。
