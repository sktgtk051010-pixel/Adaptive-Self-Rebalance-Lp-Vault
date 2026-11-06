// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {GovernanceToken} from "../../src/governance/AdaptiveGovernance.sol";

/// @notice PoC：setMinter 传入零地址后 minter 通道永久锁死（F-02）
/// @dev 断言方向为"证明缺陷存在"；修复后 setMinter(address(0)) 应 revert
contract POC_SetMinterZero is Test {
    GovernanceToken token;

    function setUp() public {
        token = new GovernanceToken();
    }

    function test_SetMinterZeroLocksChannelForever() public {
        token.mint(address(0xCAFE), 1e18);
        assertEq(token.minter(), address(this));

        token.setMinter(address(0));//minter设为0
        assertEq(token.minter(), address(0));

        vm.expectRevert("GovToken: not minter");
        token.setMinter(address(this));

        vm.expectRevert("GovToken: not minter");
        token.mint(address(0xCAFE), 1e18);

        console2.log("minter after setMinter(0):", token.minter());
    }
}
