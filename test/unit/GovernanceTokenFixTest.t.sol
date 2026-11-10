// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GovernanceToken} from "../../src/governance/AdaptiveGovernance.sol";

/// @notice F-01/F-02 修复回归测试：未授权 burn、零地址 setMinter 均应 revert
contract GovernanceTokenFixTest is Test {
    GovernanceToken token;
    address victim = address(0xBEEF);

    function setUp() public {
        token = new GovernanceToken();
    }

    // 测试未授权时 minter 不能销毁他人余额
    function test_Burn_RevertsWithoutAllowance() public {
        token.mint(victim, 1_000e18);
        vm.expectRevert();
        token.burn(victim, 1_000e18);
        assertEq(token.balanceOf(victim), 1_000e18, "balance unchanged");
    }

    // 测试授权后 minter 可以销毁
    function test_Burn_SucceedsWithAllowance() public {
        token.mint(victim, 1_000e18);
        vm.prank(victim);
        token.approve(address(this), 1_000e18);

        token.burn(victim, 1_000e18);
        assertEq(token.balanceOf(victim), 0);
    }

    // 测试 setMinter 拒绝零地址
    function test_SetMinter_RevertsOnZero() public {
        vm.expectRevert(bytes("GovToken: zero minter"));
        token.setMinter(address(0));
        assertEq(token.minter(), address(this));
    }

    // 测试 setMinter 正常切换到有效地址
    function test_SetMinter_SucceedsToValidAddress() public {
        token.setMinter(address(0xCAFE));
        assertEq(token.minter(), address(0xCAFE));
    }
}
