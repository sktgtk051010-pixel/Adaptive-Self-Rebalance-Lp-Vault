# PoC 讲解手册

面试前复习用。三个 PoC 的逐段拆解、共同套路、高频追问。

---

## 0. 总原则

PoC 是一个**断言方向反过来的测试**：

| | 普通单测 | PoC |
|---|---|---|
| 断言什么 | 行为符合预期 | 缺陷确实存在 |
| 通过意味着 | 代码没问题 | **问题被证实** |
| 修好之后 | 继续通过 | **必须变红**，然后改成 `vm.expectRevert` |

一句话：**PoC 绿了不是好消息，是坏消息被坐实了。**

---

## 1. F-01：`POC_BurnWithoutAllowance.t.sol`

### 代码

```solidity
contract POC_BurnWithoutAllowance is Test {
    GovernanceToken token;
    address victim = address(0xBEEF);

    function setUp() public {
        token = new GovernanceToken();
    }

    function test_MinterCanBurnAnyoneWithoutAllowance() public {
        token.mint(victim, 1_000e18);

        assertEq(token.balanceOf(victim), 1_000e18, "setup balance");
        assertEq(token.allowance(victim, address(this)), 0, "victim granted no allowance");

        token.burn(victim, 1_000e18);

        assertEq(token.balanceOf(victim), 0, "balance wiped without allowance");
    }
}
```

### 逐段

**L9 `is Test`**：只有继承它，才拿得到 `vm`（作弊码）、`assertEq`、`console2`。

**L11 `victim = address(0xBEEF)`**：随便造一个地址当受害者，PoC 里地址只是标签。

**L15 `new GovernanceToken()`**：在测试进程里部署全新代币。构造函数执行 `minter = msg.sender`，此刻 `msg.sender` 是测试合约自己，所以测试合约天然是 minter，不用 `prank`。

**L19-22 铺前提 + 留证据**：

- `mint(victim, 1000e18)` —— 受害者有钱，销毁才有意义
- `balanceOf == 1000e18` —— 确认钱到位
- `allowance(victim, this) == 0` —— **关键证据**：受害者从没授权

省掉 allowance 那句，面试官会说"也许人家授权过"。

**L25 `burn(victim, ...)` 核心动作**：没有 `prank`（调用者不是受害者）、没有 `approve`（从没授权），直接成功。

**L30 判决**：把 L22 和 L30 并排读 —— **授权额度 = 0，但余额被清零**。不需要解释，缺陷自己站出来了。

### 30 秒讲法

> 我部署一个代币，给受害者 mint 1000 枚，先断言他对 minter 的 allowance 是 0，然后 minter 直接调 burn，最后断言余额变成 0。allowance 为 0 却能销毁，就是 F-01。

---

## 2. F-02：`POC_SetMinterZero.t.sol`

### 代码

```solidity
function test_SetMinterZeroLocksChannelForever() public {
    token.mint(address(0xCAFE), 1e18);
    assertEq(token.minter(), address(this), "minter is test contract");

    token.setMinter(address(0));
    assertEq(token.minter(), address(0), "minter overwritten to zero");

    vm.expectRevert("GovToken: not minter");
    token.setMinter(address(this));

    vm.expectRevert("GovToken: not minter");
    token.mint(address(0xCAFE), 1e18);
}
```

### 两幕结构

**第一幕（L16-18）：证明通道现在是好的。**
先 mint 一次，再断言 `minter` 是测试合约。没有这句，"锁死"就没有对照物。

**第一幕判决（L21-22）：脏数据写进去了。**
`setMinter(address(0))` 没有零地址校验，零地址被原样写进 storage。

**第二幕（L25-30）：方向变了 —— 证明再也成功不了。**

`vm.expectRevert("GovToken: not minter")` 的语义是：**下一句调用必须 revert，且理由必须匹配这个字符串**。匹配不上，测试失败。

为什么匹配字符串而不是空 `expectRevert()`：要证明卡在 `require(msg.sender == minter)` 那一行，不是随便什么原因失败。

L29-30 再补一刀：不只 `setMinter` 死，`mint` 也死 —— 证明整个 minter 通道都废了。

### 为什么必须两幕

- 只有第一幕 → 只能说明"能写零地址"，是个健壮性问题
- 只有第二幕 → 说明不了"为什么会死"
- 两幕合起来 → **能写进去，且写进去就出不来**，这才叫永久锁死

### 30 秒讲法

> 先 mint 一次证明通道正常，然后 `setMinter(address(0))` 成功写入，断言 `minter` 变成零地址；接着用 `expectRevert` 证明原 minter 再也调不动 `setMinter` 和 `mint`。能写进去且不可恢复，就是 F-02。

---

## 3. F-08：`POC_SingleSidedIdle.t.sol`

三块：环境搭建 → 基线测试 → 反事实计算。

### 3.1 fork 守卫

```solidity
try vm.envString("SEPOLIA_RPC_URL") returns (string memory rpcUrl) {
    vm.createSelectFork(rpcUrl);
} catch {
    vm.skip(true);
    return;
}
```

三件事：

1. `vm.envString` 从环境变量读 RPC 地址 —— CI 里没有这个变量
2. `try/catch` 兜住：读不到就 `vm.skip(true)`，测试标记为 skipped 而不是 failed
3. `vm.createSelectFork(rpcUrl)` 把测试进程挂到 Sepolia 最新块

**fork 干了什么**：之后读 `pool.slot0()`、`IERC20(USDC).balanceOf(...)`，Foundry 会去 Sepolia 节点取真实数据，像本地合约一样返回。不用自己造池子、造价格、造代币。

**为什么要 `return`**：`skip` 只是标记，setUp 还会继续跑；后面 `deal(USDC, ...)` 需要 USDC 合约真实存在，非 fork 环境没有代码会崩。skip 完必须立刻退出。

### 3.2 为什么新建整套实例，而不是打已部署地址

```solidity
vault = new AdaptiveLPVault(USDC, WETH, address(oracle), address(strat), "Adaptive LP Vault", "ALP-VAULT");
```

**整个 PoC 最关键的设计决定。**

已部署的 `0xd86C...` 账上有历史存量 WETH。存 USDC 进去，`_investIdleFunds` 会把存量 WETH + 新 USDC 一起投出去，idle 反而下降，算出来的百分比是假的，甚至下溢。

新建空实例，账上只有刚存的 1000 USDC，结论才干净。

面试话术：

> 我第一次直接打已部署地址，报了 `arithmetic underflow`，因为那个金库有存量 WETH，投资反而成功了。所以改成 fork 上新建空实例 —— 空账本才能暴露单边问题。

### 3.3 接线与给钱

```solidity
vault.setAdapters(address(v2), v3Low, v3High);
deal(USDC, user, AMOUNT * 10);
vm.prank(user);
IERC20(USDC).approve(address(vault), type(uint256).max);
```

- `setAdapters`：金库默认没有适配器，不接上 `_investIdleFunds` 什么都不做，测出 100% 闲置是假的
- `deal`：Foundry 作弊码，直接往任意地址写 ERC20 余额，只改余额不改总量
- `vm.prank`：**只对紧跟着的那一句生效**。隔一句就失效，新手最常踩的坑

### 3.4 基线测试

```solidity
uint256 idleBefore = _idleUsdc();
vm.prank(user);
uint256 shares = vault.deposit(AMOUNT, user);
uint256 idleAfter = _idleUsdc();
uint256 idleDelta = idleAfter - idleBefore;
```

`deposit(assets, receiver)` 是 ERC4626 标准入口，**只收 USDC** —— "单边"的来源，不是人为构造。

**用差值而不是绝对值**：空实例里 before 是 0，差值等于绝对值。但写法上坚持差值，是为了在非空实例上也成立，通用正确姿势。

```solidity
console2.log("idle ratio bps    :", idleDelta * 10_000 / AMOUNT);
assertGe(idleDelta, AMOUNT * 9 / 10, "deposit >=90% stayed idle");
```

**为什么 `assertGe` 不用 `assertEq`**：留 10% 容差。写死 `assertEq` 会因为灰尘级差异变脆。断言"至少 90% 闲置"已足够证明缺陷。

### 3.5 反事实计算

回答面试官最难缠的问题："你说按需求分配能投出去，凭什么？"

```solidity
(, int24 tick) = oracle.getTWAPPrice();
(int24 tL, int24 tU, int24 mL, int24 mU, int24 wL, int24 wU) = strat.getRangeTicks(tick);
```

- `getTWAPPrice()` 返回 `(sqrtPriceX96, tick)`，`(, int24 tick)` 里逗号表示"第一个不要"
- `getRangeTicks` 一次拿 6 个 tick，两两一组，顺序必须和签名一致

```solidity
AMOUNT * V3_LOW_WEIGHT / TOTAL_WEIGHT * TIGHT_PCT / TOTAL_RANGE_LOCAL
```

复刻 Vault 的两步乘法：先按 adapter 权重（3000/10000），再按区间比例（4000/10000）。

1000 × 0.3 × 0.4 = **120 USDC**。这就是 `_investToAdapters` 实际切给这一档的数。注意只有 USDC，WETH 隐含为 0。

### 3.6 核心三行

```solidity
uint128 lNow   = LiquidityAmounts.getLiquidityForAmounts(sqrtP, a, b, 0, usdcAlloc);
uint256 wethEq = _usdcToWeth(usdcAlloc, sqrtP, pool.token0() == USDC);
uint128 lNeed  = LiquidityAmounts.getLiquidityForAmounts(sqrtP, a, b, wethEq, usdcAlloc);
```

- `lNow`：amount0（WETH）= 0，算出的流动性 = **0**，这就是链上真实发生的事
- `wethEq`：把 120 USDC 按现价折成等值 WETH，作为"钱够时 WETH 侧最多能给多少"的上界
- `lNeed`：两侧都有值，这次结果 > 0

再反解出每档真实需要：

```solidity
(uint256 need0, uint256 need1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, a, b, lNeed);
```

### 3.7 两条断言方向相反

```solidity
assertEq(uint256(lNow), 0, "current allocation yields zero liquidity");
assertGt(uint256(lNeed), 0, "demand-based allocation yields liquidity");
```

- 第一条：现状必须投不出去（坐实缺陷）
- 第二条：按需求配比必须投得出去（证明方案有效）

同框就把"问题"和"解法"一次讲完。

### 3.8 价格折算

```solidity
uint256 priceX96 = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), 1 << 96);
if (token0IsUsdc) return FullMath.mulDiv(usdcAmt, priceX96, 1 << 96);
return FullMath.mulDiv(usdcAmt, 1 << 96, priceX96);
```

V3 存的是 **Q96 平方根价格**，平方回来才是价格：`price = sqrtP² / 2^96`，用 `mulDiv` 防溢出。

token0 是 USDC 时 `priceX96` 表示"1 个 USDC 换多少 WETH"，直接乘；反过来就除。

**纯数学，不调用任何合约**，所以不需要改 `src/`。

### 3.9 取 idle

```solidity
(, uint256 idleUSDC,,,,,,) = vault.getDistribution();
```

`getDistribution()` 返回 8 个值，idleUSDC 是**第 2 个**。前面一个逗号跳过 idleWETH，后面 6 个逗号跳过其余六项。

**8 个返回值需要 7 个逗号** —— 数逗号是最容易错的地方。

### 45 秒讲法

> fork Sepolia，新建一套空的金库和适配器，避免已部署实例的存量 WETH 掩盖问题。单边存 1000 USDC，读 `getDistribution` 算 idle 差值，实测 10000 bps。然后做反事实：复刻 Vault 的两步权重乘法，算出每档实际分到 120、105、75 USDC，再用 `getLiquidityForAmounts` 算 —— WETH 给 0 时全部返回 0；按现价折出等值 WETH 再算，全部大于 0。所以问题在分配层，不在池子。

---

## 4. 五步模板

写新 PoC 套这个：

| 步骤 | 内容 | 对应代码 |
|---|---|---|
| 1 准备 | 部署 / 接线 / 给钱 / 授权 | `setUp` |
| 2 铺前提 | 断言"现在一切正常" | 前置 `assertEq` |
| 3 执行 | 调用那个"不该成功却成功"的函数 | 核心动作，不加 prank |
| 4 判决 | 断言错误结果成立 | 结果 `assertEq` |
| 5 打印 | 关键数字打出来给人看 | `console2.log` |

**第 2 步最容易被省，也最不能省** —— 没有前提，"缺陷"就只是"现象"。

---

## 5. 五个高频追问

| 追问 | 答法 |
|---|---|
| 为什么不用 `expectRevert` | PoC 要证明能成功；修复后才反过来 |
| 为什么 `assertGe` 不是 `assertEq` | 防灰尘误差，断言"至少 90%"已足够 |
| 为什么用差值 | 排除存量资产干扰，通用正确姿势 |
| 为什么不直接测已部署合约 | 存量 WETH 会让投资成功，掩盖单边问题 |
| fork 的意义 | 借真实池子、价格、代币，不自己造假环境 |

---

## 6. 运行

```bash
# 三个一起跑
forge test --match-path "test/poc/*" -vv

# 只看 F-08（需要 .env 里有 SEPOLIA_RPC_URL）
forge test --match-path "test/poc/POC_SingleSidedIdle.t.sol" -vv

# 只看两个毫秒级的
forge test --match-path "test/poc/POC_Burn*.t.sol" -vv
```

F-08 依赖 fork，单次约 40–150 秒；没有 RPC 时自动 skip，不会报红。
