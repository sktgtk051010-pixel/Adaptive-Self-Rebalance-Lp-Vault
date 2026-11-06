// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AdaptiveLPVault} from "../../src/vault/AdaptiveLPVault.sol";
import {TWAPOracle} from "../../src/oracles/TWAPOracle.sol";
import {AdaptiveRebalanceStrategy} from "../../src/strategies/AdaptiveRebalanceStrategy.sol";
import {AdaptiveGovernance, GovernanceToken} from "../../src/governance/AdaptiveGovernance.sol";
import {UniswapV2Adapter} from "../../src/adapters/UniswapV2Adapter.sol";
import {UniswapV3Adapter} from "../../src/adapters/UniswapV3Adapter.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {IUniswapV3Pool} from "../../src/interfaces/IUniswapV3.sol";
import {FullMath, TickMath, LiquidityAmounts} from "../../src/libraries/UniswapMath.sol";

/// @notice PoC：单边 USDC 存款后资金闲置比例，以及按需求分发能投出多少
/// @dev fork Sepolia 并新建空金库，排除已部署实例的存量干扰
contract POC_SingleSidedIdle is Test {
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant V2_ROUTER = 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3;
    address constant V3_POOL_500 = 0x3289680dD4d6C10bb19b899729cda5eEF58AEfF1;
    address constant V3_POOL_3000 = 0x6Ce0896eAE6D4BD668fDe41BB784548fb8F59b50;

    // 与 Vault 常量一致
    uint256 constant TOTAL_WEIGHT = 10_000;
    uint256 constant V3_LOW_WEIGHT = 3_000;
    uint256 constant V3_HIGH_WEIGHT = 5_000;
    uint256 constant TIGHT_PCT = 4_000;
    uint256 constant MEDIUM_PCT = 3_500;
    uint256 constant WIDE_PCT = 2_500;
    uint256 constant TOTAL_RANGE_LOCAL = 10_000;

    AdaptiveLPVault vault;
    TWAPOracle oracle;
    AdaptiveRebalanceStrategy strat;
    address v3Low;
    address v3High;

    address user = address(0xBEEF);
    uint256 constant AMOUNT = 1_000e6;

    function setUp() public {
        try vm.envString("SEPOLIA_RPC_URL") returns (string memory rpcUrl) {
            vm.createSelectFork(rpcUrl);
        } catch {
            vm.skip(true);
            return;
        }

        GovernanceToken govToken = new GovernanceToken();
        AdaptiveGovernance governance = new AdaptiveGovernance(address(govToken));
        strat = new AdaptiveRebalanceStrategy(address(governance));
        oracle = new TWAPOracle(V3_POOL_3000, WETH, USDC, address(governance));

        vault = new AdaptiveLPVault(USDC, WETH, address(oracle), address(strat), "Adaptive LP Vault", "ALP-VAULT");

        UniswapV2Adapter v2 = new UniswapV2Adapter(V2_ROUTER, address(vault), USDC, WETH);

        IUniswapV3Pool pool500 = IUniswapV3Pool(V3_POOL_500);
        v3Low = address(
            new UniswapV3Adapter(
                V3_POOL_500,
                address(vault),
                pool500.token0(),
                pool500.token1(),
                ILPAdapter.AdapterType.UNISWAP_V3_LOW_FEE
            )
        );

        IUniswapV3Pool pool3000 = IUniswapV3Pool(V3_POOL_3000);
        v3High = address(
            new UniswapV3Adapter(
                V3_POOL_3000,
                address(vault),
                pool3000.token0(),
                pool3000.token1(),
                ILPAdapter.AdapterType.UNISWAP_V3_HIGH_FEE
            )
        );

        vault.setAdapters(address(v2), v3Low, v3High);

        deal(USDC, user, AMOUNT * 10);
        vm.prank(user);
        IERC20(USDC).approve(address(vault), type(uint256).max);
    }

    /// @notice 基线：单边存款后资金是否全量闲置
    function test_SingleSidedUsdcStaysIdle() public {
        uint256 idleBefore = _idleUsdc();
        uint256 assetsBefore = vault.totalAssets();

        vm.prank(user);
        uint256 shares = vault.deposit(AMOUNT, user);

        uint256 idleAfter = _idleUsdc();
        uint256 assetsAfter = vault.totalAssets();
        uint256 idleDelta = idleAfter - idleBefore;

        console2.log("shares            :", shares);
        console2.log("totalAssets before:", assetsBefore);
        console2.log("totalAssets after :", assetsAfter);
        console2.log("idleDelta (USDC)  :", idleDelta);
        console2.log("idle ratio bps    :", idleDelta * 10_000 / AMOUNT);

        assertGe(idleDelta, AMOUNT * 9 / 10, "deposit >=90% stayed idle");
    }

    /// @notice 反事实：现状分配投不出任何流动性，按需求配比则可投
    function test_Counterfactual_DemandVsAllocation() public {
        vm.prank(user);
        vault.deposit(AMOUNT, user);

        (, int24 tick) = oracle.getTWAPPrice();
        (int24 tL, int24 tU, int24 mL, int24 mU, int24 wL, int24 wU) = strat.getRangeTicks(tick);

        _report("v3Low  tight ", v3Low, tL, tU, AMOUNT * V3_LOW_WEIGHT / TOTAL_WEIGHT * TIGHT_PCT / TOTAL_RANGE_LOCAL);
        _report("v3Low  medium", v3Low, mL, mU, AMOUNT * V3_LOW_WEIGHT / TOTAL_WEIGHT * MEDIUM_PCT / TOTAL_RANGE_LOCAL);
        _report("v3Low  wide  ", v3Low, wL, wU, AMOUNT * V3_LOW_WEIGHT / TOTAL_WEIGHT * WIDE_PCT / TOTAL_RANGE_LOCAL);
        _report("v3High tight ", v3High, tL, tU, AMOUNT * V3_HIGH_WEIGHT / TOTAL_WEIGHT * TIGHT_PCT / TOTAL_RANGE_LOCAL);
        _report(
            "v3High medium", v3High, mL, mU, AMOUNT * V3_HIGH_WEIGHT / TOTAL_WEIGHT * MEDIUM_PCT / TOTAL_RANGE_LOCAL
        );
        _report("v3High wide  ", v3High, wL, wU, AMOUNT * V3_HIGH_WEIGHT / TOTAL_WEIGHT * WIDE_PCT / TOTAL_RANGE_LOCAL);
    }

    /// @notice 补证：双边按 1:2 价值比存入，与仓位需求不符，至少一侧仍显著闲置
    function test_BilateralMismatchStillIdle() public {
        uint256 wethAmt = 1e18;
        deal(WETH, user, wethAmt);

        vm.startPrank(user);
        IERC20(WETH).approve(address(vault), wethAmt);
        uint256 shares = vault.deposit(wethAmt, AMOUNT, 0);
        vm.stopPrank();

        (uint256 idleWETH, uint256 idleUSDC,,,,,,) = vault.getDistribution();

        console2.log("bilateral shares   :", shares);
        console2.log("idle WETH          :", idleWETH);
        console2.log("idle USDC          :", idleUSDC);

        assertTrue(
            idleWETH * 100 > wethAmt * 5 || idleUSDC * 100 > AMOUNT * 5,
            "bilateral mismatch leaves >=5% idle on one side"
        );
    }

    function _report(string memory tag, address adapter, int24 tickLower, int24 tickUpper, uint256 usdcAlloc)
        internal
        view
    {
        IUniswapV3Pool pool = IUniswapV3Pool(UniswapV3Adapter(adapter).pool());
        (uint160 sqrtP,,,,,,) = pool.slot0();
        uint160 a = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 b = TickMath.getSqrtRatioAtTick(tickUpper);

        // 现状：WETH 侧为 0，能投出的流动性
        uint128 lNow = LiquidityAmounts.getLiquidityForAmounts(sqrtP, a, b, 0, usdcAlloc);

        // 把同等价值折成 WETH 作为上界，与 USDC 一起取 min
        uint256 wethEq = _usdcToWeth(usdcAlloc, sqrtP, pool.token0() == USDC);
        uint128 lNeed = LiquidityAmounts.getLiquidityForAmounts(sqrtP, a, b, wethEq, usdcAlloc);
        (uint256 need0, uint256 need1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, a, b, lNeed);

        console2.log(tag);
        console2.log("  allocated USDC:", usdcAlloc);
        console2.log("  liquidity now :", uint256(lNow));
        console2.log("  need WETH     :", need0);
        console2.log("  need USDC     :", need1);
        console2.log("  liquidity if funded:", uint256(lNeed));

        assertEq(uint256(lNow), 0, "current allocation yields zero liquidity");
        assertGt(uint256(lNeed), 0, "demand-based allocation yields liquidity");
    }

    /// @dev 用现货 sqrtPrice 把 USDC 数量折成 WETH 数量
    function _usdcToWeth(uint256 usdcAmt, uint160 sqrtP, bool token0IsUsdc) internal pure returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), 1 << 96);
        if (token0IsUsdc) {
            return FullMath.mulDiv(usdcAmt, priceX96, 1 << 96);
        }
        return FullMath.mulDiv(usdcAmt, 1 << 96, priceX96);
    }

    function _idleUsdc() internal view returns (uint256) {
        (, uint256 idleUSDC,,,,,,) = vault.getDistribution();
        return idleUSDC;
    }
}
