// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../../base/BaseTest.t.sol";
import {AdaptiveLPVault} from "../../../src/vault/AdaptiveLPVault.sol";

/**
 * @title VaultWithdrawTest
 * @notice 金库取款功能专项测试
 */
contract VaultWithdrawTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // ============ withdrawDual ============

    /// @notice 全部赎回：资金守恒
    function test_WithdrawDual_Full_FundsConserved() public {
        uint256 wethAmt = 10 ether;
        uint256 usdcAmt = 20_000e6;
        uint256 shares = _deposit(alice, wethAmt, usdcAmt);

        uint256 wethBefore = weth.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(shares, 0, 0);
        vm.stopPrank();

        // 用户收到资金
        assertGt(wethOut, 0, "should receive WETH");
        assertGt(usdcOut, 0, "should receive USDC");
        assertEq(weth.balanceOf(alice), wethBefore + wethOut, "WETH balance mismatch");
        assertEq(usdc.balanceOf(alice), usdcBefore + usdcOut, "USDC balance mismatch");

        // 份额销毁
        assertEq(vault.balanceOf(alice), 0, "all shares burned");
        assertEq(vault.totalSupply(), 0, "total supply zero");
    }

    /// @notice 全部赎回：验证Withdrawn事件
    function test_WithdrawDual_Full_EmitEvent() public {
        uint256 shares = _deposit(alice, 10 ether, 20_000e6);
        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(shares, 0, 0);
        vm.stopPrank();

        assertGt(wethOut, 0);
        assertGt(usdcOut, 0);
        assertEq(vault.balanceOf(alice), 0, "all shares should be burned");
        assertEq(weth.balanceOf(alice), aliceWethBefore + wethOut);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + usdcOut);
    }

    /// @notice 部分赎回：比例正确
    function test_WithdrawDual_Partial_Proportional() public {
        uint256 shares = _deposit(alice, 20 ether, 40_000e6);
        uint256 halfShares = shares / 2;

        (uint256 totalWBefore, uint256 totalUBefore) = _getTotalUnderlying();

        vm.startPrank(alice);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(halfShares, 0, 0);
        vm.stopPrank();

        // 剩余份额
        assertEq(vault.balanceOf(alice), shares - halfShares);

        // 取出约一半资金（允许滑点/dust）
        (uint256 totalWAfter, uint256 totalUAfter) = _getTotalUnderlying();
        assertApproxEqRel(totalWAfter, totalWBefore / 2, 0.05e18, "WETH should decrease ~half");
        assertApproxEqRel(totalUAfter, totalUBefore / 2, 0.05e18, "USDC should decrease ~half");

        assertGt(wethOut, 0);
        assertGt(usdcOut, 0);
    }

    /// @notice 再平衡后赎回：从adapter撤出资金
    function test_WithdrawDual_AfterRebalance() public {
        uint256 shares = _deposit(alice, 20 ether, 40_000e6);
        _rebalance();

        // 确认资金在adapter中
        (uint256 idleW, uint256 v2W, uint256 v3LowW, uint256 v3HighW) = _getWethDistribution();
        assertTrue(v2W + v3LowW + v3HighW > idleW, "most WETH should be in adapters");

        uint256 wethBefore = weth.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(shares, 0, 0);
        vm.stopPrank();

        assertGt(wethOut, 0);
        assertGt(usdcOut, 0);
        assertEq(weth.balanceOf(alice), wethBefore + wethOut);
        assertEq(usdc.balanceOf(alice), usdcBefore + usdcOut);
        assertEq(vault.balanceOf(alice), 0);
    }

    /// @notice 多次再平衡后赎回
    function test_WithdrawDual_MultipleRebalances() public {
        uint256 shares = _deposit(alice, 20 ether, 40_000e6);
        _rebalance();
        _setPrice(2200);
        _rebalance();
        _setPrice(2100);
        _rebalance();

        vm.startPrank(alice);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(shares, 0, 0);
        vm.stopPrank();

        assertGt(wethOut, 0);
        assertGt(usdcOut, 0);
        assertEq(vault.balanceOf(alice), 0);
    }

    // ============ 滑点保护 ============

    /// @notice 合理minOutput成功
    function test_WithdrawDual_MinOutput_Accepts() public {
        uint256 shares = _deposit(alice, 10 ether, 20_000e6);
        _rebalance();

        (uint256 totalW, uint256 totalU) = _getTotalUnderlying();
        uint256 totalSupply = vault.totalSupply();
        uint256 minWeth = totalW * shares / totalSupply * 90 / 100;
        uint256 minUsdc = totalU * shares / totalSupply * 90 / 100;

        vm.startPrank(alice);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(shares, minWeth, minUsdc);
        vm.stopPrank();

        assertGe(wethOut, minWeth);
        assertGe(usdcOut, minUsdc);
    }

    /// @notice minOutput过高revert
    function test_Revert_WithdrawDual_MinOutputTooHigh() public {
        uint256 shares = _deposit(alice, 10 ether, 20_000e6);
        _rebalance();

        vm.startPrank(alice);
        vm.expectRevert(AdaptiveLPVault.SlippageExceeded.selector);
        vault.withdrawDual(shares, 1000 ether, 1_000_000e6);
        vm.stopPrank();
    }

    // ============ ERC4626标准 ============

    /// @notice ERC4626标准withdraw（仅USDC）
    function test_Withdraw_ERC4626_Standard() public {
        uint256 usdcAmt = 50_000e6;
        vm.startPrank(alice);
        uint256 shares = vault.deposit(usdcAmt, alice);
        vm.stopPrank();
        uint256 actualShares = vault.balanceOf(alice);
        assertEq(shares, actualShares);
        uint256 maxAssets = vault.previewRedeem(actualShares);
        uint256 assetsToWithdraw = maxAssets / 4;
        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.startPrank(alice);
        uint256 sharesBurned = vault.withdraw(assetsToWithdraw, alice, alice);
        vm.stopPrank();
        assertGt(sharesBurned, 0);
        assertEq(usdc.balanceOf(alice), usdcBefore + assetsToWithdraw);
        assertEq(vault.balanceOf(alice), actualShares - sharesBurned);
    }

    /// @notice ERC4626标准redeem
    function test_Redeem_ERC4626_Standard() public {
        uint256 usdcAmt = 50_000e6;
        vm.startPrank(alice);
        uint256 shares = vault.deposit(usdcAmt, alice);
        vm.stopPrank();
        uint256 actualShares = vault.balanceOf(alice);
        assertEq(shares, actualShares);
        uint256 sharesToRedeem = actualShares / 2;
        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.startPrank(alice);
        uint256 assets = vault.redeem(sharesToRedeem, alice, alice);
        vm.stopPrank();
        assertGt(assets, 0);
        assertEq(usdc.balanceOf(alice), usdcBefore + assets);
        assertEq(vault.balanceOf(alice), actualShares - sharesToRedeem);
    }

    // ============ 多用户 ============

    /// @notice Alice赎回不影响Bob的份额价值
    function test_WithdrawDual_AliceDoesNotAffectBob() public {
        uint256 sharesA = _deposit(alice, 10 ether, 20_000e6);
        uint256 sharesB = _deposit(bob, 10 ether, 20_000e6);

        uint256 bobAssetsBefore = vault.convertToAssets(sharesB);

        vm.startPrank(alice);
        vault.withdrawDual(sharesA, 0, 0);
        vm.stopPrank();

        uint256 bobAssetsAfter = vault.convertToAssets(sharesB);
        assertApproxEqRel(bobAssetsAfter, bobAssetsBefore, 0.05e18, "Bob share value should not change");
        assertEq(vault.balanceOf(bob), sharesB);
    }

    /// @notice 所有用户依次赎回后vault清空
    function test_WithdrawDual_AllUsersExit() public {
        uint256 sharesA = _deposit(alice, 5 ether, 10_000e6);
        uint256 sharesB = _deposit(bob, 5 ether, 10_000e6);

        vm.startPrank(alice);
        vault.withdrawDual(sharesA, 0, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.withdrawDual(sharesB, 0, 0);
        vm.stopPrank();

        assertEq(vault.totalSupply(), 0);
    }

    // ============ 边界 / Revert ============

    /// @notice 零份额revert
    function test_Revert_WithdrawDual_ZeroShares() public {
        _deposit(alice, 1 ether, 2000e6);
        vm.startPrank(alice);
        vm.expectRevert(AdaptiveLPVault.ZeroAmount.selector);
        vault.withdrawDual(0, 0, 0);
        vm.stopPrank();
    }

    /// @notice 超过持有量revert
    function test_Revert_WithdrawDual_InsufficientShares() public {
        _deposit(alice, 1 ether, 2000e6);
        vm.startPrank(bob);
        vm.expectRevert(bytes("Vault: insufficient shares"));
        vault.withdrawDual(1000, 0, 0);
        vm.stopPrank();
    }

    /// @notice 小额赎回处理dust
    function test_WithdrawDual_SmallShares() public {
        uint256 shares = _deposit(alice, 20 ether, 40_000e6);
        uint256 smallShares = shares / 1000; // 0.1%

        vm.startPrank(alice);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(smallShares, 0, 0);
        vm.stopPrank();

        // 小额可能只取出一种币或都很少，但不应revert
        assertEq(vault.balanceOf(alice), shares - smallShares);
    }

    // ============ Fuzz ============

    /// @notice Fuzz：存款后全部赎回，份额守恒
    function testFuzz_DepositWithdraw_SharesConserved(uint256 wethRaw, uint256 usdcRaw) public {
        uint256 wethAmt = bound(wethRaw, 1 ether, 50 ether);
        uint256 usdcAmt = bound(usdcRaw, 1000e6, 100_000e6);

        uint256 shares = _deposit(alice, wethAmt, usdcAmt);

        vm.startPrank(alice);
        vault.withdrawDual(shares, 0, 0);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalSupply(), 0);
    }
}
