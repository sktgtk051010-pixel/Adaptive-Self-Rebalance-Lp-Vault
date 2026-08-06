// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FullMath, TickMath, LiquidityAmounts} from "../../src/libraries/UniswapMath.sol";

/**
 * @title UniswapMathTest - Uniswap数学库测试
 * @notice 测试FullMath、TickMath、LiquidityAmounts库函数
 */
contract UniswapMathTest is Test {
    // ============ FullMath 测试 ============

    function test_FullMath_MulDiv() public pure {
        // 基本测试
        assertEq(FullMath.mulDiv(100, 200, 50), 400);
        assertEq(FullMath.mulDiv(1e18, 1e18, 1e18), 1e18);
        assertEq(FullMath.mulDiv(0, 100, 1), 0);
        assertEq(FullMath.mulDiv(100, 0, 1), 0);
    }

    function test_FullMath_MulDiv_LargeNumbers() public pure {
        uint256 result = FullMath.mulDiv(
            type(uint256).max,
            type(uint256).max,
            type(uint256).max
        );
        assertEq(result, type(uint256).max);
    }

    function test_FullMath_MulDivRoundingUp() public pure {
        assertEq(FullMath.mulDivRoundingUp(100, 200, 50), 400);
        // 100 * 3 / 7 = 42.857... 向上取整为43
        assertEq(FullMath.mulDivRoundingUp(100, 3, 7), 43);
        // 整除时不向上取整
        assertEq(FullMath.mulDivRoundingUp(100, 3, 3), 100);
    }

    function testFuzz_FullMath_MulDiv(uint256 a, uint256 b, uint256 denominator) public pure {
        denominator = bound(denominator, 1, type(uint256).max);
        // 避免溢出：a*b不超过type(uint256).max
        a = bound(a, 0, type(uint128).max);
        b = bound(b, 0, type(uint128).max);

        uint256 result = FullMath.mulDiv(a, b, denominator);
        // 验证结果在合理范围内
        if (a > 0 && b > 0) {
            assertTrue(result <= a * b);
        } else {
            assertEq(result, 0);
        }
    }

    // ============ TickMath 测试 ============

    function test_TickMath_Constants() public pure {
        assertEq(TickMath.MIN_TICK, -887272);
        assertEq(TickMath.MAX_TICK, 887272);
    }

    function test_TickMath_GetSqrtRatioAtTick_Zero() public pure {
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(0);
        // tick=0 对应价格1.0, sqrtPriceX96 = 2^96
        assertEq(sqrtPrice, 79228162514264337593543950336);
    }

    function test_TickMath_GetSqrtRatioAtTick_Min() public pure {
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK);
        assertEq(sqrtPrice, TickMath.MIN_SQRT_RATIO);
    }

    function test_TickMath_GetSqrtRatioAtTick_Max() public pure {
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK);
        assertEq(sqrtPrice, TickMath.MAX_SQRT_RATIO);
    }

    function test_TickMath_GetSqrtRatioAtTick_Positive() public pure {
        // tick=1 对应价格1.0001
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(1);
        assertGt(sqrtPrice, TickMath.getSqrtRatioAtTick(0));
    }

    function test_TickMath_GetSqrtRatioAtTick_Negative() public pure {
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(-1);
        assertLt(sqrtPrice, TickMath.getSqrtRatioAtTick(0));
    }

    function test_TickMath_GetTickAtSqrtRatio_One() public pure {
        int24 tick = TickMath.getTickAtSqrtRatio(79228162514264337593543950336);
        assertEq(tick, 0);
    }

    function test_TickMath_GetTickAtSqrtRatio_Min() public pure {
        int24 tick = TickMath.getTickAtSqrtRatio(TickMath.MIN_SQRT_RATIO);
        assertEq(tick, TickMath.MIN_TICK);
    }

    function test_TickMath_GetTickAtSqrtRatio_Max() public pure {
        // 测试接近最大值的tick往返
        int24 testTick = 887200;
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(testTick);
        int24 recoveredTick = TickMath.getTickAtSqrtRatio(sqrtPrice);
        assertEq(recoveredTick, testTick);
    }

    function testFuzz_TickMath_RoundTrip(int24 tick) public pure {
        tick = int24(bound(tick, TickMath.MIN_TICK, TickMath.MAX_TICK));
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(tick);
        int24 recoveredTick = TickMath.getTickAtSqrtRatio(sqrtPrice);
        // 允许±1的误差（取整）
        assertApproxEqAbs(recoveredTick, tick, 1);
    }

    function testFuzz_TickMath_SqrtRatioRoundTrip(uint160 sqrtPrice) public pure {
        sqrtPrice = uint160(bound(sqrtPrice, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO - 1));
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPrice);
        uint160 recoveredSqrtPrice = TickMath.getSqrtRatioAtTick(tick);
        // 验证往返：getSqrtRatioAtTick(getTickAtSqrtRatio(x)) <= x
        assertLe(recoveredSqrtPrice, sqrtPrice);
        // 且下一个tick的sqrtPrice > x
        uint160 nextSqrtPrice = TickMath.getSqrtRatioAtTick(tick + 1);
        assertGe(nextSqrtPrice, sqrtPrice);
    }

    // ============ LiquidityAmounts 测试 ============

    function test_LiquidityAmounts_GetLiquidityForAmount0() public pure {
        // 简单价格区间测试
        uint160 sqrtPriceAX96 = TickMath.getSqrtRatioAtTick(-100);
        uint160 sqrtPriceBX96 = TickMath.getSqrtRatioAtTick(100);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(
            sqrtPriceAX96, sqrtPriceBX96, 1e18
        );
        assertGt(liquidity, 0);
    }

    function test_LiquidityAmounts_GetLiquidityForAmount1() public pure {
        uint160 sqrtPriceAX96 = TickMath.getSqrtRatioAtTick(-100);
        uint160 sqrtPriceBX96 = TickMath.getSqrtRatioAtTick(100);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            sqrtPriceAX96, sqrtPriceBX96, 1e18
        );
        assertGt(liquidity, 0);
    }

    function test_LiquidityAmounts_GetAmountsForLiquidity_CurrentPriceInRange() public pure {
        uint160 sqrtPriceAX96 = TickMath.getSqrtRatioAtTick(-100);
        uint160 sqrtPriceBX96 = TickMath.getSqrtRatioAtTick(100);
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(0);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, 1e18
        );
        assertGt(amount0, 0);
        assertGt(amount1, 0);
    }

    function test_LiquidityAmounts_GetAmountsForLiquidity_BelowRange() public pure {
        uint160 sqrtPriceAX96 = TickMath.getSqrtRatioAtTick(100);
        uint160 sqrtPriceBX96 = TickMath.getSqrtRatioAtTick(200);
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(0);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, 1e18
        );
        // 价格低于区间，只有amount0
        assertGt(amount0, 0);
        assertEq(amount1, 0);
    }

    function test_LiquidityAmounts_GetAmountsForLiquidity_AboveRange() public pure {
        uint160 sqrtPriceAX96 = TickMath.getSqrtRatioAtTick(-200);
        uint160 sqrtPriceBX96 = TickMath.getSqrtRatioAtTick(-100);
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(0);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, 1e18
        );
        // 价格高于区间，只有amount1
        assertEq(amount0, 0);
        assertGt(amount1, 0);
    }

    function test_LiquidityAmounts_GetLiquidityForAmounts() public pure {
        uint160 sqrtPriceAX96 = TickMath.getSqrtRatioAtTick(-100);
        uint160 sqrtPriceBX96 = TickMath.getSqrtRatioAtTick(100);
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(0);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, 1e18, 1e18
        );
        assertGt(liquidity, 0);

        // 验证往返
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, liquidity
        );
        assertApproxEqAbs(amount0, 1e18, 1);
        assertApproxEqAbs(amount1, 1e18, 1);
    }

    function testFuzz_LiquidityAmounts_RoundTrip(uint128 liquidity, int24 tickLower, int24 tickUpper) public pure {
        tickLower = int24(bound(tickLower, -100000, 100000));
        tickUpper = int24(bound(tickUpper, tickLower + 60, 200000));
        // 对齐tick spacing为60
        tickLower = (tickLower / 60) * 60;
        tickUpper = (tickUpper / 60) * 60;
        if (tickUpper <= tickLower) tickUpper = tickLower + 60;

        liquidity = uint128(bound(liquidity, 1e6, type(uint64).max));

        uint160 sqrtPriceAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtRatioAtTick(tickUpper);
        int24 midTick = (tickLower + tickUpper) / 2;
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(midTick);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, liquidity
        );

        uint128 recoveredLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, amount0, amount1
        );
        // 允许1%误差（取整导致）
        assertApproxEqRel(recoveredLiquidity, liquidity, 0.01e18);
    }
}
