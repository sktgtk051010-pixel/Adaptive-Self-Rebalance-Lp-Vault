// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";

/**
 * @title MultiUserTest
 * @notice 多用户交互集成测试
 */
contract MultiUserTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    /// @notice 顺序存款不稀释
    function test_SequentialDeposits_NoDilution() public {
        uint256 sharesA = _deposit(alice, 10 ether, 20_000e6);
        uint256 assetsPerShareA = vault.totalAssets() * 1e18 / sharesA;

        uint256 sharesB = _deposit(bob, 10 ether, 20_000e6);
        uint256 assetsPerShareB = vault.totalAssets() * 1e18 / vault.totalSupply();

        assertApproxEqRel(assetsPerShareB, assetsPerShareA, 0.01e18, "no dilution");
        assertApproxEqRel(sharesB, sharesA, 0.01e18, "same deposit = same shares");
    }

    /// @notice Alice赎回不影响Bob
    function test_AliceWithdraw_BobUnaffected() public {
        uint256 sharesA = _deposit(alice, 10 ether, 20_000e6);
        uint256 sharesB = _deposit(bob, 10 ether, 20_000e6);

        vault.rebalance();

        uint256 bobAssetsBefore = vault.convertToAssets(sharesB);

        vm.startPrank(alice);
        vault.withdrawDual(sharesA, 0, 0);
        vm.stopPrank();

        uint256 bobAssetsAfter = vault.convertToAssets(sharesB);
        assertApproxEqRel(bobAssetsAfter, bobAssetsBefore, 0.05e18, "Bob unaffected");
        assertEq(vault.balanceOf(bob), sharesB);
    }

    /// @notice 所有用户退出后vault清空
    function test_AllExit_EmptyVault() public {
        uint256 sharesA = _deposit(alice, 5 ether, 10_000e6);
        uint256 sharesB = _deposit(bob, 5 ether, 10_000e6);
        uint256 sharesC = _deposit(charlie, 5 ether, 10_000e6);

        vault.rebalance();

        vm.startPrank(alice);
        vault.withdrawDual(sharesA, 0, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.withdrawDual(sharesB, 0, 0);
        vm.stopPrank();

        vm.startPrank(charlie);
        vault.withdrawDual(sharesC, 0, 0);
        vm.stopPrank();

        assertEq(vault.totalSupply(), 0);
        (uint256 totalW, uint256 totalU) = _getTotalUnderlying();
        // 可能有少量dust
        assertLe(totalW, 1000, "WETH should be ~0");
        assertLe(totalU, 1000, "USDC should be ~0");
    }

    /// @notice 冷却期内仍可存款
    function test_DepositDuringCooldown() public {
        _deposit(alice, 20 ether, 40_000e6);
        vault.rebalance();

        // 冷却期内（<600s）不能再平衡，但可以存款
        vm.expectRevert();
        vault.rebalance();

        uint256 supplyBefore = vault.totalSupply();
        _deposit(bob, 10 ether, 20_000e6);

        assertGt(vault.totalSupply(), supplyBefore, "deposit should work during cooldown");
    }

    /// @notice 部分赎回后剩余用户份额价值不变
    function test_PartialWithdraw_RemainingUsersStable() public {
        uint256 sharesA = _deposit(alice, 30 ether, 60_000e6);
        uint256 sharesB = _deposit(bob, 10 ether, 20_000e6);

        vault.rebalance();

        uint256 bobValueBefore = vault.convertToAssets(sharesB);

        // Alice赎回一半
        vm.startPrank(alice);
        vault.withdrawDual(sharesA / 2, 0, 0);
        vm.stopPrank();

        uint256 bobValueAfter = vault.convertToAssets(sharesB);
        assertApproxEqRel(bobValueAfter, bobValueBefore, 0.05e18, "Bob value stable");
    }
}
