// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../../base/BaseTest.t.sol";
import {AdaptiveLPVault} from "../../../src/vault/AdaptiveLPVault.sol";

contract VaultAdminTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // 测试owner设置三个适配器地址后均正确更新
    function test_SetAdapters_AllThree() public {
        vault.setAdapters(address(v2Adapter), address(v3LowAdapter), address(v3HighAdapter));
        assertEq(address(vault.v2Adapter()), address(v2Adapter));
        assertEq(address(vault.v3LowFeeAdapter()), address(v3LowAdapter));
        assertEq(address(vault.v3HighFeeAdapter()), address(v3HighAdapter));
    }

    // 测试传入address(0)时跳过该适配器的更新（保留原值）
    function test_SetAdapters_ZeroAddressSkipped() public {
        address originalV2 = address(vault.v2Adapter());
        address originalV3Low = address(vault.v3LowFeeAdapter());
        address originalV3High = address(vault.v3HighFeeAdapter());
        vault.setAdapters(address(0), address(0), address(0));
        assertEq(address(vault.v2Adapter()), originalV2, "zero v2Address should skip");
        assertEq(address(vault.v3LowFeeAdapter()), originalV3Low, "zero v3LowAddress should skip");
        assertEq(address(vault.v3HighFeeAdapter()), originalV3High, "zero v3HighAddress should skip");
    }

    // 测试设置适配器时正确触发AdapterUpdated事件（三个适配器各触发一次）
    function test_SetAdapters_EmitEvent() public {
        vm.expectEmit(true, false, false, true);
        emit AdaptiveLPVault.AdapterUpdated(address(v2Adapter), 0);

        vm.expectEmit(true, false, false, true);
        emit AdaptiveLPVault.AdapterUpdated(address(v3LowAdapter), 1);

        vm.expectEmit(true, false, false, true);
        emit AdaptiveLPVault.AdapterUpdated(address(v3HighAdapter), 2);

        vault.setAdapters(address(v2Adapter), address(v3LowAdapter), address(v3HighAdapter));
    }

    // 测试非owner调用setAdapters时revert
    function test_Revert_SetAdapters_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.setAdapters(address(v2Adapter), address(v3LowAdapter), address(v3HighAdapter));
        vm.stopPrank();
    }

    // 测试设置最大滑点为0时成功（允许无滑点保护）
    function test_SetMaxSlippage_Zero() public {
        vault.setMaxSlippage(0);
        assertEq(vault.maxSlippageBps(), 0);
    }

    // 测试设置最大滑点为上限500bps(5%)时成功
    function test_SetMaxSlippage_Max500() public {
        vault.setMaxSlippage(500);
        assertEq(vault.maxSlippageBps(), 500);
    }

    // 测试设置最大滑点超过500bps时revert
    function test_Revert_SetMaxSlippage_Above500() public {
        vm.expectRevert(bytes("Vault: slippage too high"));
        vault.setMaxSlippage(501);
    }

    // 测试设置最大滑点时触发SlippageUpdated事件
    function test_SetMaxSlippage_EmitEvent() public {
        uint256 oldBps = vault.maxSlippageBps();
        vm.expectEmit(false, false, false, true);
        emit AdaptiveLPVault.SlippageUpdated(oldBps, 300);

        vault.setMaxSlippage(300);
    }

    // 测试非owner调用setMaxSlippage时revert
    function test_Revert_SetMaxSlippage_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setMaxSlippage(300);
    }

    // 测试暂停/取消暂停状态切换正常
    function test_SetPaused_TrueFalse() public {
        assertFalse(vault.paused());
        vault.setPaused(true);
        assertTrue(vault.paused());
        vault.setPaused(false);
        assertFalse(vault.paused());
    }

    // 测试设置暂停时触发PausedStateChanged事件
    function test_SetPaused_EmitEvent() public {
        vm.expectEmit(false, false, false, true);
        emit AdaptiveLPVault.PausedStateChanged(true);

        vault.setPaused(true);
    }

    // 测试非owner调用setPaused时revert
    function test_Revert_SetPaused_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.setPaused(true);
        vm.stopPrank();
    }

    // 测试owner设置激励合约地址成功
    function test_SetIncentives_Valid() public {
        vault.setIncentives(address(incentives));
        assertEq(address(vault.incentives()), address(incentives));
    }

    // 测试设置激励合约为address(0)成功（允许禁用激励）
    function test_SetIncentives_Zero() public {
        vault.setIncentives(address(0));
        assertEq(address(vault.incentives()), address(0));
    }

    // 测试非owner调用setIncentives时revert
    function test_Revert_SetIncentives_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.setIncentives(address(incentives));
        vm.stopPrank();
    }

    // 测试owner设置治理合约地址成功
    function test_SetGovernance_Valid() public {
        vault.setGovernance(address(governance));
        assertEq(address(vault.governance()), address(governance));
    }

    // 测试非owner调用setGovernance时revert
    function test_Revert_SetGovernance_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.setGovernance(address(governance));
        vm.stopPrank();
    }

    // 测试构造函数USDC地址为0时revert
    function test_Revert_Constructor_ZeroUSDC() public {
        vm.expectRevert(bytes("Vault: zero USDC"));
        new AdaptiveLPVault(
            address(0), address(weth), address(oracle), address(strategy),
            address(governance), "Test", "TEST"
        );
    }

    // 测试构造函数WETH地址为0时revert
    function test_Revert_Constructor_ZeroWETH() public {
        vm.expectRevert(bytes("Vault: zero WETH"));
        new AdaptiveLPVault(
            address(usdc), address(0), address(oracle), address(strategy),
            address(governance), "Test", "TEST"
        );
    }

    // 测试构造函数oracle地址为0时revert
    function test_Revert_Constructor_ZeroOracle() public {
        vm.expectRevert(bytes("Vault: zero oracle"));
        new AdaptiveLPVault(
            address(usdc), address(weth), address(0), address(strategy),
            address(governance), "Test", "TEST"
        );
    }

    // 测试构造函数strategy地址为0时revert
    function test_Revert_Constructor_ZeroStrategy() public {
        vm.expectRevert(bytes("Vault: zero strategy"));
        new AdaptiveLPVault(
            address(usdc), address(weth), address(oracle), address(0),
            address(governance), "Test", "TEST"
        );
    }

    // 测试构造函数governance地址为0时revert
    function test_Revert_Constructor_ZeroGovernance() public {
        vm.expectRevert(bytes("Vault: zero governance"));
        new AdaptiveLPVault(
            address(usdc), address(weth), address(oracle), address(strategy),
            address(0), "Test", "TEST"
        );
    }
}
