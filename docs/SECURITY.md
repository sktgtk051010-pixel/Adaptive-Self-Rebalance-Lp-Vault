# 安全风险分析报告 (SECURITY.md)

## Adaptive Self-Rebalance LP Vault 安全审计分析

本报告系统梳理了 Adaptive LP Vault 协议面临的主要安全风险，以及对应的缓解措施。

---

### 风险 1：三明治攻击 (Sandwich Attack)

**风险描述**：
再平衡操作涉及跨池资金调拨，攻击者可以在再平衡交易前后插入买卖订单，利用价格滑点获利，导致金库资金损失。这是 AMM 协议最常见的 MEV 攻击向量。

**影响程度**：高 — 可能导致金库资金直接损失

**缓解措施**：
1. **全局滑点保护**：所有再平衡和资金调拨操作都设置 `maxSlippageBps`（默认 1%，即 100 bps），超过滑点阈值的交易会被 revert
2. **最小输出校验**：V2/V3 添加/移除流动性时传入 `amountMin` 参数
3. **TWAP 定价基准**：再平衡使用 30 分钟 TWAP 价格而非即时价格，降低短期价格操纵的影响
4. **私有内存池友好**：再平衡操作不依赖特定顺序，可通过 Flashbots 等私有通道提交

**代码位置**：
- `AdaptiveLPVault.maxSlippageBps`
- `AdaptiveLPVault._reinvestWithRanges()` 中的滑点检查
- V3 Adapter `addLiquidity()` 的 amount0Min/amount1Min 参数

---

### 风险 2：重入攻击 (Reentrancy Attack)

**风险描述**：
金库涉及多次外部调用（V2/V3 池、代币转账），恶意合约可能在回调中重入金库函数，重复提取资金或操纵状态。

**影响程度**：高 — 可能导致资金被盗

**缓解措施**：
1. **全局 ReentrancyGuard**：所有资金操作函数（deposit、withdraw、rebalance）都使用 `nonReentrant` 修饰符
2. **Checks-Effects-Interactions 模式**：先更新状态变量，再进行外部调用
3. **SafeERC20**：使用 OpenZeppelin 的 SafeERC20 包装代币转账，防止恶意代币回调
4. **适配器隔离**：每个适配器独立持有 LP 头寸，金库通过标准接口调用，减少攻击面

**代码位置**：
- `AdaptiveLPVault` 继承 `ReentrancyGuard`
- `UniswapV2Adapter`、`UniswapV3Adapter` 继承 `ReentrancyGuard`
- `RebalanceIncentives` 继承 `ReentrancyGuard`

---

### 风险 3：预言机价格操纵 (Oracle Manipulation)

**风险描述**：
如果使用即时价格作为再平衡基准，攻击者可以通过大额交易在同一区块内操纵池价格，诱导金库以不利价格再平衡。闪电贷攻击是最典型的向量。

**影响程度**：高 — 可能导致金库以错误价格做市

**缓解措施**：
1. **TWAP 时间加权均价**：使用 Uniswap V3 的 30 分钟 TWAP 而非即时价格，闪电贷无法在短时间内显著影响 TWAP
2. **可配置时间窗口**：治理可调整 TWAP 窗口（最小 60 秒，最大 24 小时），在安全性和响应性之间平衡
3. **多池验证**：使用 0.30% 主池作为预言机源，该池流动性深、操纵成本高
4. **观察基数保证**：部署时调用 `increaseObservationCardinalityNext()` 确保有足够的历史数据点

**代码位置**：
- `TWAPOracle.getTWAPPrice()` 使用 `observe([window, 0])`
- `TWAPOracle.setTWAPWindow()` 范围验证
- `TWAPOracle.ensureObservationCardinality()`

---

### 风险 4：无常损失 (Impermanent Loss)

**风险描述**：
当 WETH/USDC 价格大幅波动时，V3 集中流动性头寸可能完全脱离做市区间，导致做市效率下降和无常损失。单边行情下 V3 LP 的损失可能超过持仓不动。

**影响程度**：中 — 影响收益但不直接导致资金损失

**缓解措施**：
1. **多区间分层做市**：V3 资金分配到窄/中/宽三个区间，即使价格突破窄区间，中宽区间仍在做市
2. **波动率自适应**：高波动时增加 V2 全区间流动性比例（最高 50%），V2 不存在区间限制
3. **双费率池分散**：同时在 0.05% 和 0.30% 池做市，不同费率池吸引不同类型交易者
4. **自动再平衡**：价格偏离阈值时自动调整区间，避免头寸长期脱离价格
5. **宽区间保护**：±30% 宽区间即使在大行情下也大概率保持在范围内

**代码位置**：
- `AdaptiveRebalanceStrategy.calculateAllocation()` 波动率自适应
- `AdaptiveRebalanceStrategy.getRangeTicks()` 三层区间
- `AdaptiveLPVault._investV3MultiRange()` 多区间投资

---

### 风险 5：再平衡激励女巫攻击 (Incentive Sybil Attack)

**风险描述**：
恶意用户可能通过频繁触发无意义的再平衡来赚取激励奖励，或者操纵资产价值使无利可图的再平衡看起来有利可图。

**影响程度**：中 — 可能导致激励资金被滥用

**缓解措施**：
1. **正向收益验证**：只有当再平衡后总资产 > 再平衡前总资产时才发放奖励
2. **冷却期机制**：两次再平衡之间至少间隔 300 秒（5 分钟），防止高频调用
3. **最小收益阈值**：收益低于 1 USDC 时不触发激励
4. **奖励比例上限**：激励比例最高 20%（2000 bps），防止过度发放
5. **首次再平衡豁免**：首次再平衡跳过冷却检查（初始化状态）
6. **try/catch 保护**：激励发放失败不影响再平衡本身执行

**代码位置**：
- `RebalanceIncentives.onRebalanceExecuted()` 收益验证
- `RebalanceIncentives.canRebalance()` 冷却检查
- `AdaptiveLPVault.rebalance()` 中的 try/catch 包裹激励调用

---

### 风险 6：治理参数滥用 (Governance Parameter Abuse)

**风险描述**：
恶意治理提案可能将参数设置为危险值（如滑点设为 100%、TWAP 窗口设为 1 秒），为攻击打开方便之门。或者攻击者通过持有大量治理代币强行通过恶意提案。

**影响程度**：中高 — 可能间接导致资金损失

**缓解措施**：
1. **时间锁机制**：所有治理参数变更需经过 48 小时时间锁，给用户退出时间
2. **投票门槛**：提案需要至少 1000 ALP-GOV，法定人数 10000 ALP-GOV
3. **投票期**：4 天投票期，确保充分讨论
4. **参数边界验证**：合约层面对参数设置进行范围检查：
   - TWAP 窗口：60 秒 ~ 24 小时
   - 激励比例：0 ~ 20%
   - 滑点：0 ~ 10%
   - 权重上限：0 ~ 100%
5. **Owner 紧急权限**：owner 可以暂停金库（pause），在发现治理攻击时阻止存款
6. **解耦设计**：治理合约与金库合约解耦，即使治理合约被攻破，金库资金仍受 ReentrancyGuard 保护

**代码位置**：
- `AdaptiveGovernance.executeTimelock()` 时间锁执行
- `TWAPOracle.setTWAPWindow()` 范围验证
- `RebalanceIncentives.setIncentiveBps()` 上限检查
- `AdaptiveLPVault.setPaused()` 紧急暂停

---

### 风险 7：灰尘资产遗漏 (Dust Asset Loss)

**风险描述**：
再平衡过程中可能残留小额代币（dust）在适配器或池合约中，长期累积导致资金沉淀。

**影响程度**：低 — 小额资金损失

**缓解措施**：
1. **适配器 withdrawAll()**：撤出所有流动性后，将合约余额全部转回金库
2. **collectFees() 全面收集**：每次再平衡前收集所有手续费
3. **DUST_THRESHOLD**：金库定义灰尘阈值（1000 wei USDC），低于此值的余额不影响计算
4. **getTotalAssets() 包含余额**：总资产计算包含适配器合约的代币余额

**代码位置**：
- `UniswapV3Adapter.withdrawAll()` 转移剩余 dust
- `UniswapV2Adapter.withdrawAll()` 转移剩余 dust
- `AdaptiveLPVault.DUST_THRESHOLD`

---

### 风险 8：硬编码地址风险

**风险描述**：
合约中硬编码代币或池地址可能导致在不同链上部署失败，或升级时出现问题。

**影响程度**：低 — 部署和可维护性问题

**缓解措施**：
1. **构造函数传入**：所有外部地址（WETH、USDC、池、路由）通过构造函数传入
2. **无 magic address**：合约代码中不包含任何硬编码地址
3. **部署脚本配置**：地址在部署脚本中定义，支持任意网络部署

---

### 安全最佳实践总结

| 实践 | 实施情况 |
|------|----------|
| ReentrancyGuard | ✅ 所有资金操作合约 |
| Checks-Effects-Interactions | ✅ 严格遵循 |
| SafeERC20 | ✅ OpenZeppelin v5.2 |
| 滑点保护 | ✅ 全局 maxSlippageBps |
| TWAP 预言机 | ✅ 30分钟窗口 |
| 时间锁治理 | ✅ 48小时 |
| 紧急暂停 | ✅ owner 可暂停 |
| 自定义错误 | ✅ Solidity 0.8.24 |
| 溢出检查 | ✅ 0.8+ 内置 |
| 无硬编码地址 | ✅ 构造函数传入 |

### 审计建议

1. **正式审计**：建议主网部署前进行专业第三方安全审计
2. **Bug 赏金**：上线后设立 Bug 赏金计划
3. **渐进式上线**：先设置 TVL 上限，逐步放开
4. **监控告警**：部署链上监控，异常再平衡或大额取款实时告警
5. **多签管理**：Owner 权限使用多签钱包，降低单点风险
