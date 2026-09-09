// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../../base/BaseTest.t.sol";
import {AdaptiveLPVault} from "../../../src/vault/AdaptiveLPVault.sol";

contract VaultDepositTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    function test_Deposit_DualAsset_FundsConserved() public {
        uint256 wethAmt = 10 ether;
        uint256 usdcAmt = 20_000e6;

        uint256 wethBefore = weth.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 totalAssetsBefore = vault.totalAssets();

        uint256 shares = _deposit(alice, wethAmt, usdcAmt);

        assertEq(weth.balanceOf(alice), wethBefore - wethAmt);
        assertEq(usdc.balanceOf(alice), usdcBefore - usdcAmt);

        assertGt(shares, 0, "shares should be > 0");
        assertEq(vault.balanceOf(alice), shares, "alice should have shares");
        assertEq(vault.totalSupply(), shares, "total supply should equal shares");

        assertGt(vault.totalAssets(), totalAssetsBefore, "total assets should increase");
        assertEq(vault.totalAssets(), vault.totalSupply());
    }

    function test_Deposit_DualAsset_StateChange() public {
        uint256 wethAmt = 5 ether;
        uint256 usdcAmt = 10_000e6;
        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 supplyBefore = vault.totalSupply();
        (uint256 totalWBefore, uint256 totalUBefore) = _getTotalUnderlying();

        uint256 shares = _deposit(alice, wethAmt, usdcAmt);

        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), sharesBefore + shares);
        assertEq(vault.totalSupply(), supplyBefore + shares);
        (uint256 totalW, uint256 totalU) = _getTotalUnderlying();
        assertEq(totalW, totalWBefore + wethAmt);
        assertEq(totalU, totalUBefore + usdcAmt);
    }

    function test_Deposit_DualAsset_InvestsToAdapters() public {
        _deposit(alice, 20 ether, 40_000e6);

        (uint256 idleW, uint256 v2W, uint256 v3LowW, uint256 v3HighW) = _getWethDistribution();
        (uint256 idleU, uint256 v2U, uint256 v3LowU, uint256 v3HighU) = _getUsdcDistribution();

        assertGt(v2W, 0, "V2 adapter should have WETH");
        assertGt(v3LowW, 0, "V3 low fee adapter should have WETH");
        assertGt(v3HighW, 0, "V3 high fee adapter should have WETH");
        assertGt(v2U, 0, "V2 adapter should have USDC");
        assertGt(v3LowU, 0, "V3 low fee adapter should have USDC");
        assertGt(v3HighU, 0, "V3 high fee adapter should have USDC");

        uint256 totalW = idleW + v2W + v3LowW + v3HighW;
        uint256 totalU = idleU + v2U + v3LowU + v3HighU;
        assertEq(totalW, 20 ether);
        assertEq(totalU, 40_000e6);
    }

    function test_Deposit_OnlyWETH_FundsConserved() public {
        uint256 wethAmt = 5 ether;
        uint256 wethBefore = weth.balanceOf(alice);

        uint256 shares = _deposit(alice, wethAmt, 0);

        assertEq(weth.balanceOf(alice), wethBefore - wethAmt);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_Deposit_OnlyUSDC_FundsConserved() public {
        uint256 usdcAmt = 10_000e6;
        uint256 usdcBefore = usdc.balanceOf(alice);

        uint256 shares = _deposit(alice, 0, usdcAmt);

        assertEq(usdc.balanceOf(alice), usdcBefore - usdcAmt);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_Deposit_FirstDepositor_SharesEqualsValue() public {
        uint256 wethAmt = 1 ether;
        uint256 usdcAmt = 2000e6;

        uint256 shares = _deposit(alice, wethAmt, usdcAmt);

        assertApproxEqRel(shares, 4000e6, 0.01e18);
    }

    function test_Deposit_SecondDepositor_SharesProportional() public {
        uint256 sharesA = _deposit(alice, 10 ether, 20_000e6);
        uint256 totalAssetsAfterA = vault.totalAssets();

        uint256 sharesB = _deposit(bob, 10 ether, 20_000e6);

        assertEq(sharesB, sharesA);
        assertGt(vault.totalAssets(), totalAssetsAfterA);
        assertEq(vault.totalSupply(), sharesA + sharesB);
    }

    function test_Deposit_MultipleUsers_NoDilution() public {
        uint256 sharesA = _deposit(alice, 10 ether, 20_000e6);
        uint256 assetsPerShareBefore = vault.totalAssets() * 1e18 / vault.totalSupply();
        assertEq(sharesA, vault.totalSupply());

        _deposit(bob, 20 ether, 40_000e6);

        uint256 assetsPerShareAfter = vault.totalAssets() * 1e18 / vault.totalSupply();
        assertApproxEqRel(assetsPerShareAfter, assetsPerShareBefore, 0.01e18);
    }

    function test_Deposit_MinShares_Accepts() public {
        _deposit(alice, 10 ether, 20_000e6);

        uint256 expectedShares = vault.totalSupply();
        uint256 minShares = expectedShares * 90 / 100;

        vm.prank(bob);
        uint256 shares = vault.deposit(10 ether, 20_000e6, minShares);

        assertGe(shares, minShares);
    }

    function test_Revert_Deposit_MinSharesTooHigh() public {
        _deposit(alice, 10 ether, 20_000e6);

        vm.prank(bob);
        vm.expectRevert(AdaptiveLPVault.SlippageExceeded.selector);
        vault.deposit(10 ether, 20_000e6, type(uint256).max);
    }

    function test_Revert_Deposit_ZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(AdaptiveLPVault.ZeroAmount.selector);
        vault.deposit(0, 0, 0);
    }

    function test_Revert_Deposit_WhenPaused() public {
        vault.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(AdaptiveLPVault.PausedError.selector);
        vault.deposit(1 ether, 2000e6, 0);
    }

    function test_Revert_Deposit_ERC4626_ZeroAmount() public {
        vm.startPrank(alice);
        vm.expectRevert(AdaptiveLPVault.ZeroAmount.selector);
        vault.deposit(0, alice);
        vm.stopPrank();
    }

    function test_Deposit_SmallAmount_Dust() public {
        uint256 smallWeth = 100;
        uint256 smallUsdc = 10;

        vm.prank(alice);
        uint256 shares = vault.deposit(smallWeth, smallUsdc, 0);

        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);

        (uint256 idleW, , , ) = _getWethDistribution();
        (uint256 idleU, , , ) = _getUsdcDistribution();
        assertEq(idleW, smallWeth);
        assertEq(idleU, smallUsdc);
    }

    function test_Deposit_AfterRebalance() public {
        _deposit(alice, 10 ether, 20_000e6);
        _rebalance();

        ( , uint256 v2WBefore, uint256 v3LowWBefore, uint256 v3HighWBefore) = _getWethDistribution();
        ( , uint256 v2UBefore, uint256 v3LowUBefore, uint256 v3HighUBefore) = _getUsdcDistribution();

        _deposit(bob, 5 ether, 10_000e6);

        ( , uint256 v2WAfter, uint256 v3LowWAfter, uint256 v3HighWAfter) = _getWethDistribution();
        ( , uint256 v2UAfter, uint256 v3LowUAfter, uint256 v3HighUAfter) = _getUsdcDistribution();

        assertGt(v2WAfter + v3LowWAfter + v3HighWAfter, v2WBefore + v3LowWBefore + v3HighWBefore);
        assertGt(v2UAfter + v3LowUAfter + v3HighUAfter, v2UBefore + v3LowUBefore + v3HighUBefore);
    }
}
