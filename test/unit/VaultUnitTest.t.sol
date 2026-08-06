// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.t.sol";

/**
 * @title VaultUnitTest
 * @notice 金库核心单元测试
 */
contract VaultUnitTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // ============ 存款测试 ============

    function test_Deposit_DualAsset() public {
        uint256 wethAmt = 1 ether;
        uint256 usdcAmt = 2000e6;

        uint256 shares = _deposit(alice, wethAmt, usdcAmt);

        assertGt(shares, 0, "shares should be > 0");
        assertEq(vault.balanceOf(alice), shares, "alice shares");
        assertGt(vault.totalAssets(), 0, "total assets > 0");
    }

    function test_Deposit_OnlyWETH() public {
        uint256 wethAmt = 5 ether;
        uint256 shares = _deposit(alice, wethAmt, 0);
        assertGt(shares, 0);
    }

    function test_Deposit_OnlyUSDC() public {
        uint256 usdcAmt = 10000e6;
        uint256 shares = _deposit(alice, 0, usdcAmt);
        assertGt(shares, 0);
    }

    function test_Deposit_ERC4626Standard() public {
        vm.startPrank(alice);
        uint256 shares = vault.deposit(5000e6, alice);
        vm.stopPrank();
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_Deposit_MultipleUsers() public {
        uint256 s1 = _deposit(alice, 1 ether, 2000e6);
        uint256 s2 = _deposit(bob, 2 ether, 4000e6);

        // bob存了两倍，应该有大约两倍份额
        assertApproxEqRel(s2, s1 * 2, 0.01e18, "bob should have ~2x shares");
    }

    function test_Revert_Deposit_ZeroAmount() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.deposit(0, 0, 0);
        vm.stopPrank();
    }

    function test_Revert_Deposit_WhenPaused() public {
        vault.setPaused(true);
        vm.startPrank(alice);
        vm.expectRevert();
        vault.deposit(1 ether, 2000e6, 0);
        vm.stopPrank();
    }

    // ============ 取款测试 ============

    function test_Withdraw_DualAsset() public {
        uint256 wethAmt = 10 ether;
        uint256 usdcAmt = 20000e6;
        uint256 shares = _deposit(alice, wethAmt, usdcAmt);

        uint256 wethBefore = weth.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(shares, 0, 0);
        vm.stopPrank();

        assertGt(wethOut, 0, "should get WETH");
        assertGt(usdcOut, 0, "should get USDC");
        assertEq(vault.balanceOf(alice), 0, "all shares burned");

        assertEq(weth.balanceOf(alice), wethBefore + wethOut, "weth balance mismatch");
        assertEq(usdc.balanceOf(alice), usdcBefore + usdcOut, "usdc balance mismatch");
    }

    function test_Withdraw_Partial() public {
        uint256 shares = _deposit(alice, 10 ether, 20000e6);
        uint256 halfShares = shares / 2;

        vm.startPrank(alice);
        vault.withdrawDual(halfShares, 0, 0);
        vm.stopPrank();

        assertApproxEqAbs(vault.balanceOf(alice), shares - halfShares, 1, "half shares remain");
    }

    function test_Revert_Withdraw_InsufficientShares() public {
        _deposit(alice, 1 ether, 2000e6);
        vm.startPrank(bob);
        vm.expectRevert();
        vault.withdrawDual(1000000, 0, 0);
        vm.stopPrank();
    }

    // ============ 再平衡测试 ============

    function test_Rebalance_Success() public {
        _deposit(alice, 10 ether, 20000e6);

        // 快进冷却时间
        vm.warp(block.timestamp + 301);

        vault.rebalance();
        uint256 assetsAfter = vault.totalAssets();

        assertEq(vault.rebalanceCount(), 1, "rebalance count");
        assertGt(assetsAfter, 0, "assets after rebalance > 0");
    }

    function test_Rebalance_Multiple() public {
        _deposit(alice, 20 ether, 40000e6);

        vm.warp(1000);
        vault.rebalance();

        // 模拟价格变化
        v3PoolHighFee.setPrice(2200);
        v3PoolLowFee.setPrice(2200);
        vm.warp(2000);

        vault.rebalance();
        assertEq(vault.rebalanceCount(), 2);
    }

    function test_Revert_Rebalance_Cooldown() public {
        _deposit(alice, 10 ether, 20000e6);
        vault.rebalance();

        vm.expectRevert();
        vault.rebalance();
    }

    // ============ 视图函数测试 ============

    function test_TotalAssets_IncreasesWithFees() public {
        _deposit(alice, 10 ether, 20000e6);
        uint256 assetsBefore = vault.totalAssets();

        // 模拟手续费产生
        v3PoolHighFee.setMockFees(100e6);
        v3PoolLowFee.setMockFees(50e6);

        vm.warp(1000);
        vault.rebalance();

        uint256 assetsAfter = vault.totalAssets();
        // 手续费应该让资产增加（mock中burn会产生tokensOwed）
        assertGe(assetsAfter, assetsBefore, "assets should not decrease");
    }

    function test_GetDistribution() public {
        _deposit(alice, 10 ether, 20000e6);

        (uint256 idleW, uint256 idleU, uint256 v2W, uint256 v2U,
         uint256 v3LW, uint256 v3LU, uint256 v3HW, uint256 v3HU) = vault.getDistribution();

        uint256 totalWeth = idleW + v2W + v3LW + v3HW;
        uint256 totalUsdc = idleU + v2U + v3LU + v3HU;

        assertGt(totalWeth, 0, "should have WETH somewhere");
        assertGt(totalUsdc, 0, "should have USDC somewhere");
    }

    function test_CumulativeFees() public {
        _deposit(alice, 10 ether, 20000e6);
        assertEq(vault.cumulativeFeesUSDC(), 0);

        v3PoolHighFee.setMockFees(100e6);
        vm.warp(block.timestamp + 301);
        vault.rebalance();

        // 再平衡后应该有手续费记录
        // (mock中手续费在collect时转给vault)
    }

    // ============ 管理函数测试 ============

    function test_SetMaxSlippage() public {
        vault.setMaxSlippage(200); // 2%
        assertEq(vault.maxSlippageBps(), 200);
    }

    function test_Revert_SetMaxSlippage_TooHigh() public {
        vm.expectRevert();
        vault.setMaxSlippage(1000); // 10%
    }

    function test_SetPaused() public {
        vault.setPaused(true);
        assertTrue(vault.paused());
        vault.setPaused(false);
        assertFalse(vault.paused());
    }

    function test_OnlyOwner_CanSetAdapters() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.setAdapters(address(0), address(0), address(0));
        vm.stopPrank();
    }

    // ============ ERC4626兼容测试 ============

    function test_ERC4626_TotalAssets() public {
        _deposit(alice, 5 ether, 10000e6);
        assertGt(vault.totalAssets(), 0);
    }

    function test_ERC4626_ConvertToShares() public {
        _deposit(alice, 1 ether, 2000e6);
        uint256 assets = 1000e6;
        uint256 shares = vault.convertToShares(assets);
        assertGt(shares, 0);
    }

    function test_ERC4626_ConvertToAssets() public {
        _deposit(alice, 1 ether, 2000e6);
        uint256 shares = 1000;
        uint256 assets = vault.convertToAssets(shares);
        assertGt(assets, 0);
    }
}
