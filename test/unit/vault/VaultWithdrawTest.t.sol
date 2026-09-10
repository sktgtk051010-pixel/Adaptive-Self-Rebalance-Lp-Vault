// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../../base/BaseTest.t.sol";
import {AdaptiveLPVault} from "../../../src/vault/AdaptiveLPVault.sol";

contract VaultWithdrawTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // 测试全额赎回双币：用户收到WETH+USDC，所有份额销毁，总供应量归零
    function test_WithdrawDual_Full_FundsConserved() public {
        uint256 wethAmt = 10 ether;
        uint256 usdcAmt = 20_000e6;
        uint256 shares = _deposit(alice, wethAmt, usdcAmt);

        uint256 wethBefore = weth.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(shares, 0, 0);

        assertGt(wethOut, 0, "should receive WETH");
        assertGt(usdcOut, 0, "should receive USDC");
        assertEq(weth.balanceOf(alice), wethBefore + wethOut, "WETH balance mismatch");
        assertEq(usdc.balanceOf(alice), usdcBefore + usdcOut, "USDC balance mismatch");

        assertEq(vault.balanceOf(alice), 0, "all shares burned");
        assertEq(vault.totalSupply(), 0, "total supply zero");
    }

    // 测试部分赎回：赎回一半份额后，金库剩余底层资产约为原来的一半
    function test_WithdrawDual_Partial_Proportional() public {
        uint256 shares = _deposit(alice, 20 ether, 40_000e6);
        uint256 halfShares = shares / 2;

        vm.prank(alice);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(halfShares, 0, 0);

        assertEq(vault.balanceOf(alice), shares - halfShares);

        (uint256 totalWAfter, uint256 totalUAfter) = _getTotalUnderlying();
        assertApproxEqRel(totalWAfter, 10 ether, 0.05e18);
        assertApproxEqRel(totalUAfter, 20_000e6, 0.05e18);

        assertGt(wethOut, 0);
        assertGt(usdcOut, 0);
    }

    // 测试再平衡后全额赎回：资金从V2/V3适配器全部撤出，适配器余额归零
    function test_WithdrawDual_AfterRebalance() public {
        uint256 shares = _deposit(alice, 20 ether, 40_000e6);
        _rebalance();

        (uint256 idleW, uint256 v2W, uint256 v3LowW, uint256 v3HighW) = _getWethDistribution();
        assertTrue(v2W + v3LowW + v3HighW > idleW, "most WETH should be in adapters");

        uint256 wethBefore = weth.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(shares, 0, 0);

        (, uint256 v2WAfter, uint256 v3LowWAfter, uint256 v3HighWAfter) = _getWethDistribution();
        assertEq(v2WAfter, 0);
        assertEq(v3LowWAfter, 0);
        assertEq(v3HighWAfter, 0);

        assertGt(wethOut, 0);
        assertGt(usdcOut, 0);
        assertEq(weth.balanceOf(alice), wethBefore + wethOut);
        assertEq(usdc.balanceOf(alice), usdcBefore + usdcOut);
        assertEq(vault.balanceOf(alice), 0);
    }

    // 测试多次再平衡和价格变动后仍能正常全额赎回，份额全部销毁
    function test_WithdrawDual_MultipleRebalances() public {
        uint256 shares = _deposit(alice, 20 ether, 40_000e6);
        _rebalance();
        _setPrice(2200);
        _rebalance();
        _setPrice(2100);
        _rebalance();

        vm.prank(alice);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(shares, 0, 0);

        assertGt(wethOut, 0);
        assertGt(usdcOut, 0);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalSupply(), 0);
    }

    // 测试设置合理的minWETH/minUSDC（预期的90%）时赎回成功通过滑点检查
    function test_WithdrawDual_MinOutput_Accepts() public {
        uint256 shares = _deposit(alice, 10 ether, 20_000e6);
        _rebalance();

        (uint256 totalW, uint256 totalU) = _getTotalUnderlying();
        uint256 totalSupply = vault.totalSupply();
        uint256 minWeth = (totalW * shares / totalSupply) * 90 / 100;
        uint256 minUsdc = (totalU * shares / totalSupply) * 90 / 100;

        vm.prank(alice);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(shares, minWeth, minUsdc);

        assertGe(wethOut, minWeth);
        assertGe(usdcOut, minUsdc);
    }

    // 测试minWETH/minUSDC设置过高时revert SlippageExceeded
    function test_Revert_WithdrawDual_MinOutputTooHigh() public {
        uint256 shares = _deposit(alice, 10 ether, 20_000e6);
        _rebalance();

        vm.prank(alice);
        vm.expectRevert(AdaptiveLPVault.SlippageExceeded.selector);
        vault.withdrawDual(shares, 1000 ether, 1_000_000e6);
    }

    // 测试minOutput设置为实际输出的99%（边界值）时赎回成功
    function test_WithdrawDual_MinOutput_ExactBoundary() public {
        uint256 shares = _deposit(alice, 10 ether, 20_000e6);
        _rebalance();

        vm.prank(alice);
        (uint256 actualWeth, uint256 actualUsdc) = vault.withdrawDual(shares, 0, 0);

        uint256 shares2 = _deposit(alice, 10 ether, 20_000e6);
        _rebalance();

        uint256 minWeth = actualWeth * 99 / 100;
        uint256 minUsdc = actualUsdc * 99 / 100;

        vm.prank(alice);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(shares2, minWeth, minUsdc);

        assertGe(wethOut, minWeth, "wethOut should >= minWeth");
        assertGe(usdcOut, minUsdc, "usdcOut should >= minUsdc");
    }

    // 测试仅minWETH设置过高（minUSDC合理）时仍revert SlippageExceeded
    function test_Revert_WithdrawDual_OnlyMinWethTooHigh() public {
        uint256 shares = _deposit(alice, 10 ether, 20_000e6);
        _rebalance();

        ( , uint256 totalU) = _getTotalUnderlying();
        uint256 totalSupply = vault.totalSupply();
        uint256 expectedUsdc = (totalU * shares / totalSupply) * 90 / 100;

        vm.prank(alice);
        vm.expectRevert(AdaptiveLPVault.SlippageExceeded.selector);
        vault.withdrawDual(shares, 1000 ether, expectedUsdc);
    }

    // 测试仅minUSDC设置过高（minWETH合理）时仍revert SlippageExceeded
    function test_Revert_WithdrawDual_OnlyMinUsdcTooHigh() public {
        uint256 shares = _deposit(alice, 10 ether, 20_000e6);
        _rebalance();

        (uint256 totalW, ) = _getTotalUnderlying();
        uint256 totalSupply = vault.totalSupply();
        uint256 expectedWeth = (totalW * shares / totalSupply) * 90 / 100;

        vm.prank(alice);
        vm.expectRevert(AdaptiveLPVault.SlippageExceeded.selector);
        vault.withdrawDual(shares, expectedWeth, 1_000_000e6);
    }

    // 测试minOutput设为0时不做用户侧滑点检查，正常赎回
    function test_WithdrawDual_ZeroMinOutput_NoUserSlippageCheck() public {
        uint256 shares = _deposit(alice, 10 ether, 20_000e6);
        _rebalance();

        vm.prank(alice);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(shares, 0, 0);

        assertGt(wethOut, 0, "should receive WETH");
        assertGt(usdcOut, 0, "should receive USDC");
        assertEq(vault.balanceOf(alice), 0, "all shares burned");
    }

    // 测试Alice赎回不会影响Bob的每份资产价值（无挤兑稀释）
    function test_WithdrawDual_AliceDoesNotAffectBob() public {
        uint256 sharesA = _deposit(alice, 10 ether, 20_000e6);
        uint256 sharesB = _deposit(bob, 10 ether, 20_000e6);

        uint256 bobAssetsBefore = vault.convertToAssets(sharesB);

        vm.prank(alice);
        vault.withdrawDual(sharesA, 0, 0);

        uint256 bobAssetsAfter = vault.convertToAssets(sharesB);
        assertApproxEqRel(bobAssetsAfter, bobAssetsBefore, 0.1e18);
        assertEq(vault.balanceOf(bob), sharesB);
    }

    // 测试所有用户全部赎回后金库总供应量归零
    function test_WithdrawDual_AllUsersExit() public {
        uint256 sharesA = _deposit(alice, 5 ether, 10_000e6);
        uint256 sharesB = _deposit(bob, 5 ether, 10_000e6);

        vm.prank(alice);
        vault.withdrawDual(sharesA, 0, 0);

        vm.prank(bob);
        vault.withdrawDual(sharesB, 0, 0);

        assertEq(vault.totalSupply(), 0);
    }

    // 测试赎回0份额时revert ZeroAmount
    function test_Revert_WithdrawDual_ZeroShares() public {
        _deposit(alice, 1 ether, 2000e6);

        vm.prank(alice);
        vm.expectRevert(AdaptiveLPVault.ZeroAmount.selector);
        vault.withdrawDual(0, 0, 0);
    }

    // 测试赎回超过自身持有份额时revert（insufficient shares）
    function test_Revert_WithdrawDual_InsufficientShares() public {
        _deposit(alice, 1 ether, 2000e6);

        vm.prank(bob);
        vm.expectRevert();
        vault.withdrawDual(100_000_000e6, 0, 0);
    }

    // 测试赎回极小份额（千分之一）时正常执行，剩余份额正确
    function test_WithdrawDual_SmallShares() public {
        uint256 shares = _deposit(alice, 20 ether, 40_000e6);
        uint256 smallShares = shares / 1000;

        vm.prank(alice);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(smallShares, 0, 0);

        assertGe(wethOut, 0);
        assertGe(usdcOut, 0);
        assertEq(vault.balanceOf(alice), shares - smallShares);
    }
}
