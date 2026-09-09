// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "../../src/libraries/UniswapMath.sol";

contract UniswapMathTest is Test {
    function testFuzz_TickMath_RoundTrip(int24 tick) public pure {
        tick = int24(bound(tick, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(tick);
        int24 recoveredTick = TickMath.getTickAtSqrtRatio(sqrtPrice);

        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(recoveredTick);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(recoveredTick + 1);
        assertGe(sqrtPrice, sqrtLower);
        assertLt(sqrtPrice, sqrtUpper);
    }

    function testFuzz_TickMath_SqrtRatioRoundTrip(uint160 sqrtPrice) public pure {
        sqrtPrice = uint160(bound(sqrtPrice, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO - 1));
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPrice);
        uint160 recoveredSqrtPrice = TickMath.getSqrtRatioAtTick(tick);
        assertLe(recoveredSqrtPrice, sqrtPrice);
        uint160 nextSqrtPrice = TickMath.getSqrtRatioAtTick(tick + 1);
        assertGe(nextSqrtPrice, sqrtPrice);
    }

    function test_TickMath_MinTick() public pure {
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK);
        assertEq(sqrtPrice, TickMath.MIN_SQRT_RATIO);
        int24 tick = TickMath.getTickAtSqrtRatio(TickMath.MIN_SQRT_RATIO);
        assertEq(tick, TickMath.MIN_TICK);
    }

    function test_TickMath_MaxTick() public pure {
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK - 1);
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPrice);
        assertEq(tick, TickMath.MAX_TICK - 1);
    }

    function test_TickMath_ZeroTick() public pure {
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(0);
        assertEq(sqrtPrice, 79228162514264337593543950336);
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPrice);
        assertEq(tick, 0);
    }
}
