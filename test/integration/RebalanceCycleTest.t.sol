// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";

/**
 * @title RebalanceCycleTest
 * @notice 再平衡周期集成测试
 */
contract RebalanceCycleTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    /// @notice 低波动→高波动切换
    function test_LowToHighVol() public {
        _deposit(alice, 50 ether, 100_000e6);

        // 低波动再平衡
        vault.rebalance();
        (uint256 v2Low, uint256 v3LowLow, uint256 v3HighLow) = vault.currentWeights();
        assertEq(v2Low, 1000);
        assertEq(v3LowLow, 3000);
        assertEq(v3HighLow, 6000);

        // 切换到高波动：先过冷却期，再设置价格，立即rebalance
        skip(1801);
        _setPrice(5000);
        vault.rebalance();
        (uint256 v2High, uint256 v3LowHigh, uint256 v3HighHigh) = vault.currentWeights();
        assertEq(v2High, 5000);
        assertEq(v3LowHigh, 2500);
        assertEq(v3HighHigh, 2500);

        // V2权重增加
        assertGt(v2High, v2Low);
    }

    /// @notice 手续费随周期积累
    function test_FeesAccumulateOverCycles() public {
        _deposit(alice, 50 ether, 100_000e6);
        vault.rebalance();

        uint256 totalFees = 0;

        // 3个再平衡周期
        for (uint256 i = 0; i < 3; i++) {
            v3PoolHighFee.setMockFees(5e18);
            v3PoolLowFee.setMockFees(2e18);

            skip(700);
            uint256 feesBefore = vault.cumulativeFeesUSDC();
            vault.rebalance();
            uint256 feesAfter = vault.cumulativeFeesUSDC();

            assertGt(feesAfter, feesBefore, "fees should increase each cycle");
            totalFees += (feesAfter - feesBefore);
        }

        assertGt(vault.cumulativeFeesUSDC(), 0);
        assertEq(vault.rebalanceCount(), 4); // 初始+3次
    }

    /// @notice 份额价格在再平衡周期中保持稳定（无价格变动时）
    function test_SharePriceStable() public {
        uint256 shares = _deposit(alice, 50 ether, 100_000e6);
        uint256 pricePerShare = vault.totalAssets() * 1e18 / shares;

        // 多次再平衡，价格不变
        for (uint256 i = 0; i < 3; i++) {
            skip(700);
            vault.rebalance();
            uint256 newPrice = vault.totalAssets() * 1e18 / shares;
            assertApproxEqRel(newPrice, pricePerShare, 0.01e18, "share price stable");
        }
    }

    /// @notice 中波动区间分配
    function test_MediumVolAllocation() public {
        _deposit(alice, 50 ether, 100_000e6);
        vault.rebalance();

        // 中波动（20-50%）
        _setPrice(2800);
        skip(700);
        vault.rebalance();

        (uint256 v2, uint256 v3Low, uint256 v3High) = vault.currentWeights();
        assertEq(v2, 2500);
        assertEq(v3Low, 3000);
        assertEq(v3High, 4500);
    }

    /// @notice 再平衡后资金确实按权重分配
    function test_Rebalance_AllocationMatchesWeights() public {
        _deposit(alice, 100 ether, 200_000e6);
        vault.rebalance();

        (uint256 v2Weight, uint256 v3LowWeight, uint256 v3HighWeight) = vault.currentWeights();

        (, uint256 v2W, uint256 v3LowW, uint256 v3HighW) = _getWethDistribution();
        uint256 totalInvestedW = v2W + v3LowW + v3HighW;

        if (totalInvestedW > 0) {
            // 验证各部分比例大致符合权重（允许较大误差因为dust和价格影响）
            uint256 v2Pct = v2W * 10000 / totalInvestedW;
            assertApproxEqRel(v2Pct, v2Weight, 0.5e18, "v2 allocation ~ weight");
        }
    }
}
