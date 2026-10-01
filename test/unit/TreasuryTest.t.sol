// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";
import {Treasury} from "../../src/distribution/Treasury.sol";
import {GovernanceToken} from "../../src/governance/AdaptiveGovernance.sol";

contract TreasuryTest is BaseTest {

    function setUp() public override {
        super.setUp();
        // BaseTest 只给国库注入了 ALP，这里补注 USDC 供双币支出测试
        usdc.mint(address(treasury), 10_000e6);
    }

    // ============ spend ============

    // 测试 owner 正常支出 ALP 和 USDC
    function test_Spend_ALP_USDC() public {
        uint256 amountALP = 100e18;
        uint256 amountUSDC = 1000e6;

        assertEq(treasury.getSpendingCount(), 0);

        uint256 balanceBeforeALP = govToken.balanceOf(bob);
        uint256 balanceBeforeUSDC = usdc.balanceOf(bob);

        treasury.spend(address(govToken), bob, amountALP, "test spending");
        treasury.spend(address(usdc), bob, amountUSDC, "usdc spending");

        uint256 balanceAfterALP = govToken.balanceOf(bob);
        uint256 balanceAfterUSDC = usdc.balanceOf(bob);

        assertEq(balanceAfterALP - balanceBeforeALP, 100e18);
        assertEq(balanceAfterUSDC - balanceBeforeUSDC, 1000e6);
        assertEq(treasury.getSpendingCount(), 2);
    }

    // 测试非 owner 调用 revert
    function test_Revert_Spend_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        treasury.spend(address(govToken), bob, 100e18, "test");
    }

    // 测试零地址接收方 revert
    function test_Revert_Spend_ZeroAddress() public {
        vm.expectRevert(bytes("Treasury: zero address"));
        treasury.spend(address(govToken), address(0), 100e18, "test");
    }

    // 测试零金额 revert
    function test_Revert_Spend_ZeroAmount() public {
        vm.expectRevert(bytes("Treasury: zero amount"));
        treasury.spend(address(govToken), bob, 0, "test");
    }

    // ============ balanceOf ============

    // 测试查询 ALP 余额 和 USDC 余额
    function test_BalanceOf_ALP_USDC() public {
        uint256 alpBalance = treasury.balanceOf(address(govToken));
        uint256 usdcBalance = treasury.balanceOf(address(usdc));
        assertEq(alpBalance, 2_000_000e18);
        assertEq(usdcBalance, 10_000e6);
    }

    // ============ getSpending ============

    // 测试查询支出记录详情
    function test_GetSpending_Details() public {
        treasury.spend(address(govToken), bob, 100e18, "test reason");
        (address token, address to, uint256 amount, string memory reason, uint256 timestamp) = treasury.getSpending(0);
        assertEq(token, address(govToken));
        assertEq(to, bob);
        assertEq(amount, 100e18);
        assertEq(reason, "test reason");
        assertEq(timestamp, block.timestamp);
    }

    // ============ ownership ============

    // 测试转移所有权后新 owner 可以支出
    function test_TransferOwnership_NewOwnerCanSpend() public {
        treasury.transferOwnership(alice);
        vm.prank(alice);
        treasury.spend(address(govToken), bob, 100e18, "new owner spend");
        assertEq(treasury.getSpendingCount(), 1);
    }

    // 测试转移所有权后旧 owner 不能支出
    function test_Revert_TransferOwnership_OldOwnerCannotSpend() public {
        treasury.transferOwnership(alice);
        vm.expectRevert();
        treasury.spend(address(govToken), bob, 100e18, "old owner");
    }

    // 测试查询越界支出记录时 revert
    function test_Revert_GetSpending_OutOfBounds() public {
        vm.expectRevert(bytes("Treasury: index out of bounds"));
        treasury.getSpending(0);
    }
}
