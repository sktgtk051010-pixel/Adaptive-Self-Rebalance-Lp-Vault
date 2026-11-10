// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {GovernanceToken} from "../../src/governance/AdaptiveGovernance.sol";

/// @notice 回归测试：minter 未经 allowance 不能销毁他人余额（F-01 已修复）
/// @dev 修复前为缺陷型 PoC；修复后断言反转，通过即修复生效
contract POC_BurnWithoutAllowance is Test {
    GovernanceToken token;
    address victim = address(0xBEEF);

    function setUp() public {
        token = new GovernanceToken();
    }

    function test_MinterCannotBurnWithoutAllowance() public {
        token.mint(victim, 1_000e18);

        assertEq(token.balanceOf(victim), 1_000e18);
        assertEq(token.allowance(victim, address(this)), 0);

        vm.expectRevert();
        token.burn(victim, 1_000e18); // 未授权销毁应 revert

        console2.log("victim balance after rejected burn:", token.balanceOf(victim));

        assertEq(token.balanceOf(victim), 1_000e18, "balance must stay");
    }
}
