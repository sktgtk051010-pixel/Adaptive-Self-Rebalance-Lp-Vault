// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../../base/BaseTest.t.sol";
import {AdaptiveLPVault} from "../../../src/vault/AdaptiveLPVault.sol";

/**
 * @title VaultDepositTest
 * @notice 金库存款功能专项测试
 */
contract VaultDepositTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // ============ 双币存款 ============

    /// @notice 双币存款：资金守恒 + 份额正确
    function test_Deposit_DualAsset_FundsConserved() public {
        uint256 wethAmt = 10 ether;
        uint256 usdcAmt = 20_000e6;

        uint256 wethBefore = weth.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 totalAssetsBefore = vault.totalAssets();

        uint256 shares = _deposit(alice, wethAmt, usdcAmt);

        // 用户资金减少
        assertEq(weth.balanceOf(alice), wethBefore - wethAmt, "alice WETH should decrease");
        assertEq(usdc.balanceOf(alice), usdcBefore - usdcAmt, "alice USDC should decrease");

        // 份额正确
        assertGt(shares, 0, "shares should be > 0");
        assertEq(vault.balanceOf(alice), shares, "alice should have shares");
        assertEq(vault.totalSupply(), shares, "total supply should equal shares");

        // 总资产增加（首次存款1:1）
        assertGt(vault.totalAssets(), totalAssetsBefore, "total assets should increase");
    }

    /// @notice 双币存款：验证存款后状态变化
    function test_Deposit_DualAsset_EmitEvent() public {
        uint256 wethAmt = 5 ether;
        uint256 usdcAmt = 10_000e6;
        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 supplyBefore = vault.totalSupply();

        vm.startPrank(alice);
        uint256 shares = vault.deposit(wethAmt, usdcAmt, 0);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), sharesBefore + shares);
        assertEq(vault.totalSupply(), supplyBefore + shares);
        // 验证资金被投资
        (uint256 totalW, uint256 totalU) = _getTotalUnderlying();
        assertGt(totalW, 0, "WETH should be in vault system");
        assertGt(totalU, 0, "USDC should be in vault system");
    }

    /// @notice 双币存款：资金确实投资到了adapter
    function test_Deposit_DualAsset_InvestsToAdapters() public {
        _deposit(alice, 20 ether, 40_000e6);

        (uint256 idleW, uint256 v2W, uint256 v3LowW, uint256 v3HighW) = _getWethDistribution();
        (uint256 idleU, uint256 v2U, uint256 v3LowU, uint256 v3HighU) = _getUsdcDistribution();

        // 至少有一些资金被分配到adapter
        assertTrue(v2W + v3LowW + v3HighW > 0, "WETH should be invested");
        assertTrue(v2U + v3LowU + v3HighU > 0, "USDC should be invested");

        // 总资金守恒
        uint256 totalW = idleW + v2W + v3LowW + v3HighW;
        uint256 totalU = idleU + v2U + v3LowU + v3HighU;
        assertEq(totalW, 20 ether, "total WETH conserved");
        assertApproxEqAbs(totalU, 40_000e6, 1000, "total USDC conserved (dust tolerance)");
    }

    // ============ 单币存款 ============

    /// @notice 只存WETH
    function test_Deposit_OnlyWETH_FundsConserved() public {
        uint256 wethAmt = 5 ether;
        uint256 wethBefore = weth.balanceOf(alice);

        uint256 shares = _deposit(alice, wethAmt, 0);

        assertEq(weth.balanceOf(alice), wethBefore - wethAmt);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
    }

    /// @notice 只存USDC
    function test_Deposit_OnlyUSDC_FundsConserved() public {
        uint256 usdcAmt = 10_000e6;
        uint256 usdcBefore = usdc.balanceOf(alice);

        uint256 shares = _deposit(alice, 0, usdcAmt);

        assertEq(usdc.balanceOf(alice), usdcBefore - usdcAmt);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
    }

    // ============ 份额计算 ============

    /// @notice 首次存款：shares = totalValue（1:1）
    function test_Deposit_FirstDepositor_SharesEqualsValue() public {
        uint256 wethAmt = 1 ether;
        uint256 usdcAmt = 2000e6;

        uint256 shares = _deposit(alice, wethAmt, usdcAmt);

        // 首次存款totalSupply=0，shares=totalValue=usdc + weth*price
        // 价格约2000 USDC/ETH，1 WETH ≈ 2000e6 USDC
        // totalValue ≈ 2000e6 + 2000e6 = 4000e6
        assertApproxEqRel(shares, 4000e6, 0.01e18, "first deposit shares approx total value");
    }

    /// @notice 第二次存款：shares按比例计算
    function test_Deposit_SecondDepositor_SharesProportional() public {
        // Alice首次存款建立价格
        uint256 sharesA = _deposit(alice, 10 ether, 20_000e6);
        uint256 totalAssetsAfterA = vault.totalAssets();

        // Bob存相同金额，应该得到相同份额
        uint256 sharesB = _deposit(bob, 10 ether, 20_000e6);

        assertApproxEqRel(sharesB, sharesA, 0.01e18, "same deposit should get same shares");
        assertEq(vault.totalSupply(), sharesA + sharesB);
    }

    /// @notice 多用户存款不稀释已有用户
    function test_Deposit_MultipleUsers_NoDilution() public {
        uint256 sharesA = _deposit(alice, 10 ether, 20_000e6);
        uint256 assetsPerShareBefore = vault.totalAssets() * 1e18 / sharesA;

        _deposit(bob, 20 ether, 40_000e6);

        uint256 assetsPerShareAfter = vault.totalAssets() * 1e18 / vault.totalSupply();
        assertApproxEqRel(assetsPerShareAfter, assetsPerShareBefore, 0.01e18, "share price should not change");
    }

    // ============ 滑点保护 ============

    /// @notice minShares合理时成功
    function test_Deposit_MinShares_Accepts() public {
        _deposit(alice, 10 ether, 20_000e6);

        // Bob存款，设置合理的minShares（预期的90%）
        uint256 expectedShares = vault.totalSupply(); // 相同金额应该得到相同份额
        uint256 minShares = expectedShares * 90 / 100;

        vm.startPrank(bob);
        uint256 shares = vault.deposit(10 ether, 20_000e6, minShares);
        vm.stopPrank();

        assertGe(shares, minShares);
    }

    /// @notice minShares过高时revert
    function test_Revert_Deposit_MinSharesTooHigh() public {
        _deposit(alice, 10 ether, 20_000e6);

        vm.startPrank(bob);
        vm.expectRevert(AdaptiveLPVault.SlippageExceeded.selector);
        vault.deposit(10 ether, 20_000e6, type(uint256).max);
        vm.stopPrank();
    }

    // ============ ERC4626标准存款 ============

    /// @notice ERC4626标准deposit（仅USDC）
    function test_Deposit_ERC4626_Standard() public {
        uint256 usdcAmt = 10_000e6;
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        uint256 shares = vault.deposit(usdcAmt, alice);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(usdc.balanceOf(alice), usdcBefore - usdcAmt);
    }

    /// @notice ERC4626标准mint
    function test_Mint_ERC4626_Standard() public {
        _deposit(alice, 10 ether, 20_000e6);

        uint256 sharesToMint = vault.totalSupply() / 2;
        uint256 usdcBefore = usdc.balanceOf(bob);

        vm.startPrank(bob);
        uint256 assets = vault.mint(sharesToMint, bob);
        vm.stopPrank();

        assertGt(assets, 0);
        assertEq(vault.balanceOf(bob), sharesToMint);
        assertEq(usdc.balanceOf(bob), usdcBefore - assets);
    }

    // ============ 边界 / Revert ============

    /// @notice 双零存款revert
    function test_Revert_Deposit_ZeroAmount() public {
        vm.startPrank(alice);
        vm.expectRevert(AdaptiveLPVault.ZeroAmount.selector);
        vault.deposit(0, 0, 0);
        vm.stopPrank();
    }

    /// @notice 暂停时存款revert
    function test_Revert_Deposit_WhenPaused() public {
        vault.setPaused(true);
        vm.startPrank(alice);
        vm.expectRevert(AdaptiveLPVault.PausedError.selector);
        vault.deposit(1 ether, 2000e6, 0);
        vm.stopPrank();
    }

    /// @notice ERC4626 deposit零金额revert
    function test_Revert_Deposit_ERC4626_ZeroAmount() public {
        vm.startPrank(alice);
        vm.expectRevert(AdaptiveLPVault.ZeroAmount.selector);
        vault.deposit(0, alice);
        vm.stopPrank();
    }

    /// @notice 小额存款（小于dust）不投资但仍有份额
    function test_Deposit_SmallAmount_Dust() public {
        uint256 smallWeth = 100; // 远小于1e12
        uint256 smallUsdc = 10;  // 远小于1000

        weth.mint(alice, smallWeth);
        usdc.mint(alice, smallUsdc);

        vm.startPrank(alice);
        weth.approve(address(vault), smallWeth);
        usdc.approve(address(vault), smallUsdc);
        uint256 shares = vault.deposit(smallWeth, smallUsdc, 0);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);

        // 资金应该留在vault闲置（没有投资到adapter）
        (uint256 idleW, , , ) = _getWethDistribution();
        assertEq(idleW, smallWeth, "small WETH should stay idle");
    }

    /// @notice 再平衡后存款，资金正确追加
    function test_Deposit_AfterRebalance() public {
        _deposit(alice, 10 ether, 20_000e6);
        _rebalance();

        uint256 supplyBefore = vault.totalSupply();
        uint256 shares = _deposit(bob, 5 ether, 10_000e6);

        assertGt(shares, 0);
        assertEq(vault.totalSupply(), supplyBefore + shares);
    }

    // ============ Fuzz ============

    /// @notice Fuzz：各种金额存款的资金守恒
    function testFuzz_Deposit_FundsConserved(uint256 wethRaw, uint256 usdcRaw) public {
        uint256 wethAmt = bound(wethRaw, 0.01 ether, 50 ether);
        uint256 usdcAmt = bound(usdcRaw, 100e6, 100_000e6);

        weth.mint(alice, wethAmt);
        usdc.mint(alice, usdcAmt);

        uint256 wethBefore = weth.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        weth.approve(address(vault), wethAmt);
        usdc.approve(address(vault), usdcAmt);
        uint256 shares = vault.deposit(wethAmt, usdcAmt, 0);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(weth.balanceOf(alice), wethBefore - wethAmt);
        assertEq(usdc.balanceOf(alice), usdcBefore - usdcAmt);
        assertEq(vault.balanceOf(alice), shares);
    }
}
