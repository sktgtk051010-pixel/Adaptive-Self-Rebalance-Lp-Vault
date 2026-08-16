// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../../base/BaseTest.t.sol";

/**
 * @title VaultERC4626Test
 * @notice ERC4626标准合规性专项测试
 */
contract VaultERC4626Test is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    /// @notice asset()返回USDC
    function test_Asset_ReturnsUSDC() public {
        assertEq(vault.asset(), address(usdc));
    }

    /// @notice totalAssets覆盖正确
    function test_TotalAssets_Override() public {
        assertEq(vault.totalAssets(), 0);
        _deposit(alice, 0, 1000e6);
        assertGt(vault.totalAssets(), 0);
    }

    /// @notice 零供应时convertToShares 1:1
    function test_ConvertToShares_ZeroSupply() public {
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.convertToShares(1000e6), 1000e6);
    }

    /// @notice 有供应时按比例转换
    function test_ConvertToShares_Proportional() public {
        _deposit(alice, 0, 10_000e6);
        uint256 supply = vault.totalSupply();
        uint256 assets = vault.totalAssets();

        // 存一半资产应该得到一半份额
        uint256 expectedShares = (assets / 2) * supply / assets;
        assertEq(vault.convertToShares(assets / 2), expectedShares);
    }

    /// @notice 零供应时convertToAssets 1:1
    function test_ConvertToAssets_ZeroSupply() public {
        assertEq(vault.convertToAssets(1000), 1000);
    }

    /// @notice 有供应时按比例转换资产
    function test_ConvertToAssets_Proportional() public {
        _deposit(alice, 0, 10_000e6);
        uint256 supply = vault.totalSupply();
        uint256 assets = vault.totalAssets();

        // 一半份额对应一半资产
        uint256 halfShares = supply / 2;
        uint256 expectedAssets = halfShares * assets / supply;
        assertEq(vault.convertToAssets(halfShares), expectedAssets);
    }

    /// @notice previewDeposit与实际deposit匹配
    function test_PreviewDeposit_MatchesActual() public {
        _deposit(alice, 0, 10_000e6);

        uint256 previewShares = vault.previewDeposit(5000e6);

        vm.startPrank(bob);
        uint256 actualShares = vault.deposit(5000e6, bob);
        vm.stopPrank();

        assertApproxEqRel(actualShares, previewShares, 0.01e18, "preview approx actual");
    }

    /// @notice previewMint与实际mint匹配
    function test_PreviewMint_MatchesActual() public {
        _deposit(alice, 0, 10_000e6);

        uint256 sharesToMint = vault.totalSupply() / 2;
        uint256 previewAssets = vault.previewMint(sharesToMint);

        vm.startPrank(bob);
        uint256 actualAssets = vault.mint(sharesToMint, bob);
        vm.stopPrank();

        assertApproxEqRel(actualAssets, previewAssets, 0.01e18, "preview approx actual");
    }

    /// @notice previewWithdraw与实际withdraw匹配
    function test_PreviewWithdraw_MatchesActual() public {
        uint256 shares = _deposit(alice, 0, 10_000e6);

        uint256 assetsToWithdraw = vault.totalAssets() / 4;
        uint256 previewShares = vault.previewWithdraw(assetsToWithdraw);

        vm.startPrank(alice);
        uint256 actualShares = vault.withdraw(assetsToWithdraw, alice, alice);
        vm.stopPrank();

        assertApproxEqRel(actualShares, previewShares, 0.01e18, "preview approx actual");
    }

    /// @notice previewRedeem与实际redeem匹配
    function test_PreviewRedeem_MatchesActual() public {
        uint256 shares = _deposit(alice, 0, 10_000e6);
        uint256 sharesToRedeem = shares / 2;

        uint256 previewAssets = vault.previewRedeem(sharesToRedeem);

        vm.startPrank(alice);
        uint256 actualAssets = vault.redeem(sharesToRedeem, alice, alice);
        vm.stopPrank();

        assertApproxEqRel(actualAssets, previewAssets, 0.01e18, "preview approx actual");
    }

    /// @notice maxDeposit无上限
    function test_MaxDeposit_ReturnsMax() public {
        assertEq(vault.maxDeposit(alice), type(uint256).max);
    }

    /// @notice maxMint无上限
    function test_MaxMint_ReturnsMax() public {
        assertEq(vault.maxMint(alice), type(uint256).max);
    }

    /// @notice maxWithdraw返回用户可提取的最大资产
    function test_MaxWithdraw_ReturnsUserAssets() public {
        uint256 shares = _deposit(alice, 0, 10_000e6);
        uint256 maxWithdraw = vault.maxWithdraw(alice);
        assertApproxEqRel(maxWithdraw, vault.convertToAssets(shares), 0.01e18);
    }

    /// @notice maxRedeem返回用户份额
    function test_MaxRedeem_ReturnsUserShares() public {
        uint256 shares = _deposit(alice, 0, 10_000e6);
        assertEq(vault.maxRedeem(alice), shares);
    }

    /// @notice 空用户maxWithdraw为0
    function test_MaxWithdraw_EmptyUser() public {
        assertEq(vault.maxWithdraw(bob), 0);
    }

    /// @notice 空用户maxRedeem为0
    function test_MaxRedeem_EmptyUser() public {
        assertEq(vault.maxRedeem(bob), 0);
    }
}
