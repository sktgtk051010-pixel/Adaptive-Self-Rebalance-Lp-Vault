// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "../../src/libraries/UniswapMath.sol";

contract UniswapMathTest is Test {
    // 模糊测试tick→sqrtPrice→tick的往返转换：恢复的tick对应的sqrtPrice范围包含原值
    function testFuzz_TickMath_RoundTrip(int24 tick) public pure {
        tick = int24(bound(tick, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(tick);
        int24 recoveredTick = TickMath.getTickAtSqrtRatio(sqrtPrice);

        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(recoveredTick);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(recoveredTick + 1);
        assertGe(sqrtPrice, sqrtLower);
        assertLt(sqrtPrice, sqrtUpper);
    }

    // 模糊测试sqrtPrice→tick→sqrtPrice的往返转换：恢复值<=原值<下一tick对应值
    function testFuzz_TickMath_SqrtRatioRoundTrip(uint160 sqrtPrice) public pure {
        sqrtPrice = uint160(bound(sqrtPrice, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO - 1));
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPrice);
        uint160 recoveredSqrtPrice = TickMath.getSqrtRatioAtTick(tick);
        assertLe(recoveredSqrtPrice, sqrtPrice);
        uint160 nextSqrtPrice = TickMath.getSqrtRatioAtTick(tick + 1);
        assertGe(nextSqrtPrice, sqrtPrice);
    }

    // 测试MIN_TICK对应的sqrtPrice等于MIN_SQRT_RATIO，且反向转换一致
    function test_TickMath_MinTick() public pure {
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK);
        assertEq(sqrtPrice, TickMath.MIN_SQRT_RATIO);
        int24 tick = TickMath.getTickAtSqrtRatio(TickMath.MIN_SQRT_RATIO);
        assertEq(tick, TickMath.MIN_TICK);
    }

    // 测试MAX_TICK-1对应的sqrtPrice反向转换后仍为MAX_TICK-1
    function test_TickMath_MaxTick() public pure {
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK - 1);
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPrice);
        assertEq(tick, TickMath.MAX_TICK - 1);
    }

    // 测试tick=0对应的sqrtPrice为2^96（价格1:1），反向转换为0
    function test_TickMath_ZeroTick() public pure {
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(0);
        assertEq(sqrtPrice, 79228162514264337593543950336);
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPrice);
        assertEq(tick, 0);
    }
}
