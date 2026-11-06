# Security Self-Review — Adaptive LP Vault

> 自研项目安全自查报告。
> 本文档记录"查了什么、查出什么、怎么验证、结论是什么"，与 `SECURITY.md`（风险与缓解措施说明）互为补充。

| 项 | 值 |
|---|---|
| 审查对象 | Adaptive-Self-Rebalance-Lp-Vault |
| 代码版本 | `631a96731cc8d0d4bac41fd6e66f997b55f607c9`（2026-10-27） |
| 审查范围 | `src/` 下 15 个 Solidity 文件 |
| 网络 | Sepolia 11155111（已部署并验证） |
| 审查性质 | 自查（Self-Review）|

---

## 目录

- [1. 范围与方法](#1-范围与方法)
- [2. 架构与信任模型](#2-架构与信任模型)
- [3. 发现清单](#3-发现清单)
- [4. 工具输出裁决（Slither）](#4-工具输出裁决slither)
- [5. 风险维度与缓解](#5-风险维度与缓解)
- [6. 测试证据](#6-测试证据)
- [7. 历史安全事件](#7-历史安全事件)
- [8. 结论与建议](#8-结论与建议)

---

## 1. 范围与方法

### 1.1 审查对象

| 类别 | 文件 |
|---|---|
| 金库核心 | `src/vault/AdaptiveLPVault.sol` |
| 适配器 | `src/adapters/UniswapV2Adapter.sol`、`src/adapters/UniswapV3Adapter.sol` |
| 治理与代币 | `src/governance/AdaptiveGovernance.sol`（含 `GovernanceToken`） |
| 预言机 / 策略 | `src/oracles/TWAPOracle.sol`、`src/strategies/AdaptiveRebalanceStrategy.sol` |
| 分发与激励 | `src/distribution/{Treasury,LiquidityMining,TeamVesting}.sol`、`src/incentives/RebalanceIncentives.sol` |
| 库与接口 | `src/libraries/UniswapMath.sol`、`src/interfaces/*.sol` |

### 1.2 方法与工具

1. **静态分析**：Slither 0.11.5 + solc 0.8.20 + Foundry 1.8.6，全量扫描 `src/`（`--filter-paths lib/`）
2. **人工复核**：按 detector 分组复核，逐条判定误报 / 已缓解 / 真实缺陷；判据包括权限修饰器、可达性、常量条件、差值校正、重入锁
3. **权限链梳理**：从 owner、governance、minter、adapter 四个角色出发，还原"谁能动什么"
4. **测试验证**：现有 Foundry 测试 + PoC 复现（PoC 见第 6 章）

### 1.3 未覆盖范围

- 前端代码、部署脚本（`script/`）、第三方依赖（`lib/`）
- 经济攻击的组合场景（MEV、预言机与流动性联合操纵）
- 形式化验证、模糊测试的深度覆盖（仅有不变量测试）

---

## 2. 架构与信任模型

### 2.1 资产流

```
用户 ──deposit(WETH+USDC)──▶ AdaptiveLPVault
                                   │
                    ┌──────────────┼──────────────┐
                    ▼              ▼              ▼
            UniswapV2Adapter  V3LowFeeAdapter  V3HighFeeAdapter
                    │              │              │
                    ▼              ▼              ▼
              V2 Pair(USDC/WETH)  V3 Pool 0.05%  V3 Pool 0.30%

撤回路径：withdrawDual ──▶ _withdrawFromAdapters ──▶ 各 adapter.removeLiquidity ──▶ 代币回到 Vault ──▶ 用户
```

资金形态有三种：**闲置在 Vault**、**在 Adapter 待投（散币）**、**已进入池子（V2 LP 份额 / V3 直接仓位）**。

#### 2.1.1 `totalAssets()` 计算口径

**公式**（`AdaptiveLPVault.sol#L516-528`）：

```solidity
totalAssets = totalUSDC + _wethToUSDC(totalWETH, TWAP)
// 预言机 revert 或返回 0 时：totalAssets = totalUSDC（WETH 敞口按 0 计）
```

**分解图**：

```
totalAssets()  [USDC 计价]
├─ Vault 自身余额                                  L532-533
│   ├─ WETH  balanceOf(vault)
│   └─ USDC  balanceOf(vault)
└─ getTotalUnderlying() 汇总三个 adapter            L536-550
    ├─ UniswapV2Adapter.getTotalAssets()           L261-280
    │   ├─ LP 份额折算：lpBalance × reserve / LP.totalSupply    L272-273
    │   ├─ adapter 散币：balanceOf(adapter)                     L275-276
    │   └─ fees = 0（手续费已长在 reserve，不重复计）            L278-279
    ├─ V3LowFeeAdapter.getTotalAssets()            L377-389
    │   ├─ 逐仓位本金：getAmountsForLiquidity                    L508-510
    │   ├─ 逐仓位未领手续费：feeGrowth 差值 + tokensOwed         L514-518
    │   └─ adapter 散币                                        L387-388
    └─ V3HighFeeAdapter.getTotalAssets()           同上

最后：WETH 部分 × TWAP → USDC，与 USDC 部分相加      L521-524
```

**资产清单**：

| 计入 | 资产 | 依据 |
|---|---|---|
| ✅ | Vault 的 WETH 余额 | L532 |
| ✅ | Vault 的 USDC 余额 | L533 |
| ✅ | V2 adapter 持有的 LP 份额（对应池内资产） | L272-273 |
| ✅ | V2 adapter 散币 | L275-276 |
| ✅ | V3 各仓位本金 | L508-510 |
| ✅ | V3 各仓位未领取手续费 | L514-518 |
| ✅ | V3 adapter 散币 | L387-388 |

**价格来源（同一函数内口径不一致）**：

| 估值对象 | 价格来源 | 代码 |
|---|---|---|
| WETH → USDC 总额折算 | **TWAP** | L521-524 |
| V3 仓位内部 token0/token1 拆分 | **现货** `POOL.slot0()` | L504 |
| V2 LP 份额折算 | **现货储备** `PAIR.getReserves()` | L269 |

总额折算用 TWAP、仓位拆分用现货。价格偏离时两类资产的拆分比例与总额口径不同，估值存在偏差（关联 F-04）。

### 2.2 权限矩阵

| 角色 | 地址 / 实现 | 能做什么 | 单点风险 |
|---|---|---|---|
| **owner** | 部署 EOA（Sepolia） | `executeAsOwner`（L431-440，`onlyOwner`）可发起任意 `call`；参数、暂停、适配器替换等管理函数 | **一把万能钥匙**：可暂停金库、划走国库、更换适配器、改任意参数 |
| **governance** | `AdaptiveGovernance` 合约 | 提案 → 投票 → 48h 时间锁执行；作为 `minter` 可 `mint` / `burn` | 有 timelock 延迟；但 `burn` 无授权检查（F-01） |
| **minter** | = governance 合约 | `mint`（受 `CAP = 10_000_000e18` 约束，已铸满）、`burn(address from, uint256)`（**暂无 allowance 检查**） | F-01、F-02 |
| **adapter** | 三个适配器合约 | 只能被 `onlyVault` 调用，从 Vault 拉取代币、向池子添加/移除流动性 | 边界清晰；adapter 地址可被 owner 替换 |
| **任意用户** | — | `deposit` / `withdrawDual` / `rebalance`（受冷却期与 `whenNotPaused` 约束） | 有 `nonReentrant` + 滑点参数 |

### 2.3 关键外部依赖

| 依赖 | 用途 | 失败时的行为 |
|---|---|---|
| Uniswap V2 Router / Pair | V2 流动性 | 交易 revert |
| Uniswap V3 Pool（直接仓位，无 NFT Manager） | V3 流动性 | 交易 revert |
| `TWAPOracle` | 净值折算、再平衡决策 | `totalAssets()` 降级为只计 USDC（F-04） |
| `LiquidityMining` | 份额转账时同步记账 | `try/catch` 静默忽略（F-05） |

---

## 3. 发现清单

| ID | 严重性 | 标题 | 位置 | 状态 |
|---|---|---|---|---|
| F-01 | Medium | `burn` 缺少授权检查，minter 可销毁任意地址余额 | `AdaptiveGovernance.sol#L64-66` | Open |
| F-02 | Low | `setMinter` 无零地址校验，误设后不可逆 | `AdaptiveGovernance.sol#L54-57` | Open |
| F-03 | Medium（设计） | `executeAsOwner` 无时间锁、无多签，owner 单点可任意调用 | `AdaptiveGovernance.sol#L431-440` | Accepted |
| F-04 | Low | 预言机失败时 `totalAssets()` 静默降级，净值被低估 | `AdaptiveLPVault.sol#L517-528` | Accepted |
| F-05 | Low | `_update` 用空 `catch` 吞掉挖矿记账异常 | `AdaptiveLPVault.sol#L440-447` | Accepted |
| F-06 | Info（设计） | ERC4626 标准接口与双币入口错配，`withdraw`/`redeem` 禁用 | `AdaptiveLPVault.sol#L395-405` | Accepted |
| F-07 | Medium | V3 再平衡路径滑点下限为 0，存在三明治残留风险 | `UniswapV3Adapter.sol`（`addLiquidity` / `withdrawAll`） | Open |
| F-08 | Low | 分配层按权重切币且金库无兑换能力，库存与仓位需求不匹配导致资金闲置（单边存款时达 100%） | `AdaptiveLPVault.sol#L688-710` | Accepted |

### F-01 `burn` 缺少授权检查

- **位置**：`src/governance/AdaptiveGovernance.sol#L64-66`
- **代码**：
  ```solidity
  function burn(address from, uint256 amount) external onlyMinter {
      _burn(from, amount);
  }
  ```
- **描述**：仅校验调用者是 `minter`，未校验 `from` 是否授权。任何持有 minter 权限的地址可销毁任意账户余额。
- **影响链**：`governance` 合约即 `minter` → `owner` 通过 `executeAsOwner(target=GovernanceToken, data=burn(victim, amount))` 调用时，`msg.sender` 为 governance 合约本身，满足 `onlyMinter` → **可销毁任意用户份额**。
- **建议**：增加 `allowance[from][msg.sender]` 检查与扣减，或限制 `from == msg.sender`。
- **状态**：Open。不重部署（理由见 8.2），修复进入 v1.1 分支。

### F-02 `setMinter` 无零地址校验

- **位置**：`src/governance/AdaptiveGovernance.sol#L54-57`
- **代码**：
  ```solidity
  function setMinter(address _minter) external {
      require(msg.sender == minter, "GovToken: not minter");
      minter = _minter;
  }
  ```
- **描述**：缺少 `_minter != address(0)` 校验。一旦误设为零地址，`require(msg.sender == minter)` 永远无法满足，**minter 通道永久锁死且不可恢复**。
- **实际影响**：`CAP` 已铸满（10,000,000 枚），增发额度耗尽，因此影响限于 `burn` 与未来治理动作，定为 Low。
- **建议**：增加零地址校验，并考虑两阶段转移（`setPendingMinter` + `acceptMinter`）。
- **状态**：Open。

### F-03 `executeAsOwner` 单点权限

- **位置**：`src/governance/AdaptiveGovernance.sol#L431-440`
- **描述**：`onlyOwner` 的任意 `call` 通道，无时间锁、无多签约束。owner 私钥泄露即等价于全部 12 个合约失控。
- **缓解**：部署文档已约定主网阶段 owner 移交多签。
- **残余风险**：多签只把"一人可做"变为"多签合谋可做"，不消除函数级设计缺陷（F-01 仍可经此通道触发）。
- **状态**：Accepted（设计取舍）。

### F-04 `totalAssets()` 静默降级

- **位置**：`src/vault/AdaptiveLPVault.sol#L517-528`
- **代码**：
  ```solidity
  try ORACLE.getTWAPPrice() returns (uint160 sqrtPriceX96Twap, int24) {
      if (sqrtPriceX96Twap == 0) return totalUSDC;
      uint256 wethValueUSDC = _wethToUSDC(totalWETH, sqrtPriceX96Twap);
      return totalUSDC + wethValueUSDC;
  } catch {
      return totalUSDC;   // WETH 部分被忽略
  }
  ```
- **描述**：预言机 revert 或返回 0 时，净值只计 USDC 部分，WETH 敞口被当作 0。
- **影响**：`totalAssets` 被低估 → 同一笔存款换到更多份额（`shares = value * supply / totalAssets`），存款人受益、存量持有人被稀释。不造成资金损失，但破坏份额定价一致性。
- **建议**：降级时发出事件；或对 WETH 部分使用最近一次有效价格并标记陈旧。
- **状态**：Accepted（可用性优先于精确性）。

### F-05 `_update` 吞掉挖矿记账异常

- **位置**：`src/vault/AdaptiveLPVault.sol#L440-447`
- **代码**：
  ```solidity
  try liquidityMining.updateBalance(from, balanceOf(from)) {} catch {
      /* 挖矿记账失败不影响份额转账本身，下次存取款时再校准 */
  }
  ```
- **描述**：异常被完全吞掉，无事件、无返回值记录。
- **影响**：`LiquidityMining` 的份额记账可能短暂失真，用户奖励分配出现偏差；不涉及本金。
- **建议**：`catch` 中发出 `MiningSyncFailed` 事件，便于链下监控。
- **状态**：Accepted。

### F-06 ERC4626 标准接口与双币入口错配

- **位置**：`src/vault/AdaptiveLPVault.sol#L395-405`（`withdraw`/`redeem` 为 `pure` 且直接 revert，已禁用）；`#L308`（标准 `deposit` 仅收 USDC 单币）
- **描述**：`asset()` 为 USDC，但金库资产为 WETH+USDC 双币。标准取款按 USDC 计价却无法支付双币，因此禁用；完整存取走 `deposit(wethAmount, usdcAmount, minShares)` / `withdrawDual`。
- **影响**：第三方钱包、聚合器、借贷平台按 ERC4626 标准集成会失败或误判资产构成。
- **建议**：README 与前端明确标注标准接口不可用；如需兼容，实现单币 Zap 封装。
- **状态**：Accepted（有意设计取舍）。

### F-07 V3 再平衡路径滑点下限为 0

- **位置**：`src/adapters/UniswapV3Adapter.sol`（`addLiquidity` 的 `amount0Min`/`amount1Min` 传 0；`withdrawAll` 无最小输出校验）
- **描述**：再平衡过程中添加/撤出 V3 流动性时未设输出下限，攻击者可在 mempool 抢先交易，使再平衡以不利价格成交
- **缓解**：再平衡冷却期（正常 10 分钟 / 高波动 30 分钟）、执行时间不可预测、TWAP 估值
- **建议**：以 TWAP 为基准计算 `amountMin`，复用金库的 `maxSlippageBps`
- **状态**：Open（已知限制，见 `SECURITY.md` 第 1 节）

### F-08 分配层按权重切币且金库无兑换能力，库存与仓位需求不匹配导致资金闲置

- **位置**：`src/vault/AdaptiveLPVault.sol#L688-710`（`_investToAdapters` 将 WETH 与 USDC 各自乘同一权重切分）、`#L719-742`（`_investV3MultiRange` 再按区间比例二次切分）、`src/adapters/UniswapV3Adapter.sol#L192-203`（`getLiquidityForAmounts` 取两侧 min）、`#L152`（`liquidity == 0` 直接返回）、`src/` 内无任何 swap 调用（`IUniswapV3.sol` / `IUniswapV2.sol` 仅为接口声明）
- **描述**：分配层从不计算仓位在当前价与区间边界下实际需要多少两种币，而是把 WETH、USDC 各自乘以同一权重切分。V2 需按储备比配、V3 需按区间位置配，配不上的部分被适配器退回；金库本身又没有兑换能力补齐，缺口无法自愈。单边存款时缺失一侧，V3 算得 `liquidity == 0` 直接返回，V2 因 WETH 侧为 0 被灰尘阈值跳过，资金全额留在金库；双边存款但比例与池子最优比不符时，同样残留部分闲置。
- **证据**：`test/poc/POC_SingleSidedIdle.t.sol` 在 Sepolia fork 上新建空金库。单边场景仅存 1000 USDC，实测 `getDistribution()` 的 idle 占比 **10000 bps（100%）**，`totalAssets` 由 0 增至 1000e6、`idleUSDC` 同步由 0 增至 1000e6；双边场景存入 1 WETH + 1000 USDC（价值比约 1:2，与仓位需求不符），实测 `idleWETH = 0.925 WETH`（占存入 WETH 的 **92.5%**）、`idleUSDC = 0`，即富余一侧大量闲置、紧缺一侧全部投出。
- **影响**：单边存款人资金零收益；双币存款亦因配比不匹配产生残余闲置。不造成资金损失，属效率与体验缺陷，级别 Low / Design。
- **建议（下一版可选）**：① 按当前价与区间边界算出每个仓位需要的 token0/token1 并加总；② 金库库存对比总需求，多的一侧换少的一侧，全局只 swap 一次，`amountOutMin` 复用 `maxSlippageBps`；③ 按①的数字精确分发；④ 分配层同步改为按需求切分（V2 精确 50/50，三档区间各自比例）。只换总账不改分发，残差仍会回流。
- **状态**：Accepted / Known Limitation。

---

## 4. 工具输出裁决（Slither）

### 4.1 扫描口径

```bash
slither src/ --filter-paths lib/ --json /tmp/slither_report.json
```

结果：**171 条**，`src/ analyzed (68 contracts with 101 detectors)`。

### 4.2 分布

| Impact | Detector | 条数 |
|---|---|---|
| High | `reentrancy-balance` | 5 |
| High | `arbitrary-send-erc20` | 4 |
| Medium | `unused-return` | 28 |
| Medium | `incorrect-equality` | 15 |
| Medium | `reentrancy-no-eth` | 5 |
| Medium | `uninitialized-local` | 2 |
| Low | `timestamp` | 14 |
| Low | `calls-loop` | 13 |
| Low | `missing-zero-check` | 7 |
| Low | `reentrancy-benign` | 5 |
| Low | `shadowing-local` / `events-access` | 1 / 1 |
| Informational | `naming-convention` 等 | 63 |
| Optimization | `constable-states` / `cache-array-length` | 6 / 2 |

### 4.3 High 逐条裁决（9 条）

| # | Detector | 位置 | 裁决 | 判据 |
|---|---|---|---|---|
| 1-2 | `arbitrary-send-erc20` | `UniswapV2Adapter.addLiquidity` #L97/L100 | 误报 | `VAULT` 为 `immutable`（L26）；函数 `external onlyVault nonReentrant`（L93） |
| 3-4 | `arbitrary-send-erc20` | `UniswapV3Adapter._transferFromVault` #L211/L214 | 误报 | `VAULT` 为 `immutable`（L20）；`_transferFromVault` 为 `internal`（L209），唯一调用方 `addLiquidity` 带 `onlyVault nonReentrant`（L132-138） |
| 5 | `reentrancy-balance` | `AdaptiveLPVault.deposit` #L269-301 | 误报（门不存在） | 快照 `totalAssetsBefore`（L277）与门（L281）分属互斥分支；`_mint(DEAD_ADDRESS, DEAD_SHARES)`（L258）的 `to == DEAD_ADDRESS`（L97）被 `_update` L444 条件排除，外部调用实际不发生；另有 `nonReentrant`（L273） |
| 6-7 | `reentrancy-balance` | `withdrawDual` 的 `_burn` 路径 #L370 | 误报 | `nonReentrant`（L361）；余额用差值校正 `wethOut = mulDiv(idleWethBefore, sharePct, WAD) + (wethBalAfter - idleWethBefore)`（L377-378）；外部调用有 `try/catch`（L440-447） |
| 8-9 | `reentrancy-balance` | `withdrawDual` 的 `_withdrawFromAdapters` 路径 #L372 | 已缓解 | 三道防线同上；残余风险为 adapter 地址由治理控制（信任假设），故不判"纯误报" |

**小结**：9 条 High 中，**7 条误报、2 条已缓解，0 条可利用**。
三类工具盲点：① 不做常量条件推理（`DEAD_ADDRESS` 被当作任意地址）；② 不做分支互斥判断；③ 不识别差值校正（`after - before`）。

### 4.4 Medium 裁决

| Detector | 条数 | 裁决 | 依据 |
|---|---|---|---|
| `incorrect-equality` | 15 | 全部误报 | 15 条均为 `== 0` 零值 / 除零 / 同块去重守卫（V2Adapter L263；Vault L257/L280/L617/L685/L757/L801/L922/L987/L1004；LiquidityMining L61/L98/L147；RebalanceIncentives L169；TeamVesting L71）。真正危险的是"与精确余额比较"（`balanceOf(this) == expected`），本项目不存在 |
| `unused-return` | 28 | 全部误报 | 19 条为元组部分解构（丢弃 `slot0` 的 tick、`getReserves` 的 timestamp、`ticks`/`observe` 的次要字段）；9 条为整次调用未接返回值，均有余额差值或全量 collect 兜底。`src/` **无裸 `transfer`/`approve`/`transferFrom`**，37 处全部走 SafeERC20，失败即 revert → 0 条 ERC20 返回值风险 |
| `reentrancy-no-eth` | 5 | 全部误报 | 5 条入口均带 `nonReentrant`：`executeTimelock` L316、`V3Adapter.removeLiquidity` L268（另 `onlyVault`）、`collectFees` L311-312（另 `onlyVault`）、`withdrawAll` L559（另 `onlyVault`）、`Vault.rebalance` L456。工具不识别 OZ ReentrancyGuard 的 storage 锁 |
| `uninitialized-local` | 2 | 全部误报 | `_collectAllFees` 的 `totalFeesWeth`/`totalFeesUsdc`（L944-945）声明后仅参与 `+=`，Solidity 0.8 默认零值，不存在读取未初始化值 |

**`unused-return` 的 9 条整次调用明细**（其余 19 条为元组解构）：

| 调用点 | 位置 | 为何无风险 |
|---|---|---|
| `v2Adapter.addLiquidity` | Vault L695 | V2Adapter 内部 L123 自行接收 `(amount0, amount1, )`，L134-137 将剩余余额退回 Vault |
| `v2Adapter.addLiquidity` | Vault L764 | 同上（`_reinvestWithRanges`） |
| `adapter.addLiquidity` | Vault L834 | 同上（`_investOneRange`） |
| `v2Adapter.removeLiquidity` | Vault L873 | 出金量由 `idleWethBefore`/`idleUsdcBefore` 与 `...After` 差值校正（L367-378），不依赖返回值 |
| `adapter.removeLiquidity` | Vault L932-937 | 同上（`_withdrawFromV3Position`） |
| `POOL.collect` | V3Adapter L565 | 全量 `collect` 到 `VAULT`，随后将 adapter 余额全转（L572-574） |
| `POOL.burn` | V3Adapter L564 | 全量 burn 后由 collect 兜底 |
| `POOL.burn(...,0)` | V3Adapter L318 | 仅刷新手续费记账，返回值为 0 |
| `ROUTER.removeLiquidity` | V2Adapter L241-249 | 全额 LP 移除，随后将 adapter 余额全转 Vault（L252-255） |

### 4.5 Low / Informational / Optimization

| 类别 | 条数 | 裁决 |
|---|---|---|
| `timestamp` | 14 | 整类跳过：全部用于冷却期、线性释放、奖励时间窗，不参与随机数、授权或金额判定 |
| `calls-loop` | 13 | **全部误报**：循环上界固定——adapter 固定 3 个、V3 区间固定 3 档（`_investV3WithRanges` L797-809）；`rebalance` 先调 `_withdrawAllFromAdapters`（L840-849），V3 `withdrawAll` 在 L570 `delete activePositionList`，数组每轮清空重建，长度 ≤3，不存在用户可控数组的 gas DoS |
| `missing-zero-check` | 7 | **1 条真缺陷 + 2 条间接拦截 + 4 条可恢复**：`GovernanceToken.setMinter`（F-02，不可恢复）；`V3Adapter` 的 `TOKEN0/TOKEN1` 构造参数（L84-85）被 L98 `token mismatch` require 间接拦截；`Strategy`/`Oracle` 的 `governance`（构造 L27-31 / L36-46 + `setGovernance` L126-133 / L134-138）零地址后 owner 仍可补设，属健壮性建议 |
| `reentrancy-benign` | 5 | 整类跳过：无可利用的状态变更次序 |
| `naming-convention` | 54 | 整类跳过：命名风格 |
| `constable-states` / `cache-array-length` | 8 | gas 优化项，不涉及安全 |

### 4.6 工具裁决结论

Slither 的 impact 标签与真实严重性不一致，本项目已出现三类偏差：

- 标 High 的 `reentrancy-balance`：5 条，0 条可利用
- 标 Medium 的 50 条（`incorrect-equality` 15 + `unused-return` 28 + `reentrancy-no-eth` 5 + `uninitialized-local` 2）：**全部误报，0 条真实缺陷**
- 标 Low 的 `missing-zero-check`：7 条中 1 条真缺陷（F-02），2 条被构造期 `require` 间接拦截，4 条可被 owner 补设

因此裁决原则为：**工具负责覆盖，人工负责收敛**。工具的计数不构成风险清单，真实结论只来自逐条的权限、可达性、常量条件与差值校验。

---

## 5. 风险维度与缓解

设计层面的风险推演与缓解措施见 [`SECURITY.md`](./SECURITY.md)，本章仅做索引与结论汇总。

| 维度 | 结论 | 详见 |
|---|---|---|
| 三明治攻击 | 用户存取款、V2 全路径、V3 按比例撤出有滑点下限；**V3 再平衡路径缺下限（F-07）** | `SECURITY.md` §1 |
| 重入 | 核心函数均 `nonReentrant` + CEI + `SafeERC20`；Slither 9 条 High 已裁决 | `SECURITY.md` §2、本文 4.3 |
| 预言机操纵 | 30 分钟 TWAP + 波动率冷却期 + 数据源 `immutable`；失败时降级（F-04） | `SECURITY.md` §3 |
| 无常损失 | 三档区间 + V2 宽区间摊薄 + 波动率自适应 | `SECURITY.md` §4 |
| 份额价格操纵 | 首存锁 1e6 死份额至 `0xdead`（L95/L97/L258），实测攻击者无法回本 | `SECURITY.md` §5 |
| ERC4626 兼容性 | 标准取款禁用、双币入口替代（F-06） | `SECURITY.md` §6 |
| 滑点覆盖 | 3 条路径未启用（F-07） | `SECURITY.md` §"已知限制 1" |
| 单币存款 | 无法参与做市（F-08） | `SECURITY.md` §"已知限制 3" |

---

## 6. 测试证据

### 6.1 现有自动化测试

`test/` 共 23 个测试文件：

| 层级 | 文件 |
|---|---|
| 单元测试 | `unit/` 下 17 个（顶层 10 个 + `unit/vault/` 7 个）：`GovernanceTest`、`TreasuryTest`、`LiquidityMiningTest`、`TeamVestingTest`、`RebalanceStrategyTest`、`TWAPOracleTest`、`UniswapMathTest`、`UniswapV2AdapterTest`、`UniswapV3AdapterTest`、`IncentivesTest`，以及 `unit/vault/` 下 7 个（`VaultDepositTest`、`VaultWithdrawTest`、`VaultERC4626Test`、`VaultRebalanceTest`、`VaultAdminTest`、`VaultViewTest`、`VaultMiningTest`） |
| 不变量测试 | `invariant/VaultInvariantTest.t.sol` |
| Fork 测试 | `fork/ForkTest.t.sol` |
| 基础设施 | `base/BaseTest.t.sol`、`mocks/`（MockTokens、MockUniswapV2、MockUniswapV3） |

复现命令：

```bash
forge test
forge test --match-contract VaultInvariantTest
```

### 6.2 PoC

| PoC | 目标发现 | 路径 | 状态与实测结论 |
|---|---|---|---|
| `POC_BurnWithoutAllowance` | F-01 | `test/poc/POC_BurnWithoutAllowance.t.sol` | 已跑通：victim 未授予任何 allowance，minter 直接 `burn` 后余额归零 |
| `POC_SetMinterZero` | F-02 | `test/poc/POC_SetMinterZero.t.sol` | 已跑通：`setMinter(address(0))` 后 `setMinter`/`mint` 全部 revert，通道不可恢复 |
| `POC_SingleSidedIdle` | F-08 | `test/poc/POC_SingleSidedIdle.t.sol` | 已跑通：单边存 1000 USDC 时 idle 10000 bps；双边存 1 WETH + 1000 USDC 时 WETH 闲置 92.5%、USDC 为 0；六个区间现状流动性均为 0 |

运行方式：

```bash
forge test --match-path "test/poc/*" -vv
```

`POC_SingleSidedIdle` 依赖 Sepolia fork，三个测试合计约 2–4 分钟；另两个为本地部署，毫秒级。fork 测试依赖外部 RPC，免费额度限流或网络抖动时可能出现 `operation timed out` 后 revert，重跑即可，非断言失败。

PoC 的断言方向为"**证明缺陷存在**"：测试通过即缺陷成立；修复后该断言应失败（届时改为 `vm.expectRevert`）。

### 6.3 已验证行为

| 行为 | 证据 |
|---|---|
| 首存通胀攻击无法获利 | `SECURITY.md` §5 的实测数据（受害者获正份额、攻击者回本 < 25%）；仓库内无对应自动化测试，证据为当时的手工运行记录 |
| 治理参数校验（地址/金额零值与越界） | `src/governance/AdaptiveGovernance.sol`：propose L222-226、`_applyParam` L414-418；测试 `test_Revert_Propose_SpendBadTokenAddr`（`GovernanceTest.t.sol` L771）、`test_Revert_Propose_SpendZeroAmount`（L821）、`test_ApplyParam_ZeroAddressNoSync`（L667） |
| 死份额不触达 `LiquidityMining` | `_update` L439/L444 的 `DEAD_ADDRESS` 排除条件 |

---

## 7. 历史安全事件

### 7.1 私钥泄露

- **事件**：`.env.bak.20261017` 曾被提交进 git 历史（提交 `47b716f`、`ee076d5`），其中包含部署者 EOA 私钥。
- **处置**：停止使用旧账户 → 生成新 EOA 重新部署 12 个合约 → 旧私钥作废。
- **结论**：未发生资金损失；**未采用 force push 清理历史**，历史中的旧私钥一律视为已泄露。

### 7.2 凭证轮换状态

| 凭证 | 状态 |
|---|---|
| 部署者私钥 | ✅ 已轮换（旧地址废弃） |
| RPC API Key | ✅ 已轮换（旧地址废弃） |
| 区块浏览器 API Key | ✅ 已轮换（旧地址废弃） |

---

## 8. 结论与建议

### 8.1 总体评级

| 维度 | 评级 |
|---|---|
| 可利用高危漏洞 | 0（Slither 9 条 High 全部收敛为误报/已缓解） |
| 真实缺陷 | 2 项：F-01（Medium）、F-02（Low） |
| 已知风险缺口 | 1 项：F-07（V3 再平衡滑点，Medium） |
| 设计取舍 | 4 项：F-03、F-04、F-06、F-08 |
| **整体** | **中低风险**，无资金可直接被盗的路径 |

### 8.2 版本策略：v1 冻结，修复走分支与下一版

v1 已部署至 Sepolia 并完成 Etherscan 源码验证，链上字节码即事实。修复不采用“就地改仓库 + 重部署”的方式，因为它会同时破坏三件事：已验证源码与字节码的对应关系、已经对外公布并接入前端的合约地址、以及围绕这些地址产生的测试与运行记录。

替代路径分三层：

| 层级 | 内容 | 生效范围 |
|---|---|---|
| v1（当前） | 代码与链上逐字一致；缺陷以 F 条目记录，并附 PoC 复现 | 已部署，不再变更 |
| 修复分支 | 在独立分支完成代码修复与单元测试，验证方案可行 | 不合并 main、不部署 |
| 下一版 | 汇总分支成果，重新部署并迁移，同步更新前端地址 | 需迁移方案 |

### 8.3 后续行动

| 优先级 | 行动 |
|---|---|
| P1 | 建立 `fix/govtoken-burn-auth` 分支：`burn` 加 allowance、`setMinter` 加零地址校验 + 单测 |
| P2 | V3 再平衡滑点下限接入 `maxSlippageBps`（F-07） |
| P2 | 单边存款闲置：按仓位需求分发 + 全局单次 swap（需新部署生效，见 F-08） |
| P2 | 主网阶段 owner 移交多签 |

---
