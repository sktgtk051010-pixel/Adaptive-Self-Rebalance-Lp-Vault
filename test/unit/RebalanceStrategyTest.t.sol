// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";
import {AdaptiveRebalanceStrategy} from "../../src/strategies/AdaptiveRebalanceStrategy.sol";
import {IRebalanceStrategy} from "../../src/interfaces/ICoreInterfaces.sol";
import {TickMath} from "../../src/libraries/UniswapMath.sol";

contract RebalanceStrategyTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    function test_CalculateAllocation_LowVolatility() public view {
        (IRebalanceStrategy.AllocationWeights memory alloc,
         IRebalanceStrategy.V3RangeWeights memory ranges) =
            AdaptiveRebalanceStrategy(address(strategy)).calculateAllocation(0, 0, 1000);

        assertEq(alloc.v2Weight, 1000, "v2=10%");
        assertEq(alloc.v3LowFeeWeight, 3000, "v3Low=30%");
        assertEq(alloc.v3HighFeeWeight, 6000, "v3High=60%");
        assertEq(ranges.tightWeight, 6000, "tight=60%");
        assertEq(ranges.mediumWeight, 3000, "medium=30%");
        assertEq(ranges.wideWeight, 1000, "wide=10%");
        assertEq(alloc.v2Weight + alloc.v3LowFeeWeight + alloc.v3HighFeeWeight, 10000);
        assertEq(ranges.tightWeight + ranges.mediumWeight + ranges.wideWeight, 10000);
    }

    function test_CalculateAllocation_MediumVolatility() public view {
        (IRebalanceStrategy.AllocationWeights memory alloc,
         IRebalanceStrategy.V3RangeWeights memory ranges) =
            AdaptiveRebalanceStrategy(address(strategy)).calculateAllocation(0, 0, 3000);

        assertEq(alloc.v2Weight, 2500, "v2=25%");
        assertEq(alloc.v3LowFeeWeight, 3000, "v3Low=30%");
        assertEq(alloc.v3HighFeeWeight, 4500, "v3High=45%");
        assertEq(ranges.tightWeight, 3000, "tight=30%");
        assertEq(ranges.mediumWeight, 5000, "medium=50%");
        assertEq(ranges.wideWeight, 2000, "wide=20%");
        assertEq(alloc.v2Weight + alloc.v3LowFeeWeight + alloc.v3HighFeeWeight, 10000);
        assertEq(ranges.tightWeight + ranges.mediumWeight + ranges.wideWeight, 10000);
    }

    function test_CalculateAllocation_HighVolatility() public view {
        (IRebalanceStrategy.AllocationWeights memory alloc,
         IRebalanceStrategy.V3RangeWeights memory ranges) =
            AdaptiveRebalanceStrategy(address(strategy)).calculateAllocation(0, 0, 6000);

        assertEq(alloc.v2Weight, 5000, "v2=50%");
        assertEq(alloc.v3LowFeeWeight, 2500, "v3Low=25%");
        assertEq(alloc.v3HighFeeWeight, 2500, "v3High=25%");
        assertEq(ranges.tightWeight, 1000, "tight=10%");
        assertEq(ranges.mediumWeight, 3000, "medium=30%");
        assertEq(ranges.wideWeight, 6000, "wide=60%");
        assertEq(alloc.v2Weight + alloc.v3LowFeeWeight + alloc.v3HighFeeWeight, 10000);
        assertEq(ranges.tightWeight + ranges.mediumWeight + ranges.wideWeight, 10000);
    }

    function test_GetRangeTicks_Tight() public view {
        int24 currentTick = -200000;
        (int24 tLower, int24 tUpper, , , , ) =
            AdaptiveRebalanceStrategy(address(strategy)).getRangeTicks(currentTick);
        assertApproxEqAbs(int256(tLower), int256(currentTick - 198), 60, "tight lower");
        assertApproxEqAbs(int256(tUpper), int256(currentTick + 198), 60, "tight upper");
        assertLt(tLower, tUpper);
    }

    function test_GetRangeTicks_Medium() public view {
        int24 currentTick = -200000;
        (, , int24 mLower, int24 mUpper, , ) =
            AdaptiveRebalanceStrategy(address(strategy)).getRangeTicks(currentTick);
        assertApproxEqAbs(int256(mLower), int256(currentTick - 953), 60, "medium lower");
        assertApproxEqAbs(int256(mUpper), int256(currentTick + 953), 60, "medium upper");
    }

    function test_GetRangeTicks_Wide() public view {
        int24 currentTick = -200000;
        (, , , , int24 wLower, int24 wUpper) =
            AdaptiveRebalanceStrategy(address(strategy)).getRangeTicks(currentTick);
        assertApproxEqAbs(int256(wLower), int256(currentTick - 2624), 60, "wide lower");
        assertApproxEqAbs(int256(wUpper), int256(currentTick + 2624), 60, "wide upper");
    }

    function test_GetRangeTicks_ClampsAtMinMax() public view {
        int24 nearMin = TickMath.MIN_TICK + 100;
        (int24 tLower, , int24 mLower, , int24 wLower, ) =
            strategy.getRangeTicks(nearMin);
        assertGe(tLower, TickMath.MIN_TICK, "tightLower should clamp at MIN_TICK");
        assertGe(mLower, TickMath.MIN_TICK, "mediumLower should clamp at MIN_TICK");
        assertGe(wLower, TickMath.MIN_TICK, "wideLower should clamp at MIN_TICK");

        int24 nearMax = TickMath.MAX_TICK - 100;
        (, int24 tUpper, , int24 mUpper, , int24 wUpper) =
            strategy.getRangeTicks(nearMax);
        assertGe(tUpper, TickMath.MAX_TICK, "tightUpper should clamp at MAX_TICK");
        assertGe(mUpper, TickMath.MAX_TICK, "mediumUpper should clamp at MAX_TICK");
        assertGe(wUpper, TickMath.MAX_TICK, "wideUpper should clamp at MAX_TICK");
    }

    function test_GetRangeTicks_Aligned() public view {
        int24 currentTick = -200000;
        (int24 tLower, int24 tUpper, int24 mLower, int24 mUpper, int24 wLower, int24 wUpper) =
            AdaptiveRebalanceStrategy(address(strategy)).getRangeTicks(currentTick);
        assertEq(int256(tLower % 60), 0);
        assertEq(int256(tUpper % 60), 0);
        assertEq(int256(mLower % 60), 0);
        assertEq(int256(mUpper % 60), 0);
        assertEq(int256(wLower % 60), 0);
        assertEq(int256(wUpper % 60), 0);
    }

    function test_NeedsRebalance_AboveThreshold() public view {
        assertTrue(strategy.needsRebalance(600));
    }

    function test_NeedsRebalance_BelowThreshold() public view {
        assertFalse(strategy.needsRebalance(400));
    }

    function test_NeedsRebalance_AtThreshold() public view {
        assertTrue(strategy.needsRebalance(500));
    }

    function test_EstimateVolatility_SamePrice() public view {
        uint160 price = 3000000000000000000000000000;
        uint256 vol = AdaptiveRebalanceStrategy(address(strategy)).estimateVolatility(price, price);
        assertEq(vol, 0);
    }

    function test_EstimateVolatility_DifferentPrice() public view {
        uint160 price1 = 3000000000000000000000000000;
        uint160 price2 = 4000000000000000000000000000;
        uint256 vol = AdaptiveRebalanceStrategy(address(strategy)).estimateVolatility(price1, price2);
        assertGt(vol, 0);
    }

    function test_EstimateVolatility_ZeroTarget() public view {
        uint256 vol = AdaptiveRebalanceStrategy(address(strategy)).estimateVolatility(1000, 0);
        assertEq(vol, 0);
    }

    function test_CalculateDeviation_MatchesVolatility() public view {
        uint160 p1 = 3000000000000000000000000000;
        uint160 p2 = 4000000000000000000000000000;
        uint256 dev = AdaptiveRebalanceStrategy(address(strategy)).calculateDeviation(p1, p2);
        uint256 vol = AdaptiveRebalanceStrategy(address(strategy)).estimateVolatility(p1, p2);
        assertEq(dev, vol, "deviation should equal volatility");
    }

    function test_SetRebalanceThreshold_Valid() public {
        strategy.setRebalanceThreshold(1000);
        assertEq(strategy.rebalanceThresholdBps(), 1000);
    }

    function test_Revert_SetRebalanceThreshold_TooSmall() public {
        vm.expectRevert(bytes("Strategy: invalid threshold"));
        strategy.setRebalanceThreshold(50);
    }

    function test_Revert_SetRebalanceThreshold_TooLarge() public {
        vm.expectRevert(bytes("Strategy: invalid threshold"));
        strategy.setRebalanceThreshold(6000);
    }

    function test_Revert_SetRebalanceThreshold_NotAuthorized() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Strategy: not authorized"));
        strategy.setRebalanceThreshold(1000);
    }
}
