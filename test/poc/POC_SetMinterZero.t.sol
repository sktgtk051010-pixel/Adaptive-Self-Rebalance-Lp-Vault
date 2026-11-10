// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {GovernanceToken} from "../../src/governance/AdaptiveGovernance.sol";

/// @notice 回归测试：setMinter 拒绝零地址（F-02 已修复）
/// @dev 修复前为缺陷型 PoC；修复后通过即修复生效
contract POC_SetMinterZero is Test {
    GovernanceToken token;

    function setUp() public {
        token = new GovernanceToken();
    }

    function test_SetMinterZeroReverts() public {
        token.mint(address(0xCAFE), 1e18);
        assertEq(token.minter(), address(this));

        vm.expectRevert(bytes("GovToken: zero minter"));
        token.setMinter(address(0)); // 零地址应 revert
        assertEq(token.minter(), address(this));

        token.setMinter(address(0xCAFE));
        assertEq(token.minter(), address(0xCAFE));

        console2.log("minter after valid setMinter:", token.minter());
    }
}
