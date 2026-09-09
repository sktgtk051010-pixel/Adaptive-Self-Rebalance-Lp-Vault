// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../../base/BaseTest.t.sol";

contract VaultERC4626Test is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    function test_Asset_ReturnsUSDC() public view {
        assertEq(vault.asset(), address(usdc));
    }

    function test_TotalAssets_Override() public {
        assertEq(vault.totalAssets(), 0);
        _deposit(alice, 0, 1_000e6);
        assertEq(vault.totalAssets(), 1_000e6);
    }

    function test_ConvertToShares_ZeroSupply() public view {
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.convertToShares(1000e6), 1000e6);
    }

    function test_ConvertToShares_Proportional() public {
        uint256 shares = _deposit(alice, 0, 10_000e6);

        assertEq(shares, 10_000e6);
        assertEq(vault.convertToShares(10_000e6), shares);
    }

    function test_ConvertToAssets_ZeroSupply() public view {
        assertEq(vault.convertToAssets(1000), 1000);
    }

    function test_ConvertToAssets_Proportional() public {
        _deposit(alice, 0, 10_000e6);

        assertEq(vault.totalAssets(), 10_000e6);
        assertEq(vault.convertToAssets(10_000e6), 10_000e6);
    }

    function test_PreviewDeposit_MatchesActual() public {
        uint256 shares = _deposit(bob, 0, 5_000e6);
        uint256 previewShares = vault.previewDeposit(5000e6);

        assertEq(shares, previewShares);
    }

    function test_PreviewMint_MatchesActual() public {
        _deposit(alice, 0, 10_000e6);

        uint256 sharesToMint = vault.totalSupply() / 2;
        uint256 previewAssets = vault.previewMint(sharesToMint);

        vm.prank(bob);
        uint256 actualAssets = vault.mint(sharesToMint, bob);

        assertEq(actualAssets, previewAssets);
    }

    function test_PreviewWithdraw_MatchesActual() public {
        uint256 shares = _deposit(alice, 0, 10_000e6);

        uint256 assetsToWithdraw = 2_500e6;
        uint256 previewShares = vault.previewWithdraw(assetsToWithdraw);

        vm.prank(alice);
        uint256 actualShares = vault.withdraw(assetsToWithdraw, alice, alice);

        assertEq(actualShares, previewShares);
    }

    function test_PreviewRedeem_MatchesActual() public {
        uint256 shares = _deposit(alice, 0, 10_000e6);
        uint256 sharesToRedeem = shares / 2;

        uint256 previewAssets = vault.previewRedeem(sharesToRedeem);

        vm.startPrank(alice);
        uint256 actualAssets = vault.redeem(sharesToRedeem, alice, alice);

        assertEq(actualAssets, previewAssets);
    }

    function test_MaxDeposit_ReturnsMax() public view {
        assertEq(vault.maxDeposit(alice), type(uint256).max);
    }

    function test_MaxMint_ReturnsMax() public view {
        assertEq(vault.maxMint(alice), type(uint256).max);
    }

    function test_MaxWithdraw_ReturnsUserAssets() public {
        uint256 shares = _deposit(alice, 0, 10_000e6);
        uint256 maxWithdraw = vault.maxWithdraw(alice);

        assertEq(maxWithdraw, vault.convertToAssets(shares));
    }

    function test_MaxRedeem_ReturnsUserShares() public {
        uint256 shares = _deposit(alice, 0, 10_000e6);
        assertEq(vault.maxRedeem(alice), shares);
    }

    function test_MaxWithdraw_EmptyUser() public view {
        assertEq(vault.maxWithdraw(bob), 0);
    }

    function test_MaxRedeem_EmptyUser() public view {
        assertEq(vault.maxRedeem(bob), 0);
    }
}
