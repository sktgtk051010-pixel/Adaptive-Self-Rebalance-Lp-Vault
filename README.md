# Adaptive Self-Rebalance LP Vault

> 0x Academy 自适应自再平衡 Uniswap LP 金库 — 对标 Gamma Strategies

[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-3674A5.svg)](https://getfoundry.sh/)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.24-363636.svg)](https://soliditylang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## 概述

Adaptive LP Vault 是一个去中心化的自动做市（AMM）流动性管理协议，对标行业头部 Gamma Protocol。用户只需存入 WETH + USDC 双代币，金库自动将资金智能分配至 Uniswap V2 和多费率 Uniswap V3 流动性池，依托 TWAP 预言机驱动的再平衡逻辑，自动调整做市仓位、价格区间和资金配比。

用户持有 ERC4626 标准金库份额即可被动获取 DEX 手续费收益，无需主动管理 LP 头寸。

## 核心特性

- **ERC4626 标准金库**：存款铸币、赎回销毁，份额净值自动包含做市手续费收益
- **多场所流动性路由**：Uniswap V2 + Uniswap V3 0.05% + Uniswap V3 0.30% 三池联动
- **TWAP 预言机驱动**：使用 Uniswap V3 时间加权均价，规避瞬时价格操纵
- **智能再平衡引擎**：根据市场波动率动态调整 V2/V3 资金配比
- **多区间 V3 做市**：窄/中/宽三层价格区间分层做市，平衡手续费收益与无常损失
- **去中心化再平衡激励**：任何人可触发再平衡，正向收益时获得代币奖励
- **链上治理**：治理代币 ALP-GOV 持有者可投票修改策略参数，含 48 小时时间锁
- **全面安全防护**：ReentrancyGuard 防重入、滑点保护防三明治攻击、灰尘资产自动归集

## 架构概览

```
┌─────────────────────────────────────────────────────────────┐
│                        用户层                                │
│   存入 WETH+USDC → 铸造 ALP-VAULT 份额 → 赎回本金+收益       │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                     核心金库层                               │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │ ERC4626金库 │  │ TWAP预言机   │  │ 再平衡激励模块   │   │
│  └──────┬──────┘  └──────────────┘  └──────────────────┘   │
│         │                                                   │
│  ┌──────▼──────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │ 再平衡引擎  │  │ 策略模块     │  │ 治理模块         │   │
│  └──────┬──────┘  └──────────────┘  └──────────────────┘   │
└─────────┼───────────────────────────────────────────────────┘
          │
┌─────────▼───────────────────────────────────────────────────┐
│                    适配器层                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │ UniswapV2    │  │ V3 0.05%     │  │ V3 0.30%         │   │
│  │ Adapter      │  │ Adapter      │  │ Adapter          │   │
│  └──────────────┘  └──────────────┘  └──────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## 快速开始

### 环境要求

- [Foundry](https://getfoundry.sh/) (forge, cast, anvil)
- Node.js >= 18（前端开发）
- Git

### 安装依赖

```bash
# 克隆仓库
git clone <repo-url>
cd Adaptive-Self-Rebalance-Lp-Vault

# 安装 Foundry 依赖
forge install

# 编译合约
forge build
```

### 运行测试

```bash
# 运行全部测试（单元+集成+组件）
forge test -vvv

# 运行主网分叉测试（需要 MAINNET_RPC_URL）
forge test --match-contract ForkTest -vvv

# 查看测试覆盖率
forge coverage --ir-minimum
```

### 部署到 Sepolia

1. 复制 `.env.example` 为 `.env` 并填入你的私钥和 RPC URL
2. 确保 Sepolia 测试网有足够的 ETH 和测试代币
3. 执行部署：

```bash
# 加载环境变量
source .env

# 部署并验证合约
forge script script/Deploy.s.sol:DeployScript \
  --rpc-url sepolia \
  --broadcast \
  --verify \
  -vvvv
```

## 项目结构

```
Adaptive-Self-Rebalance-Lp-Vault/
├── src/
│   ├── interfaces/          # 接口定义
│   │   ├── IUniswapV2.sol
│   │   ├── IUniswapV3.sol
│   │   ├── ILPAdapter.sol
│   │   └── ICoreInterfaces.sol
│   ├── libraries/           # 数学库
│   │   └── UniswapMath.sol
│   ├── tokens/              # 测试代币
│   │   └── MockTokens.sol
│   ├── oracles/             # TWAP 预言机
│   │   └── TWAPOracle.sol
│   ├── adapters/            # 流动性适配器
│   │   ├── UniswapV2Adapter.sol
│   │   └── UniswapV3Adapter.sol
│   ├── strategies/          # 再平衡策略
│   │   └── AdaptiveRebalanceStrategy.sol
│   ├── incentives/          # 再平衡激励
│   │   └── RebalanceIncentives.sol
│   ├── governance/          # 链上治理
│   │   └── AdaptiveGovernance.sol
│   └── vault/               # 核心金库
│       └── AdaptiveLPVault.sol
├── test/
│   ├── mocks/               # Mock 合约
│   ├── unit/                # 单元测试
│   ├── integration/         # 集成测试
│   └── fork/                # 主网分叉测试
├── script/                  # 部署脚本
├── frontend/                # Web3 前端
└── docs/                    # 文档
```

## 核心合约说明

| 合约 | 说明 |
|------|------|
| `AdaptiveLPVault` | ERC4626 标准金库，统一管理资金，协调再平衡 |
| `TWAPOracle` | Uniswap V3 TWAP 价格读取器 |
| `AdaptiveRebalanceStrategy` | 波动率自适应策略，计算资金分配和价格区间 |
| `UniswapV2Adapter` | Uniswap V2 流动性适配器 |
| `UniswapV3Adapter` | Uniswap V3 多区间流动性适配器 |
| `RebalanceIncentives` | 再平衡执行者激励发放 |
| `AdaptiveGovernance` | 治理参数管理，提案投票+时间锁 |

## 策略逻辑

### 波动率自适应分配

| 波动率 | V2 权重 | V3 低费率 | V3 高费率 | 窄区间 | 中区间 | 宽区间 |
|--------|---------|-----------|-----------|--------|--------|--------|
| 低 (<20%) | 10% | 30% | 60% | 60% | 30% | 10% |
| 中 (20-50%) | 25% | 30% | 45% | 30% | 50% | 20% |
| 高 (>50%) | 50% | 25% | 25% | 10% | 30% | 60% |

### V3 三层做市区间

- **窄区间**：当前 TWAP 价格 ±2%，高手续费收益
- **中区间**：当前 TWAP 价格 ±10%，平衡收益与风险
- **宽区间**：当前 TWAP 价格 ±30%，抵御大幅波动

## 安全审计要点

详见 [SECURITY.md](docs/SECURITY.md)，包含 6 类风险分析与缓解措施：

1. 三明治攻击 → 滑点保护
2. 重入攻击 → ReentrancyGuard
3. 预言机操纵 → TWAP 时间窗口
4. 无常损失 → 多区间+V2对冲
5. 女巫攻击激励 → 收益校验+冷却期
6. 治理参数滥用 → 时间锁+投票门槛

## 测试覆盖率

```
| 合约                           | 行覆盖率    | 分支覆盖率  |
|--------------------------------|-------------|-------------|
| AdaptiveLPVault.sol            | 91.11%      | 90.00%      |
| UniswapV3Adapter.sol           | 92.70%      | 91.08%      |
| TWAPOracle.sol                 | 97.92%      | 98.04%      |
| AdaptiveRebalanceStrategy.sol  | 98.15%      | 90.91%      |
| RebalanceIncentives.sol        | 97.96%      | 97.73%      |
| AdaptiveGovernance.sol         | 86.36%      | 84.04%      |
```

## License

MIT
