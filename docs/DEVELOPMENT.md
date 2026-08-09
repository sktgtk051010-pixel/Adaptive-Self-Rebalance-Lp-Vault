# 开发调试指南 (DEVELOPMENT.md)

本文档记录 Adaptive LP Vault 项目的开发调试细节、核心机制说明、已知坑点和测试设计思路。

---

## 一、滑点机制详解

### 1.1 滑点保护层级

本项目采用**多层滑点保护**机制：

| 层级 | 位置 | 参数 | 默认值 | 作用 |
|------|------|------|--------|------|
| 用户层 | `withdrawDual` | `minWETH`/`minUSDC` | 用户传入 | 用户自定义最低接受输出 |
| 金库层 | `AdaptiveLPVault` | `maxSlippageBps` | 100 (1%) | 传给adapter的amountMin保护 |
| Adapter层 | V2/V3 Adapter | 内部计算 | 99%预期值 | removeLiquidity时的最低输出 |

### 1.2 withdrawDual 滑点逻辑（修复后）

**修复前的Bug**：
- 旧逻辑在撤出资金**前**就把输出打了99折（`theoretical * 99 / 100`）
- 这导致用户最多只能拿到理论值的99%，多余1%强制留在合约
- 本质是**强制扣费**，不是滑点保护
- 没有正确区分闲置资金和adapter资金的分配

**修复后逻辑**：
```solidity
function withdrawDual(uint256 shares, uint256 minWETH, uint256 minUSDC)
    external nonReentrant returns (uint256 wethOut, uint256 usdcOut)
{
    // 1. 计算份额比例
    uint256 sharePct = FullMath.mulDiv(shares, WAD, totalSupply());

    // 2. 记录撤出前合约闲置余额
    uint256 idleWethBefore = IERC20(WETH).balanceOf(address(this));
    uint256 idleUsdcBefore = IERC20(asset()).balanceOf(address(this));

    // 3. 销毁份额（Checks-Effects-Interactions）
    _burn(msg.sender, shares);

    // 4. 从适配器撤出对应比例资金（内部有maxSlippageBps保护）
    _withdrawFromAdapters(sharePct);

    // 5. 计算撤出后余额
    uint256 wethBalAfter = IERC20(WETH).balanceOf(address(this));
    uint256 usdcBalAfter = IERC20(asset()).balanceOf(address(this));

    // 6. 用户应得 = 闲置资金的sharePct比例 + 从adapter撤出的全部资金
    //    滑点损失由赎回用户承担，不摊给其他用户
    wethOut = FullMath.mulDiv(idleWethBefore, sharePct, WAD)
              + (wethBalAfter - idleWethBefore);
    usdcOut = FullMath.mulDiv(idleUsdcBefore, sharePct, WAD)
              + (usdcBalAfter - idleUsdcBefore);

    // 7. 用户层滑点保护
    if (wethOut < minWETH || usdcOut < minUSDC) revert SlippageExceeded();

    // 8. 转账
    IERC20(WETH).safeTransfer(msg.sender, wethOut);
    IERC20(asset()).safeTransfer(msg.sender, usdcOut);
}
```

**数学验证**：
- 假设：总供应1000 shares，闲置WETH=10，adapter WETH=90，用户赎回100 shares（10%）
- 无滑点情况：撤出9 → wethOut = 10*10% + 9 = 10 ✓
- 有滑点情况（只撤出8）：wethOut = 1 + 8 = 9（用户承担1损失）✓
- 其他用户不受影响：剩余900 shares对应90 WETH ✓

### 1.3 前端滑点计算

前端不应传 `min=0`，而应根据预期输出计算合理min：

```javascript
// 计算预期输出
var totalSupplyBN = await C.vault.totalSupply();
var d = await C.vault.getDistribution();
var totalWeth = d[0].add(d[2]).add(d[4]).add(d[6]);
var totalUsdc = d[1].add(d[3]).add(d[5]).add(d[7]);
var ratioScaled = sharesWei.mul(ratioScale).div(totalSupplyBN);
var outWeth = totalWeth.mul(ratioScaled).div(ratioScale);
var outUsdc = totalUsdc.mul(ratioScaled).div(ratioScale);

// 1%滑点容忍
var minWeth = outWeth.mul(99).div(100);
var minUsdc = outUsdc.mul(99).div(100);
```

---

## 二、TWAP 预言机工作原理

### 2.1 Uniswap V3 价格表示

Uniswap V3 使用 `sqrtPriceX96` 表示价格：
- `sqrtPriceX96 = sqrt(price) × 2^96`
- `price = token1_raw / token0_raw`（原始单位，未按decimals调整）

**关键：token0/token1顺序问题**

| 环境 | token0 | token1 | price含义 |
|------|--------|--------|-----------|
| Sepolia | USDC (6位) | WETH (18位) | price = WETH_raw / USDC_raw |
| 本地Mock | WETH (18位) | USDC (6位) | price = USDC_raw / WETH_raw |

合约通过 `TOKEN0_IS_WETH` immutable 变量在构造时确定顺序：
```solidity
TOKEN0_IS_WETH = (IUniswapV3Pool(address(ORACLE_POOL)).token0() == _weth);
```

### 2.2 价格换算公式

**1 ETH = ? USDC（显示价格，人类可读）**

当 token0=WETH, token1=USDC（本地Mock环境）：
```
USDC_raw per WETH_raw = price = sqrtPriceX96² / 2^192
显示价格 = USDC_raw / 10^6 = (sqrtPriceX96² × 10^12) / 2^192
```

当 token0=USDC, token1=WETH（Sepolia环境）：
```
WETH_raw per USDC_raw = price = sqrtPriceX96² / 2^192
USDC_raw per WETH_raw = 1 / price = 2^192 / sqrtPriceX96²
显示价格 = (2^192 × 10^12) / sqrtPriceX96²
```

**验证（价格2000 USDC/ETH，token0=WETH）**：
- price = 2000 × 10^6 / 10^18 = 2 × 10^-9
- sqrtPrice = sqrt(2×10^-9) ≈ 4.472 × 10^-5
- sqrtPriceX96 = 4.472×10^-5 × 2^96 ≈ 3.543 × 10^24 ✓

### 2.3 TWAP采样逻辑

```solidity
function getTWAPPrice() public view returns (uint160 sqrtPriceX96Twap, int24 tick) {
    uint32[] memory secondsAgos = new uint32[](2);
    secondsAgos[0] = twapWindow;  // 例如1800秒前
    secondsAgos[1] = 0;          // 当前

    (int56[] memory tickCumulatives, ) = ORACLE_POOL.observe(secondsAgos);

    // 平均tick = (当前tickCumulative - 过去tickCumulative) / 时间窗口
    int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
    int24 arithmeticMeanTick = int24(tickCumulativesDelta / int56(uint56(twapWindow)));

    // 从tick反算sqrtPriceX96
    sqrtPriceX96Twap = TickMath.getSqrtRatioAtTick(arithmeticMeanTick);
}
```

### 2.4 前端价格计算Bug修复

**原Bug**：
1. 硬编码假设 token0=USDC，没有处理 token0=WETH 的情况
2. `BigNumber.toNumber()` 大数溢出（超过2^53 ≈ 9×10^15时精度丢失）

**修复后**：
```javascript
function calcPrice(sqrtPriceX96) {
    var Q192 = ethers.BigNumber.from(2).pow(192);
    var PRICE_SCALE = ethers.BigNumber.from('1000000000000'); // 1e12 = 1e18 / 1e6
    var priceSquared = sqrtPriceX96.mul(sqrtPriceX96);

    var usdcRawPerWeth;
    if (token0IsWeth) {
        // token0=WETH, token1=USDC
        usdcRawPerWeth = priceSquared.mul(PRICE_SCALE).div(Q192);
    } else {
        // token0=USDC, token1=WETH
        usdcRawPerWeth = Q192.mul(PRICE_SCALE).div(priceSquared);
    }

    // 字符串处理避免JS Number溢出
    var priceStr = usdcRawPerWeth.toString();
    if (priceStr.length <= 6) {
        return parseFloat('0.' + priceStr.padStart(6, '0'));
    }
    var intPart = priceStr.slice(0, -6);
    var decPart = priceStr.slice(-6);
    return parseFloat(intPart + '.' + decPart);
}
```

---

## 三、本地部署与调试流程

### 3.1 启动Anvil本地节点

```bash
# WSL环境
/home/gintoki/.foundry/bin/anvil --chain-id 31337 --port 8545
```

Anvil默认账户：
- 账户0: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` (10000 ETH)
- 私钥0: `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`

### 3.2 部署合约到本地

```bash
forge script script/DeployLocal.s.sol:DeployLocalScript \
    --rpc-url http://127.0.0.1:8545 --broadcast
```

部署脚本会自动：
1. 部署Mock WETH/USDC
2. 部署Mock Uniswap V2/V3
3. 设置初始价格 2000 USDC/ETH
4. 部署所有核心合约
5. 给前3个测试账户mint 100 WETH + 200,000 USDC
6. 给激励合约充值 100,000 USDC

### 3.3 本地部署地址（默认）

| 合约 | 地址 |
|------|------|
| WETH | `0x5FbDB2315678afecb367f032d93F642f64180aa3` |
| USDC | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` |
| Vault | `0x9A676e781A523b5d0C0e43731313A708CB607508` |
| Oracle | `0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82` |
| Strategy | `0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0` |
| Governance | `0x610178dA211FEF7D417bC0e6FeD39F05609AD788` |
| V2Adapter | `0x0B306BF915C4d645ff596e518fAf3F9669b97016` |
| V3LowAdapter | `0x959922bE3CAee4b8Cd9a407cc3ac1C251C2007B1` |
| V3HighAdapter | `0x9A9f2CCfdE556A7E9Ff0848998Aa4a0CFD8863AE` |
| Incentives | `0x3Aa5ebB10DC797CAC828524e59A333d0A371443c` |

### 3.4 MetaMask配置本地网络

1. 网络名称：`Local Anvil`
2. RPC URL：`http://127.0.0.1:8545`
3. 链ID：`31337`
4. 货币符号：`ETH`

导入账户0私钥：`0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`

### 3.5 前端使用

1. 用浏览器打开 `frontend/index.html`
2. 连接MetaMask，会自动检测网络
3. 如果不在本地或Sepolia，会尝试切换
4. 前端已内置本地部署地址，无需手动配置

### 3.6 cast命令验证

```bash
# 查询totalSupply
cast call <vault_address> 'totalSupply()(uint256)' --rpc-url http://127.0.0.1:8545

# 查询TOKEN0_IS_WETH
cast call <vault_address> 'TOKEN0_IS_WETH()(bool)' --rpc-url http://127.0.0.1:8545

# 查询TWAP价格
cast call <oracle_address> 'getTWAPPrice()(uint160,int24)' --rpc-url http://127.0.0.1:8545
```

---

## 四、已知坑点与注意事项

### 4.1 Mock合约与真实合约的差异

| 问题 | Mock行为 | 真实合约行为 | 影响 |
|------|----------|--------------|------|
| token排序 | createPool**不排序**，直接用传入顺序 | UniswapV3Factory排序，地址小的为token0 | 本地token0=WETH，Sepolia token0=USDC |
| V2 addLiquidity | 直接用传入值，不做最优计算 | Router会计算最优LP数量 | 测试中代币比例不影响LP数量 |
| observe | 简化实现，假设价格一直是当前价格 | 真实历史tick累积 | TWAP在本地就是当前价格 |
| V3手续费 | mockFeesPerPosition硬编码 | 真实交易产生手续费 | 测试中手续费收益固定 |

### 4.2 WSL环境问题

1. **PATH问题**：WSL环境PATH不完整，基础命令可能找不到
   - 解决：使用绝对路径如 `/usr/bin/tail`、`/usr/bin/grep`
2. **NAT警告**：启动时会有 "检测到localhost已转发" 警告
   - 这是正常stderr输出，不影响命令执行
3. **forge路径**：`/home/gintoki/.foundry/bin/forge`
4. **PowerShell不支持&&**：Windows PowerShell中 `&&` 不是有效分隔符
   - 解决：分开执行命令，或使用WSL bash -c包裹

### 4.3 测试注意事项

1. **withdrawDual不要传min=0**：虽然测试能过，但没有覆盖滑点逻辑
   - 正确做法：根据getDistribution()和totalSupply()计算预期输出，设置95-99%作为min
2. **first rebalance特殊处理**：第一次rebalance不需要冷却期
3. **价格变动后需要warp**：setPrice后需要skip/warp时间才能再次rebalance
4. **V2Adapter onlyVault异常**：collectFees和removeLiquidity的onlyVault检查行为与addLiquidity相反（待修复）
5. **份额小数位**：ALP份额是6位小数，不是18位
6. **DUST_THRESHOLD**：1000 wei USDC以下视为灰尘

### 4.4 前端BigNumber处理

1. **永远不要对BigNumber使用toNumber()**：超过2^53会溢出
   - 用 `.toString()` 后手动处理小数位
2. **ethers.js v5**：项目使用ethers v5.7.2 UMD版本
   - BigNumber运算用 `.add()`, `.sub()`, `.mul()`, `.div()`
3. **单位转换**：`ethers.utils.parseUnits("1.5", 6)` 解析为 1500000

---

## 五、测试设计思路

### 5.1 测试文件结构

```
test/
├── BaseTest.t.sol              # 测试基类，部署所有合约
├── unit/
│   ├── ComponentsTest.t.sol    # 各组件独立测试（V2/V3/Oracle/Strategy/Incentives/Governance）
│   ├── VaultUnitTest.t.sol     # 金库核心测试（存款/取款/重平衡/滑点）
│   ├── UniswapMathTest.t.sol   # 数学库测试
│   ├── MockV2Test.t.sol        # Mock V2合约测试
│   └── MockV3Test.t.sol        # Mock V3合约测试
├── integration/
│   └── IntegrationTest.t.sol   # 端到端集成测试
├── fork/
│   └── ForkTest.t.sol          # 主网分叉测试
└── mocks/
    ├── MockUniswapV2.sol       # V2 Factory/Router/Pair Mock
    └── MockUniswapV3.sol       # V3 Factory/Pool Mock
```

### 5.2 BaseTest.setUp()设计

setUp()模拟完整的生产环境：
1. 部署Mock WETH/USDC
2. 部署Mock Uniswap V2/V3（两个费率池：0.05%和0.30%）
3. 设置初始价格 2000 USDC/ETH
4. 部署治理、策略、预言机
5. 部署V2/V3适配器（注意：需要先部署vault才能设置正确的vault地址）
6. 部署金库，设置适配器
7. 给测试用户mint代币：alice/bob/charlie各1000 WETH + 2M USDC
8. 给激励合约mint 100,000 USDC
9. 授权所有额度

### 5.3 正常用例编写模式

```solidity
function test_Deposit_DualAsset() public {
    // 1. 准备：用户存款
    uint256 shares = _deposit(alice, 1 ether, 2000e6);

    // 2. 断言：验证状态变化
    assertGt(shares, 0);
    assertEq(vault.balanceOf(alice), shares);
    assertGt(vault.totalAssets(), 0);
}
```

### 5.4 异常回滚用例编写模式

```solidity
function test_Revert_Deposit_ZeroAmount() public {
    vm.startPrank(alice);
    vm.expectRevert();  // 期望回滚
    vault.deposit(0, 0, 0);
    vm.stopPrank();
}

// 或指定具体错误
function test_WithdrawDual_RevertWhenSlippageTooHigh() public {
    uint256 shares = _deposit(alice, 10 ether, 20000e6);
    vm.startPrank(alice);
    vm.expectRevert(AdaptiveLPVault.SlippageExceeded.selector);
    vault.withdrawDual(shares, 100 ether, 200000e6);
    vm.stopPrank();
}
```

### 5.5 滑点场景测试要点

1. **正常滑点**：计算预期输出，设置99%作为min，应成功
2. **滑点过大**：设置不可能达到的min，应revert SlippageExceeded
3. **全部赎回**：totalSupply应为0，用户收到所有资金
4. **部分赎回**：剩余份额仍有价值
5. **多用户隔离**：A赎回不影响B的资产
6. **重平衡后赎回**：资金从adapter撤出，滑点保护仍有效

### 5.6 Cheatcodes常用

```solidity
vm.prank(addr);           // 下一次调用以addr身份
vm.startPrank(addr);      // 开始以addr身份
vm.stopPrank();           // 停止
vm.warp(timestamp);       // 设置block.timestamp
vm.roll(blockNumber);     // 设置block.number
skip(seconds);            // 快进时间
vm.expectRevert();        // 期望下一次调用回滚
vm.assume(condition);     // fuzz测试条件过滤
makeAddr("name");         // 生成确定性地址
assertApproxEqRel(a, b, 0.01e18);  // 近似相等（1%误差）
```

### 5.7 避免"测试全过但线上报错"

1. **不要传min=0**：滑点参数要真实计算
2. **测试token0/token1两种顺序**：本地Mock和Sepolia顺序不同
3. **不要依赖Mock的简化行为**：Mock的observe、手续费等与真实合约不同
4. **多用户场景**：单用户测试通过不代表多用户无问题
5. **边界值测试**：零份额、全部份额、极小金额
6. **状态变化后验证**：rebalance后、withdraw后验证totalAssets、balanceOf
7. **事件验证**：重要操作验证事件是否正确触发

---

## 六、Bug修复记录

### Bug #1: withdrawDual滑点逻辑错误（已修复）

**现象**：前端withdraw总是触发SlippageExceeded
**根因**：合约在撤出前就把输出打99折，强制扣除1%资金
**修复**：改为先撤出再计算实际输出，滑点损失由赎回用户承担
**文件**：`src/vault/AdaptiveLPVault.sol` withdrawDual函数

### Bug #2: 前端TWAP价格显示错误（已修复）

**现象**：1 ETH显示约2万美元（10倍错误）
**根因**：
1. 硬编码token0=USDC，本地环境token0=WETH时公式反向
2. BigNumber.toNumber()大数溢出
**修复**：
1. 从合约读取TOKEN0_IS_WETH，动态选择公式
2. 用字符串处理避免JS Number溢出
**文件**：`frontend/app.js` calcPrice函数

### Bug #3: 前端withdraw传min=0（已修复）

**现象**：虽然不报错，但没有滑点保护
**根因**：前端直接传(0,0)
**修复**：根据getDistribution()计算预期输出，设置99%作为min
**文件**：`frontend/app.js` withdraw函数

---

## 七、面试口述话术

### 滑点Bug

"我们项目的withdrawDual函数之前有个经典滑点bug。旧逻辑在从adapter撤出资金**之前**，就把理论输出打了99折，然后用这个打折后的值和用户的min比较。这导致两个问题：第一，用户最多只能拿到理论值的99%，1%强制留在合约里，这不是滑点保护而是强制扣费；第二，滑点损失没有正确归属，应该由赎回用户承担的损失摊给了所有持有人。

修复方案是：先记录闲置余额，burn份额，从adapter撤出资金，然后计算用户应得 = 闲置资金的份额比例 + 撤出的adapter资金。这样撤出时的滑点损失自然体现在撤出金额少了，由赎回用户自己承担，其他用户不受影响。用户传入的minWETH/minUSDC作为额外保护。"

### TWAP价格异常

"前端价格显示bug有两个原因。第一是token顺序问题：Uniswap V3的sqrtPriceX96 = sqrt(token1/token0) × 2^96，在Sepolia上USDC地址小是token0，但在我们本地Mock环境里WETH是token0，价格公式是反的。第二是JavaScript大数溢出：sqrtPriceX96大约是3.5×10^24，平方后超过JS Number的安全整数上限2^53，toNumber()会丢精度。

修复方案：合约里加了个TOKEN0_IS_WETH的immutable变量，构造时读pool.token0()判断。前端部署后先读这个标志位，动态选择价格换算方向。大数运算全部用ethers.js的BigNumber，最后转成字符串手动处理小数位，避免JS Number溢出。"

### 测试用例设计

"我们的测试分三层：单元测试覆盖每个合约的独立功能，集成测试跑完整的存款-重平衡-取款流程，还有主网分叉测试用真实Uniswap合约验证兼容性。

滑点测试我设计了几个关键场景：正常滑点用例计算预期输出设99%min应该成功；反向用例设不可能的min应该revert；边界用例包括零份额、全部赎回、极小金额；多用户场景验证A赎回不影响B。

一个重要教训是：不要为了测试方便就传min=0，那样测试全过但线上会出问题。测试要模拟真实用户行为，minAmount要根据合约状态真实计算。另外要注意Mock和真实合约的差异，比如token顺序、手续费计算，本地过了不代表主网能过。"
