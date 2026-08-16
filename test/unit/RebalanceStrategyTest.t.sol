// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";
import {AdaptiveRebalanceStrategy} from "../../src/strategies/AdaptiveRebalanceStrategy.sol";
import {IRebalanceStrategy} from "../../src/interfaces/ICoreInterfaces.sol";
import {TickMath} from "../../src/libraries/UniswapMath.sol";

/**
 * @title RebalanceStrategyTest
 * @notice 再平衡策略专项测试
 */
contract RebalanceStrategyTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // ============ calculateAllocation ============

    /// @notice 低波动率(<=20%)分配
    function test_CalculateAllocation_LowVolatility() public {
        (IRebalanceStrategy.AllocationWeights memory alloc,
         IRebalanceStrategy.V3RangeWeights memory ranges) =
            AdaptiveRebalanceStrategy(address(strategy)).calculateAllocation(0, 0, 1000); // 10%

        assertEq(alloc.v2Weight, 1000, "v2=10%");
        assertEq(alloc.v3LowFeeWeight, 3000, "v3Low=30%");
        assertEq(alloc.v3HighFeeWeight, 6000, "v3High=60%");
        assertEq(ranges.tightWeight, 6000, "tight=60%");
        assertEq(ranges.mediumWeight, 3000, "medium=30%");
        assertEq(ranges.wideWeight, 1000, "wide=10%");
    }

    /// @notice 中波动率(20-50%)分配
    function test_CalculateAllocation_MediumVolatility() public {
        (IRebalanceStrategy.AllocationWeights memory alloc,
         IRebalanceStrategy.V3RangeWeights memory ranges) =
            AdaptiveRebalanceStrategy(address(strategy)).calculateAllocation(0, 0, 3000); // 30%

        assertEq(alloc.v2Weight, 2500, "v2=25%");
        assertEq(alloc.v3LowFeeWeight, 3000, "v3Low=30%");
        assertEq(alloc.v3HighFeeWeight, 4500, "v3High=45%");
        assertEq(ranges.tightWeight, 3000, "tight=30%");
        assertEq(ranges.mediumWeight, 5000, "medium=50%");
        assertEq(ranges.wideWeight, 2000, "wide=20%");
    }

    /// @notice 高波动率(>50%)分配
    function test_CalculateAllocation_HighVolatility() public {
        (IRebalanceStrategy.AllocationWeights memory alloc,
         IRebalanceStrategy.V3RangeWeights memory ranges) =
            AdaptiveRebalanceStrategy(address(strategy)).calculateAllocation(0, 0, 6000); // 60%

        assertEq(alloc.v2Weight, 5000, "v2=50%");
        assertEq(alloc.v3LowFeeWeight, 2500, "v3Low=25%");
        assertEq(alloc.v3HighFeeWeight, 2500, "v3High=25%");
        assertEq(ranges.tightWeight, 1000, "tight=10%");
        assertEq(ranges.mediumWeight, 3000, "medium=30%");
        assertEq(ranges.wideWeight, 6000, "wide=60%");
    }

    /// @notice 三档权重之和都是10000
    function test_CalculateAllocation_WeightsSumTo10000() public {
        uint256[3] memory vols = [uint256(1000), uint256(3000), uint256(6000)];
        for (uint256 i = 0; i < 3; i++) {
            (IRebalanceStrategy.AllocationWeights memory alloc, ) =
                AdaptiveRebalanceStrategy(address(strategy)).calculateAllocation(0, 0, vols[i]);
            assertEq(alloc.v2Weight + alloc.v3LowFeeWeight + alloc.v3HighFeeWeight, 10000);
        }
    }

    /// @notice range权重之和也是10000
    function test_CalculateAllocation_RangeWeightsSum() public {
        (, IRebalanceStrategy.V3RangeWeights memory ranges) =
            AdaptiveRebalanceStrategy(address(strategy)).calculateAllocation(0, 0, 1000);
        assertEq(ranges.tightWeight + ranges.mediumWeight + ranges.wideWeight, 10000);
    }

    // ============ getRangeTicks ============

    /// @notice 窄区间±198 tick
    function test_GetRangeTicks_Tight() public {
        int24 currentTick = -200000;
        (int24 tLower, int24 tUpper, , , , ) =
            AdaptiveRebalanceStrategy(address(strategy)).getRangeTicks(currentTick);
        // 约±198 tick，对齐到60
        assertApproxEqAbs(int256(tLower), int256(currentTick - 198), 60, "tight lower");
        assertApproxEqAbs(int256(tUpper), int256(currentTick + 198), 60, "tight upper");
        assertLt(tLower, tUpper);
    }

    /// @notice 中区间±953 tick
    function test_GetRangeTicks_Medium() public {
        int24 currentTick = -200000;
        (, , int24 mLower, int24 mUpper, , ) =
            AdaptiveRebalanceStrategy(address(strategy)).getRangeTicks(currentTick);
        assertApproxEqAbs(int256(mLower), int256(currentTick - 953), 60, "medium lower");
        assertApproxEqAbs(int256(mUpper), int256(currentTick + 953), 60, "medium upper");
    }

    /// @notice 宽区间±2624 tick
    function test_GetRangeTicks_Wide() public {
        int24 currentTick = -200000;
        (, , , , int24 wLower, int24 wUpper) =
            AdaptiveRebalanceStrategy(address(strategy)).getRangeTicks(currentTick);
        assertApproxEqAbs(int256(wLower), int256(currentTick - 2624), 60, "wide lower");
        assertApproxEqAbs(int256(wUpper), int256(currentTick + 2624), 60, "wide upper");
    }

    /// @notice 边界clamp
    function test_GetRangeTicks_ClampsAtMinMax() public {
        int24 nearMin = TickMath.MIN_TICK + 100;
        (int24 tLower, , , , , ) =
            AdaptiveRebalanceStrategy(address(strategy)).getRangeTicks(nearMin);
        assertGe(tLower, TickMath.MIN_TICK, "should clamp at MIN_TICK");
    }

    /// @notice tick对齐到tickSpacing
    function test_GetRangeTicks_Aligned() public {
        int24 currentTick = -200000;
        (int24 tLower, int24 tUpper, int24 mLower, int24 mUpper, int24 wLower, int24 wUpper) =
            AdaptiveRebalanceStrategy(address(strategy)).getRangeTicks(currentTick);
        // 所有tick应对齐到60（TICK_SPACING_HIGH）
        assertEq(int256(tLower % 60), 0);
        assertEq(int256(tUpper % 60), 0);
        assertEq(int256(mLower % 60), 0);
        assertEq(int256(mUpper % 60), 0);
        assertEq(int256(wLower % 60), 0);
        assertEq(int256(wUpper % 60), 0);
    }

    // ============ needsRebalance ============

    /// @notice 偏差>=阈值返回true
    function test_NeedsRebalance_AboveThreshold() public view {
        assertTrue(strategy.needsRebalance(600)); // 默认阈值500
    }

    /// @notice 偏差<阈值返回false
    function test_NeedsRebalance_BelowThreshold() public view {
        assertFalse(strategy.needsRebalance(400));
    }

    /// @notice 偏差==阈值返回true
    function test_NeedsRebalance_AtThreshold() public view {
        assertTrue(strategy.needsRebalance(500));
    }

    // ============ estimateVolatility / calculateDeviation ============

    /// @notice 相同价格波动率为0
    function test_EstimateVolatility_SamePrice() public {
        uint160 price = 3000000000000000000000000000;
        uint256 vol = AdaptiveRebalanceStrategy(address(strategy)).estimateVolatility(price, price);
        assertEq(vol, 0);
    }

    /// @notice 不同价格波动率>0
    function test_EstimateVolatility_DifferentPrice() public {
        uint160 price1 = 3000000000000000000000000000;
        uint160 price2 = 4000000000000000000000000000;
        uint256 vol = AdaptiveRebalanceStrategy(address(strategy)).estimateVolatility(price1, price2);
        assertGt(vol, 0);
    }

    /// @notice target为0时波动率为0
    function test_EstimateVolatility_ZeroTarget() public {
        uint256 vol = AdaptiveRebalanceStrategy(address(strategy)).estimateVolatility(1000, 0);
        assertEq(vol, 0);
    }

    /// @notice calculateDeviation与estimateVolatility结果一致
    function test_CalculateDeviation_MatchesVolatility() public {
        uint160 p1 = 3000000000000000000000000000;
        uint160 p2 = 4000000000000000000000000000;
        uint256 dev = AdaptiveRebalanceStrategy(address(strategy)).calculateDeviation(p1, p2);
        uint256 vol = AdaptiveRebalanceStrategy(address(strategy)).estimateVolatility(p1, p2);
        assertEq(dev, vol, "deviation should equal volatility");
    }

    // ============ setRebalanceThreshold ============

    /// @notice 设置合理阈值
    function test_SetRebalanceThreshold_Valid() public {
        strategy.setRebalanceThreshold(1000);
        assertEq(strategy.rebalanceThresholdBps(), 1000);
    }

    /// @notice 阈值过小revert
    function test_Revert_SetRebalanceThreshold_TooSmall() public {
        vm.expectRevert(bytes("Strategy: invalid threshold"));
        strategy.setRebalanceThreshold(50); // < 100
    }

    /// @notice 阈值过大revert
    function test_Revert_SetRebalanceThreshold_TooLarge() public {
        vm.expectRevert(bytes("Strategy: invalid threshold"));
        strategy.setRebalanceThreshold(6000); // > 5000
    }

    /// @notice 非治理设置阈值revert
    function test_Revert_SetRebalanceThreshold_NotAuthorized() public {
        vm.startPrank(alice);
        vm.expectRevert(bytes("Strategy: not authorized"));
        strategy.setRebalanceThreshold(1000);
        vm.stopPrank();
    }
}
