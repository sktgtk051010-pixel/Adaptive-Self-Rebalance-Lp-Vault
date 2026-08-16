// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";

/**
 * @title FullUserFlowTest
 * @notice 完整用户流程集成测试
 */
contract FullUserFlowTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    /// @notice 完整流程：存款→再平衡→手续费→赎回
    function test_FullFlow_Deposit_Rebalance_Fees_Withdraw() public {
        // 1. 存款
        uint256 shares = _deposit(alice, 50 ether, 100_000e6);
        assertGt(shares, 0);

        uint256 assetsAfterDeposit = vault.totalAssets();

        // 2. 再平衡
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 1);
        assertApproxEqRel(vault.totalAssets(), assetsAfterDeposit, 0.01e18);

        // 3. 积累手续费
        v3PoolHighFee.setMockFees(10e18);
        v3PoolLowFee.setMockFees(5e18);

        skip(700);
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 2);

        // 手续费让总资产增加
        assertGt(vault.totalAssets(), assetsAfterDeposit, "fees should increase assets");
        assertGt(vault.cumulativeFeesUSDC(), 0, "cumulative fees > 0");

        // 4. 全部赎回
        uint256 wethBefore = weth.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(shares, 0, 0);
        vm.stopPrank();

        assertGt(wethOut, 0);
        assertGt(usdcOut, 0);
        assertEq(weth.balanceOf(alice), wethBefore + wethOut);
        assertEq(usdc.balanceOf(alice), usdcBefore + usdcOut);
        assertEq(vault.totalSupply(), 0);
    }

    /// @notice ERC4626标准流程：deposit→redeem
    function test_FullFlow_ERC4626_Deposit_Redeem() public {
        uint256 usdcAmt = 50_000e6;

        // ERC4626 deposit
        vm.startPrank(alice);
        uint256 shares = vault.deposit(usdcAmt, alice);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);

        // 再平衡
        vault.rebalance();

        // ERC4626 redeem
        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.startPrank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertGt(assets, 0);
        assertEq(usdc.balanceOf(alice), usdcBefore + assets);
        assertEq(vault.balanceOf(alice), 0);
    }

    /// @notice 暂停→恢复流程
    function test_FullFlow_Pause_Emergency() public {
        _deposit(alice, 20 ether, 40_000e6);

        // 暂停
        vault.setPaused(true);
        assertTrue(vault.paused());

        // 暂停时不能存款
        vm.startPrank(bob);
        vm.expectRevert();
        vault.deposit(1 ether, 2000e6, 0);
        vm.stopPrank();

        // 暂停时不能再平衡
        vm.expectRevert();
        vault.rebalance();

        // 恢复
        vault.setPaused(false);
        assertFalse(vault.paused());

        // 恢复后可以操作
        _deposit(bob, 5 ether, 10_000e6);
        vault.rebalance();
    }

    /// @notice 多次再平衡+价格变动
    function test_FullFlow_MultipleRebalances_PriceChanges() public {
        _deposit(alice, 50 ether, 100_000e6);

        // 初始再平衡
        vault.rebalance();

        // 价格上涨，中波动
        _setPrice(2400);
        skip(700);
        vault.rebalance();
        (uint256 v2_1, , ) = vault.currentWeights();

        // 价格大幅上涨，高波动
        _setPrice(3500);
        skip(700);
        vault.rebalance();
        (uint256 v2_2, , ) = vault.currentWeights();

        // 高波动时v2权重应该更大
        assertGt(v2_2, v2_1, "high vol should have more V2");

        // 价格回落
        _setPrice(2200);
        skip(700);
        vault.rebalance();

        assertEq(vault.rebalanceCount(), 4);
    }

    /// @notice 治理参数变更流程
    function test_FullFlow_GovernanceParamChange() public {
        _deposit(alice, 20 ether, 40_000e6);

        // owner直接设置参数
        governance.setTWAPWindow(600);
        assertEq(governance.getParams().twapWindow, 600);

        // oracle需要governance或owner调用
        oracle.setTWAPWindow(600);
        assertEq(oracle.twapWindow(), 600);

        // 再平衡仍正常
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 1);
    }

    /// @notice 激励领取流程
    function test_FullFlow_IncentiveClaim() public {
        _deposit(alice, 50 ether, 100_000e6);
        vault.rebalance();

        // 设置手续费让再平衡盈利
        v3PoolHighFee.setMockFees(20e18);
        v3PoolLowFee.setMockFees(10e18);

        skip(700);
        uint256 rewardBefore = incentives.pendingReward(address(this));
        vault.rebalance();
        uint256 rewardAfter = incentives.pendingReward(address(this));

        assertGt(rewardAfter, rewardBefore, "should earn reward");

        // 领取奖励
        uint256 usdcBefore = usdc.balanceOf(address(this));
        incentives.claimReward();
        uint256 usdcAfter = usdc.balanceOf(address(this));

        assertEq(usdcAfter, usdcBefore + rewardAfter - rewardBefore);
        assertEq(incentives.pendingReward(address(this)), 0);
    }
}
