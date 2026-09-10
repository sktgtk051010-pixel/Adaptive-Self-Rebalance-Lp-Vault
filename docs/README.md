# Adaptive Self-Rebalance LP Vault

> 去中心化自适应再平衡 Uniswap LP 金库 — 对标 Gamma Strategies，自动管理 V2/V3 多池流动性

[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-3674A5.svg)](https://getfoundry.sh/)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.24-363636.svg)](https://soliditylang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Network: Sepolia](https://img.shields.io/badge/Network-Sepolia-4A4A4A.svg)](https://sepolia.etherscan.io/)
[![Contracts: Verified](https://img.shields.io/badge/Contracts-9%2F9%20Verified-brightgreen.svg)](#sepolia-测试网部署)

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
- [安全分析](#安全分析)
- [测试覆盖率](#测试覆盖率)
- [License](#license)

---

## 项目概述

Adaptive LP Vault 是一个基于 ERC4626 标准的去中心化流动性管理协议。用户存入 WETH + USDC 双代币，获得金库份额代币，金库自动将资金智能分配至 Uniswap V2 和多费率 Uniswap V3 流动性池。

系统依托 TWAP 预言机驱动的再平衡引擎，根据市场波动率动态调整资金配比、做市区间和仓位结构，在最大化手续费收益的同时控制无常损失。任何人都可以触发再平衡操作并获得激励奖励。

---

## 核心特性

- **ERC4626 标准金库**：存款铸币、赎回销毁，份额净值自动累积做市手续费收益
- **多场所流动性路由**：Uniswap V2 + Uniswap V3 0.05% + Uniswap V3 0.30% 三池联动
- **TWAP 预言机驱动**：使用 Uniswap V3 时间加权均价，规避瞬时价格操纵和闪电贷攻击
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
forge test --match-path test/unit/ -vvv

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
| `TWAPOracle` | ~150 | Uniswap V3 TWAP 价格读取器，支持时间加权均价计算，规避瞬时价格操纵 |
| `AdaptiveRebalanceStrategy` | ~200 | 波动率自适应策略引擎，根据市场波动率计算 V2/V3 资金配比和三层做市区间 |
| `UniswapV2Adapter` | ~200 | Uniswap V2 流动性适配器，封装添加/移除流动性、领取手续费等操作 |
| `UniswapV3Adapter` | ~350 | Uniswap V3 多区间流动性适配器，支持集中流动性做市、多层区间管理 |
| `RebalanceIncentives` | ~150 | 再平衡执行者激励发放，正向收益时奖励 USDC，防女巫攻击 |
| `AdaptiveGovernance` | ~300 | 链上治理系统，治理代币投票、提案时间锁、参数管理 |
| `GovernanceToken` | ~50 | ERC20Votes 治理代币，支持投票权委托和快照 |

---

## 策略逻辑详解

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

### 再平衡触发条件

当满足以下任一条件时，任何人可触发再平衡：
1. 当前价格偏离 TWAP 价格超过阈值（默认 5%）
2. 距离上次再平衡超过最大时间间隔
3. 波动率发生显著变化，需要调整资金配比

再平衡执行者在操作产生正向收益时，可获得一定比例的 USDC 奖励。

---

## 安全分析

本项目已识别 6 类主要安全风险，并实施了相应的缓解措施：

| # | 风险 | 评级 | 缓解措施 |
|---|------|------|---------|
| 1 | 三明治攻击 | 🔴 高 | 滑点保护 + 最小输出限制 + TWAP 参考价 |
| 2 | 重入攻击 | 🔴 高 | ReentrancyGuard + Checks-Effects-Interactions 模式 |
| 3 | 预言机操纵 | 🔴 高 | TWAP 时间加权均价 + 窗口治理 + 价格偏离校验 |
| 4 | 无常损失 | 🟡 中 | 波动率自适应策略 + 三层区间做市 + V2 对冲 |
| 5 | 女巫攻击激励 | 🟡 中 | 正向收益校验 + 最小阈值 + 冷却期 + 激励上限 |

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

```bash
# 查看覆盖率摘要（每个文件的行覆盖率和分支覆盖率）
forge coverage --report summary

# 生成 LCOV 格式报告（可用于 VSCode 插件或 CI 集成）
forge coverage --report lcov

# 生成详细的调试报告（显示未覆盖的具体行号）
forge coverage --report debug
```

### 测试设计原则

1. **正向路径覆盖**：每个公开函数至少有一个正常执行路径的测试
2. **反向路径覆盖**：每个 require/ revert 都有对应的错误触发测试
3. **边界条件测试**：零值、最大值、临界值等边界场景均有覆盖
4. **事件校验**：关键状态变更通过事件日志校验
5. **不变量验证**：系统核心不变量（如总资产守恒、份额净值单调）通过模糊测试验证

### 运行测试

```bash
# 运行全部测试
forge test -vvv

# 仅运行单元测试
forge test --match-path test/unit/ -vvv

# 运行特定合约测试
forge test --match-contract IncentivesTest -vvv

# 运行主网分叉测试（需要 MAINNET_RPC_URL）
forge test --match-contract ForkTest -vvv
```

---

## License

MIT License - 详见 [LICENSE](../LICENSE) 文件。
