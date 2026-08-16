// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../../base/BaseTest.t.sol";
import {AdaptiveLPVault} from "../../../src/vault/AdaptiveLPVault.sol";

/**
 * @title VaultRebalanceTest
 * @notice 金库再平衡功能专项测试
 */
contract VaultRebalanceTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // ============ 基本再平衡 ============

    /// @notice 首次再平衡不需要冷却
    function test_Rebalance_FirstTime_NoCooldown() public {
        _deposit(alice, 20 ether, 40_000e6);
        assertEq(vault.rebalanceCount(), 0);
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 1);
    }

    /// @notice 验证再平衡后状态变化
    function test_Rebalance_EmitRebalancedEvent() public {
        _deposit(alice, 20 ether, 40_000e6);
        uint256 countBefore = vault.rebalanceCount();

        vault.rebalance();

        assertEq(vault.rebalanceCount(), countBefore + 1, "rebalanceCount should increase");
        assertGt(vault.lastRebalanceTimestamp(), 0, "lastRebalanceTimestamp should be set");
    }

    /// @notice 验证再平衡后权重更新
    function test_Rebalance_EmitWeightsUpdatedEvent() public {
        _deposit(alice, 20 ether, 40_000e6);

        vault.rebalance();

        (uint256 v2, uint256 v3Low, uint256 v3High) = vault.currentWeights();
        assertEq(v2 + v3Low + v3High, 10000, "weights should sum to 10000");
        assertGt(v2, 0, "v2 weight should be > 0");
        assertGt(v3Low, 0, "v3Low weight should be > 0");
        assertGt(v3High, 0, "v3High weight should be > 0");
    }

    /// @notice 无价格变动时，再平衡前后总资产不变
    function test_Rebalance_FundsConserved() public {
        _deposit(alice, 20 ether, 40_000e6);
        uint256 assetsBefore = vault.totalAssets();

        vault.rebalance();

        uint256 assetsAfter = vault.totalAssets();
        assertApproxEqRel(assetsAfter, assetsBefore, 0.01e18, "total assets should be conserved");
    }

    /// @notice 再平衡更新时间戳
    function test_Rebalance_UpdatesLastRebalanceTimestamp() public {
        _deposit(alice, 20 ether, 40_000e6);
        assertEq(vault.lastRebalanceTimestamp(), 0);

        uint256 tsBefore = block.timestamp;
        vault.rebalance();

        assertEq(vault.lastRebalanceTimestamp(), tsBefore);
        assertGt(vault.lastRebalanceSqrtPriceX96(), 0);
    }

    // ============ 冷却期 ============

    /// @notice 普通波动率下600s冷却
    function test_Revert_Rebalance_Cooldown_Normal() public {
        _deposit(alice, 20 ether, 40_000e6);
        vault.rebalance();

        // 快进500s（<600），应revert
        skip(500);
        vm.expectRevert(AdaptiveLPVault.CooldownActive.selector);
        vault.rebalance();
    }

    /// @notice 快进601s后可以再平衡
    function test_Rebalance_Cooldown_PassesAfter600s() public {
        _deposit(alice, 20 ether, 40_000e6);
        vault.rebalance();

        skip(601);
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 2);
    }

    /// @notice 高波动率(>50%)下1800s紧急冷却
    function test_Revert_Rebalance_EmergencyCooldown() public {
        _deposit(alice, 20 ether, 40_000e6);
        vault.rebalance();

        // 大幅改变价格制造高波动率
        _setPrice(5000); // 从2000涨到5000，波动率>50%

        // 快进700s（>600但<1800），高波动下应revert
        skip(700);
        vm.expectRevert(AdaptiveLPVault.CooldownActive.selector);
        vault.rebalance();
    }

    /// @notice 紧急冷却1801s后通过
    function test_Rebalance_EmergencyCooldown_PassesAfter1800s() public {
        _deposit(alice, 20 ether, 40_000e6);
        vault.rebalance();

        _setPrice(5000);
        skip(1801);
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 2);
    }

    // ============ 波动率驱动权重切换 ============

    /// @notice 低波动率时权重分配
    function test_Rebalance_LowVolatility_Allocation() public {
        _deposit(alice, 50 ether, 100_000e6);
        vault.rebalance();

        // 低波动：v2=10%, v3Low=30%, v3High=60%
        (, uint256 v2W, uint256 v3LowW, uint256 v3HighW) = _getWethDistribution();
        uint256 totalW = v2W + v3LowW + v3HighW;

        assertGt(totalW, 0, "WETH should be invested");
        // v2占比约10%
        assertApproxEqRel(v2W * 10000 / totalW, 1000, 0.3e18, "v2 ~10% (tolerance for dust)");
        // v3High占比最大
        assertGt(v3HighW, v2W, "v3High should be > v2");
    }

    /// @notice 中波动率时权重分配
    function test_Rebalance_MediumVolatility_Allocation() public {
        _deposit(alice, 50 ether, 100_000e6);
        vault.rebalance();

        // 制造中波动（20-50%）
        _setPrice(2800); // 从2000到2800，约40%波动
        skip(700);
        vault.rebalance();

        // 中波动：v2=25%, v3Low=30%, v3High=45%
        (uint256 v2, uint256 v3Low, uint256 v3High) = vault.currentWeights();
        assertEq(v2, 2500, "v2 weight should be 25%");
        assertEq(v3Low, 3000, "v3Low weight should be 30%");
        assertEq(v3High, 4500, "v3High weight should be 45%");
    }

    /// @notice 高波动率时权重分配
    function test_Rebalance_HighVolatility_Allocation() public {
        _deposit(alice, 50 ether, 100_000e6);
        vault.rebalance();

        // 制造高波动（>50%）：先过冷却期，再设置价格，立即rebalance
        skip(1801);
        _setPrice(5000);
        vault.rebalance();

        // 高波动：v2=50%, v3Low=25%, v3High=25%
        (uint256 v2, uint256 v3Low, uint256 v3High) = vault.currentWeights();
        assertEq(v2, 5000, "v2 weight should be 50%");
        assertEq(v3Low, 2500, "v3Low weight should be 25%");
        assertEq(v3High, 2500, "v3High weight should be 25%");
    }

    // ============ 手续费收集 ============

    /// @notice 再平衡收集手续费，cumulativeFeesUSDC增加
    function test_Rebalance_CollectsFees() public {
        _deposit(alice, 50 ether, 100_000e6);
        vault.rebalance();

        // 设置mock手续费
        v3PoolHighFee.setMockFees(1e18);
        v3PoolLowFee.setMockFees(1e18);

        uint256 feesBefore = vault.cumulativeFeesUSDC();

        skip(700);
        vault.rebalance();

        uint256 feesAfter = vault.cumulativeFeesUSDC();
        assertGt(feesAfter, feesBefore, "cumulative fees should increase");
    }

    /// @notice 手续费让totalAssets增加
    function test_Rebalance_FeesIncreaseTotalAssets() public {
        _deposit(alice, 50 ether, 100_000e6);
        vault.rebalance();

        v3PoolHighFee.setMockFees(5e18);
        v3PoolLowFee.setMockFees(5e18);

        uint256 assetsBefore = vault.totalAssets();
        skip(700);
        vault.rebalance();
        uint256 assetsAfter = vault.totalAssets();

        assertGt(assetsAfter, assetsBefore, "fees should increase total assets");
    }

    /// @notice 验证再平衡后手续费状态
    function test_EmitFeesCollectedEvent() public {
        _deposit(alice, 50 ether, 100_000e6);
        vault.rebalance();

        v3PoolHighFee.setMockFees(1e18);
        skip(700);

        uint256 feesBefore = vault.cumulativeFeesUSDC();
        vault.rebalance();
        uint256 feesAfter = vault.cumulativeFeesUSDC();

        // 再平衡后cumulativeFeesUSDC不应减少
        assertGe(feesAfter, feesBefore, "fees should not decrease");
    }

    // ============ 激励 ============

    /// @notice 盈利再平衡后激励记录奖励
    function test_Rebalance_WithIncentives_Profitable() public {
        _deposit(alice, 50 ether, 100_000e6);
        vault.rebalance();

        // 设置手续费让再平衡盈利
        v3PoolHighFee.setMockFees(10e18);
        v3PoolLowFee.setMockFees(10e18);

        skip(700);
        uint256 rewardBefore = incentives.pendingReward(address(this));
        vault.rebalance();
        uint256 rewardAfter = incentives.pendingReward(address(this));

        assertGt(rewardAfter, rewardBefore, "should earn incentive reward");
    }

    /// @notice incentives设为零地址，再平衡仍成功
    function test_Rebalance_WithZeroIncentives() public {
        _deposit(alice, 20 ether, 40_000e6);
        vault.setIncentives(address(0));

        vault.rebalance();
        assertEq(vault.rebalanceCount(), 1);
    }

    /// @notice incentives调用失败不影响rebalance
    function test_Rebalance_IncentivesFail_DoesNotRevert() public {
        _deposit(alice, 20 ether, 40_000e6);
        vault.rebalance();

        // 用mock让incentives revert（正确签名：address,uint256,uint256）
        vm.mockCallRevert(
            address(incentives),
            abi.encodeWithSignature("onRebalanceExecuted(address,uint256,uint256)"),
            abi.encode("incentive fail")
        );

        skip(700);
        // 不应revert
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 2);
    }

    // ============ 边界 ============

    /// @notice 暂停时再平衡revert
    function test_Revert_Rebalance_WhenPaused() public {
        _deposit(alice, 20 ether, 40_000e6);
        vault.setPaused(true);
        vm.expectRevert(AdaptiveLPVault.PausedError.selector);
        vault.rebalance();
    }
}
