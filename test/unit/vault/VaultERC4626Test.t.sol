// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../../base/BaseTest.t.sol";

contract VaultERC4626Test is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // 测试asset()返回USDC地址（金库记账资产为USDC）
    function test_Asset_ReturnsUSDC() public view {
        assertEq(vault.asset(), address(usdc));
    }

    // 测试totalAssets重写：空金库为0，存款后等于存入USDC金额
    function test_TotalAssets_Override() public {
        assertEq(vault.totalAssets(), 0);
        _deposit(alice, 0, 1_000e6);
        assertEq(vault.totalAssets(), 1_000e6);
    }

    // 测试空金库时convertToShares按1:1转换（无溢价/折价）
    function test_ConvertToShares_ZeroSupply() public view {
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.convertToShares(1000e6), 1000e6);
    }

    // 测试存款后convertToShares与实际铸造的份额一致
    function test_ConvertToShares_Proportional() public {
        uint256 shares = _deposit(alice, 0, 10_000e6);

        assertEq(shares, 10_000e6);
        assertEq(vault.convertToShares(10_000e6), shares);
    }

    // 测试空金库时convertToAssets按1:1转换
    function test_ConvertToAssets_ZeroSupply() public view {
        assertEq(vault.convertToAssets(1000), 1000);
    }

    // 测试存款后convertToAssets返回值与totalAssets一致（1:1锚定）
    function test_ConvertToAssets_Proportional() public {
        _deposit(alice, 0, 10_000e6);

        assertEq(vault.totalAssets(), 10_000e6);
        assertEq(vault.convertToAssets(10_000e6), 10_000e6);
    }

    // 测试previewDeposit预测的份额与实际存款铸造的份额一致
    function test_PreviewDeposit_MatchesActual() public {
        uint256 shares = _deposit(bob, 0, 5_000e6);
        uint256 previewShares = vault.previewDeposit(5000e6);

        assertEq(shares, previewShares);
    }

    // 测试previewMint预测的资产量与实际mint消耗的资产量一致
    function test_PreviewMint_MatchesActual() public {
        _deposit(alice, 0, 10_000e6);

        uint256 sharesToMint = vault.totalSupply() / 2;
        uint256 previewAssets = vault.previewMint(sharesToMint);

        vm.prank(bob);
        uint256 actualAssets = vault.mint(sharesToMint, bob);

        assertEq(actualAssets, previewAssets);
    }

    // 测试previewWithdraw预测的份额与实际withdraw销毁的份额一致
    function test_PreviewWithdraw_MatchesActual() public {
        uint256 shares = _deposit(alice, 0, 10_000e6);

        uint256 assetsToWithdraw = 2_500e6;
        uint256 previewShares = vault.previewWithdraw(assetsToWithdraw);

        vm.prank(alice);
        uint256 actualShares = vault.withdraw(assetsToWithdraw, alice, alice);

        assertEq(actualShares, previewShares);
    }

    // 测试previewRedeem预测的资产量与实际redeem收到的资产量一致
    function test_PreviewRedeem_MatchesActual() public {
        uint256 shares = _deposit(alice, 0, 10_000e6);
        uint256 sharesToRedeem = shares / 2;

        uint256 previewAssets = vault.previewRedeem(sharesToRedeem);

        vm.startPrank(alice);
        uint256 actualAssets = vault.redeem(sharesToRedeem, alice, alice);

        assertEq(actualAssets, previewAssets);
    }

    // 测试maxDeposit返回uint256最大值（无存款上限）
    function test_MaxDeposit_ReturnsMax() public view {
        assertEq(vault.maxDeposit(alice), type(uint256).max);
    }

    // 测试maxMint返回uint256最大值（无mint上限）
    function test_MaxMint_ReturnsMax() public view {
        assertEq(vault.maxMint(alice), type(uint256).max);
    }

    // 测试maxWithdraw返回用户持有份额对应的资产量
    function test_MaxWithdraw_ReturnsUserAssets() public {
        uint256 shares = _deposit(alice, 0, 10_000e6);
        uint256 maxWithdraw = vault.maxWithdraw(alice);

        assertEq(maxWithdraw, vault.convertToAssets(shares));
    }

    // 测试maxRedeem返回用户实际持有的份额数量
    function test_MaxRedeem_ReturnsUserShares() public {
        uint256 shares = _deposit(alice, 0, 10_000e6);
        assertEq(vault.maxRedeem(alice), shares);
    }

    // 测试未存款用户的maxWithdraw返回0
    function test_MaxWithdraw_EmptyUser() public view {
        assertEq(vault.maxWithdraw(bob), 0);
    }

    // 测试未存款用户的maxRedeem返回0
    function test_MaxRedeem_EmptyUser() public view {
        assertEq(vault.maxRedeem(bob), 0);
    }
}
