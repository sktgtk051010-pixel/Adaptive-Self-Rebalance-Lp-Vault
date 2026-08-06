# 设计文档 (DESIGN.md)

## Adaptive Self-Rebalance LP Vault 系统设计

### 1. 设计目标

本项目旨在构建一个对标 Gamma Strategies 的去中心化自动做市流动性金库，核心目标：

1. **简化用户体验**：用户只需存入 WETH/USDC，无需管理复杂的 LP 头寸
2. **最大化手续费收益**：通过多场所、多区间策略优化做市效率
3. **自适应市场环境**：根据波动率动态调整资金配置
4. **去中心化治理**：参数调整由代币持有者投票决定
5. **安全第一**：全面的安全防护机制

### 2. 系统架构

#### 2.1 分层设计

```
用户交互层 (Frontend + ERC4626 API)
    ↓
核心金库层 (AdaptiveLPVault)
    ↓
策略与治理层 (Strategy + Oracle + Governance + Incentives)
    ↓
适配器层 (V2 Adapter + V3 Adapters)
    ↓
协议层 (Uniswap V2/V3 Pools)
```

#### 2.2 资金流

1. **存款流程**：
   - 用户调用 `deposit(wethAmount, usdcAmount, minShares)`
   - 金库转移 WETH/USDC 到合约
   - 计算份额并铸造 ALP-VAULT 代币
   - 闲置资金保留在金库中，等待再平衡

2. **再平衡流程**：
   - 任何人调用 `rebalance()`
   - 收集所有适配器的手续费
   - 撤出所有流动性
   - 通过 TWAP 预言机获取当前价格和波动率
   - 策略计算新的资金分配权重
   - 将资金重新投入各适配器（V2/V3多区间）
   - 如果再平衡产生正向收益，触发激励发放

3. **取款流程**：
   - 用户调用 `withdraw(shares, minWETH, minUSDC)`
   - 按比例从各适配器撤出流动性
   - 转移 WETH/USDC 给用户
   - 销毁对应份额

### 3. 核心模块设计

#### 3.1 AdaptiveLPVault (金库核心)

**继承**：ERC4626, ERC20, ReentrancyGuard, Ownable

**关键状态变量**：
- `WETH`, `USDC`：基础代币地址
- `oracle`：TWAP 预言机
- `strategy`：再平衡策略
- `v2Adapter`, `v3LowFeeAdapter`, `v3HighFeeAdapter`：流动性适配器
- `currentWeights`：当前资金分配权重
- `cumulativeFeesUSDC`：累计手续费（USDC计价）
- `rebalanceCount`：再平衡次数
- `maxSlippageBps`：最大滑点保护

**关键方法**：
- `deposit(uint256 wethAmount, uint256 usdcAmount, uint256 minShares)`：双币存款
- `withdraw(uint256 shares, uint256 minWETH, uint256 minUSDC)`：双币赎回
- `rebalance()`：触发再平衡
- `totalAssets()`：总资产（USDC计价，含WETH按TWAP折算）
- `getDistribution()`：各场所资金分布

**设计决策**：
- 使用 ERC4626 以 USDC 为记账单位（asset = USDC, decimals = 6）
- 扩展支持 WETH 双币存入，提供更灵活的用户体验
- 再平衡冷却期 300 秒，防止频繁调用
- 所有资金操作使用 nonReentrant 修饰符

#### 3.2 TWAPOracle (价格预言机)

**功能**：
- 读取 Uniswap V3 池的 TWAP 价格
- 支持 WETH→USDC 和 USDC→WETH 双向报价
- 可配置采样时间窗口（默认 30 分钟）

**关键方法**：
- `getTWAPPrice()`：返回 (sqrtPriceX96, tick)
- `quote(uint256 amount, bool isWETH)`：代币转换报价
- `getCurrentPrice()`：即时价格（非TWAP）

**安全设计**：
- 使用 30 分钟 TWAP 防止闪电贷操纵
- 时间窗口可由治理调整（最小 60 秒，最大 24 小时）
- 正确处理 token0/token1 顺序

#### 3.3 AdaptiveRebalanceStrategy (策略引擎)

**波动率计算**：
- 基于 TWAP 价格变化百分比估算波动率
- 三档波动率：低 (<20%)、中 (20-50%)、高 (>50%)

**资金分配**：

| 波动率 | V2 | V3 0.05% | V3 0.30% |
|--------|-----|----------|----------|
| 低 | 10% | 30% | 60% |
| 中 | 25% | 30% | 45% |
| 高 | 50% | 25% | 25% |

**V3 区间权重**：

| 波动率 | 窄(±2%) | 中(±10%) | 宽(±30%) |
|--------|---------|----------|----------|
| 低 | 60% | 30% | 10% |
| 中 | 30% | 50% | 20% |
| 高 | 10% | 30% | 60% |

**Tick 计算**：
- ±2% ≈ ±198 ticks (tick spacing 60 → 对齐到 ±180)
- ±10% ≈ ±953 ticks (对齐到 ±960)
- ±30% ≈ ±2624 ticks (对齐到 ±2640)
- 所有 tick 对齐到 V3 tick spacing (60 for 0.30% pool)
- Clamp 到 [-887272, 887272] 边界

#### 3.4 LP Adapters (适配器)

**ILPAdapter 接口**：
```solidity
interface ILPAdapter {
    enum AdapterType { UNISWAP_V2, UNISWAP_V3_LOW_FEE, UNISWAP_V3_HIGH_FEE }

    function addLiquidity(uint256 amount0, uint256 amount1, ...) external returns (...);
    function removeLiquidity(bytes32 positionId, uint128 liquidity, ...) external returns (...);
    function collectFees() external returns (uint256 amount0, uint256 amount1);
    function getTotalAssets() external view returns (uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1);
    function withdrawAll() external returns (uint256 amount0, uint256 amount1);
}
```

**UniswapV2Adapter**：
- 与 V2 Router 交互添加/移除流动性
- LP 代币由适配器持有
- 资产价值 = LP余额 × 储备金 / 总供应量

**UniswapV3Adapter**：
- 直接与 V3 Pool 交互（不使用 NFT Position Manager）
- 支持多 position（bytes32 positionId = keccak256(tickLower, tickUpper)）
- 实现 IUniswapV3MintCallback
- 手续费通过 burn(0,0) + collect() 收集

#### 3.5 RebalanceIncentives (激励机制)

**设计**：
- 任何人可触发再平衡
- 验证再平衡后总资产 > 再平衡前总资产
- 从收益中扣除一定比例（默认 5%）作为奖励
- 奖励累积到调用者地址，可随时领取
- 冷却期 5 分钟，防止同一区块多次调用
- 最小收益阈值 1 USDC，避免无意义激励

**防女巫攻击**：
- 奖励基于实际收益比例
- 冷却期限制
- 只有正向收益才发奖励
- 奖励上限 20%（MAX_INCENTIVE_BPS = 2000）

#### 3.6 AdaptiveGovernance (链上治理)

**治理代币**：ALP-GOV (ERC20)

**可治理参数**：
- TWAP 窗口长度
- 再平衡阈值
- 激励比例
- 最大滑点
- 各池权重上限
- V3 区间范围（bps）

**治理流程**：
1. **提案**：持有 ≥1000 ALP-GOV 的地址可创建提案
2. **投票延迟**：1 个区块（约 12 秒）
3. **投票期**：28800 个区块（约 4 天）
4. **法定人数**：10000 ALP-GOV 赞成票
5. **执行**：通过后进入 48 小时时间锁
6. **时间锁到期**：任何人可执行参数变更

**安全特性**：
- 提案者或 owner 可取消提案
- 每个地址每个提案只能投一次票
- 时间锁防止恶意参数立即生效

### 4. 价格数学

#### 4.1 价格表示

Uniswap V3 使用 sqrtPriceX96 表示价格：
- `sqrtPriceX96 = sqrt(price) × 2^96`
- `price = token1/token0`（原始单位）

对于 WETH(18 decimals)/USDC(6 decimals)，价格 2000 USDC/ETH：
- `P = 2000 × 10^6 / 10^18 = 2 × 10^-9`
- `sqrtPriceX96 ≈ 3.54 × 10^24`
- `tick ≈ log(2×10^-9) / log(1.0001) ≈ -200300`

#### 4.2 资产折算

金库以 USDC 为记账单位，WETH 按 TWAP 价格折算：
```
wethValueUSDC = wethAmount × priceX96^2 / 2^192
```
使用 FullMath.mulDiv 防止溢出。

### 5. 安全考虑

详见 [SECURITY.md](SECURITY.md)。

### 6. 测试策略

- **单元测试**：每个合约的独立功能测试
- **fuzz 测试**：策略权重和 tick 计算的模糊测试
- **集成测试**：完整存款→再平衡→取款流程
- **主网分叉测试**：使用真实 Uniswap 合约验证兼容性
- **安全测试**：重入攻击、三明治攻击、异常参数

### 7. Gas 优化

- 使用 custom errors 替代 revert strings
- via_ir 编译优化
- 适配器直接与 Pool 交互（跳过 NFT Manager）
- 批量操作减少外部调用
- 适当使用 unchecked 块
