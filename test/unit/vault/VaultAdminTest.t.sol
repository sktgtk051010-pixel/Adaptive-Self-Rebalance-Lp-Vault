// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../../base/BaseTest.t.sol";
import {AdaptiveLPVault} from "../../../src/vault/AdaptiveLPVault.sol";

contract VaultAdminTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    function test_SetAdapters_AllThree() public {
        vault.setAdapters(address(v2Adapter), address(v3LowAdapter), address(v3HighAdapter));
        assertEq(address(vault.v2Adapter()), address(v2Adapter));
        assertEq(address(vault.v3LowFeeAdapter()), address(v3LowAdapter));
        assertEq(address(vault.v3HighFeeAdapter()), address(v3HighAdapter));
    }

    function test_SetAdapters_ZeroAddressSkipped() public {
        address originalV2 = address(vault.v2Adapter());
        address originalV3Low = address(vault.v3LowFeeAdapter());
        address originalV3High = address(vault.v3HighFeeAdapter());
        vault.setAdapters(address(0), address(0), address(0));
        assertEq(address(vault.v2Adapter()), originalV2, "zero v2Address should skip");
        assertEq(address(vault.v3LowFeeAdapter()), originalV3Low, "zero v3LowAddress should skip");
        assertEq(address(vault.v3HighFeeAdapter()), originalV3High, "zero v3HighAddress should skip");
    }

    function test_SetAdapters_EmitEvent() public {
        vm.expectEmit(true, false, false, true);
        emit AdaptiveLPVault.AdapterUpdated(address(v2Adapter), 0);

        vm.expectEmit(true, false, false, true);
        emit AdaptiveLPVault.AdapterUpdated(address(v3LowAdapter), 1);

        vm.expectEmit(true, false, false, true);
        emit AdaptiveLPVault.AdapterUpdated(address(v3HighAdapter), 2);

        vault.setAdapters(address(v2Adapter), address(v3LowAdapter), address(v3HighAdapter));
    }

    function test_Revert_SetAdapters_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.setAdapters(address(v2Adapter), address(v3LowAdapter), address(v3HighAdapter));
        vm.stopPrank();
    }

    function test_SetMaxSlippage_Zero() public {
        vault.setMaxSlippage(0);
        assertEq(vault.maxSlippageBps(), 0);
    }

    function test_SetMaxSlippage_Max500() public {
        vault.setMaxSlippage(500);
        assertEq(vault.maxSlippageBps(), 500);
    }

    function test_Revert_SetMaxSlippage_Above500() public {
        vm.expectRevert(bytes("Vault: slippage too high"));
        vault.setMaxSlippage(501);
    }

    function test_SetMaxSlippage_EmitEvent() public {
        uint256 oldBps = vault.maxSlippageBps();
        vm.expectEmit(false, false, false, true);
        emit AdaptiveLPVault.SlippageUpdated(oldBps, 300);

        vault.setMaxSlippage(300);
    }

    function test_Revert_SetMaxSlippage_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setMaxSlippage(300);
    }

    function test_SetPaused_TrueFalse() public {
        assertFalse(vault.paused());
        vault.setPaused(true);
        assertTrue(vault.paused());
        vault.setPaused(false);
        assertFalse(vault.paused());
    }

    function test_SetPaused_EmitEvent() public {
        vm.expectEmit(false, false, false, true);
        emit AdaptiveLPVault.PausedStateChanged(true);

        vault.setPaused(true);
    }

    function test_Revert_SetPaused_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.setPaused(true);
        vm.stopPrank();
    }

    function test_SetIncentives_Valid() public {
        vault.setIncentives(address(incentives));
        assertEq(address(vault.incentives()), address(incentives));
    }

    function test_SetIncentives_Zero() public {
        vault.setIncentives(address(0));
        assertEq(address(vault.incentives()), address(0));
    }

    function test_Revert_SetIncentives_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.setIncentives(address(incentives));
        vm.stopPrank();
    }

    function test_SetGovernance_Valid() public {
        vault.setGovernance(address(governance));
        assertEq(address(vault.governance()), address(governance));
    }

    function test_Revert_SetGovernance_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.setGovernance(address(governance));
        vm.stopPrank();
    }

    function test_Revert_Constructor_ZeroUSDC() public {
        vm.expectRevert(bytes("Vault: zero USDC"));
        new AdaptiveLPVault(
            address(0), address(weth), address(oracle), address(strategy),
            address(governance), "Test", "TEST"
        );
    }

    function test_Revert_Constructor_ZeroWETH() public {
        vm.expectRevert(bytes("Vault: zero WETH"));
        new AdaptiveLPVault(
            address(usdc), address(0), address(oracle), address(strategy),
            address(governance), "Test", "TEST"
        );
    }

    function test_Revert_Constructor_ZeroOracle() public {
        vm.expectRevert(bytes("Vault: zero oracle"));
        new AdaptiveLPVault(
            address(usdc), address(weth), address(0), address(strategy),
            address(governance), "Test", "TEST"
        );
    }

    function test_Revert_Constructor_ZeroStrategy() public {
        vm.expectRevert(bytes("Vault: zero strategy"));
        new AdaptiveLPVault(
            address(usdc), address(weth), address(oracle), address(0),
            address(governance), "Test", "TEST"
        );
    }

    function test_Revert_Constructor_ZeroGovernance() public {
        vm.expectRevert(bytes("Vault: zero governance"));
        new AdaptiveLPVault(
            address(usdc), address(weth), address(oracle), address(strategy),
            address(0), "Test", "TEST"
        );
    }
}
