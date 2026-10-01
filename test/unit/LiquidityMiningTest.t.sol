// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";
import {FullMath} from "../../src/libraries/UniswapMath.sol";

contract LiquidityMiningTest is BaseTest {

    function setUp() public override {
        super.setUp();
    }

    // ============ startMining ============

    // 测试正常开始挖矿和重复开始挖矿 revert
    function test_StartMining_AlreadyStarted() public {
        assertEq(mining.startTime(), 0);
        mining.startMining();
        assertEq(mining.startTime(), block.timestamp);
        assertEq(mining.lastUpdateTime(), block.timestamp);

        vm.expectRevert(bytes("LiquidityMining: already started"));
        mining.startMining();
    }

    // ============ currentRewardPerSecond ============

    // 测试未开始时返回 0
    function test_CurrentRewardPerSecond_NotStarted() public {
        assertEq(mining.currentRewardPerSecond(), 0);
    }

    // 测试第一年的释放速率
    function test_CurrentRewardPerSecond_FirstYear() public {
        mining.startMining();

        uint256 expected = uint256(2500000 * 1e18) / 365 days;
        assertEq(mining.currentRewardPerSecond(), expected);
    }

    // 测试减半后的释放速率（1年后）
    function test_CurrentRewardPerSecond_AfterHalving() public {
        mining.startMining();
        uint256 firstYear = mining.currentRewardPerSecond();

        skip(365 days + 1);
        uint256 secondYear = mining.currentRewardPerSecond();
        assertEq(secondYear, firstYear / 2);
    }

    // ============ updateBalance ============

    // 测试非 vault 调用 revert
    function test_Revert_UpdateBalance_NotVault() public {
        mining.startMining();

        vm.prank(alice);
        vm.expectRevert(bytes("LiquidityMining: not vault"));
        mining.updateBalance(alice, 100e18);
    }

    // 测试份额增加时自动结算奖励，奖励金额精确匹配计算
    function test_UpdateBalance_AutoSettleOnIncrease() public {
        mining.startMining();

        vm.prank(address(vault));
        mining.updateBalance(alice, 100e18);

        assertEq(mining.balanceOf(alice), 100e18);
        assertEq(mining.totalShares(), 100e18);

        uint256 oldUserDebt = mining.rewardDebt(alice);
        uint256 oldGlobalRps = mining.rewardPerShare();

        skip(1 days);

        uint256 timeDelta = 1 days;
        uint256 rewardPerSecond = mining.currentRewardPerSecond();
        assertEq(rewardPerSecond, mining.INITIAL_RPS());

        uint256 totalReward = timeDelta * rewardPerSecond;
        uint256 expectedNewRps = oldGlobalRps + FullMath.mulDiv(totalReward, 1e18, mining.totalShares());

        uint256 aliceShare = mining.balanceOf(alice);
        uint256 expectedPending = FullMath.mulDiv(aliceShare, expectedNewRps - oldUserDebt, 1e18);
        uint256 balanceBefore = govToken.balanceOf(alice);

        vm.prank(address(vault));
        mining.updateBalance(alice, 200e18);
        uint256 balanceAfter = govToken.balanceOf(alice);

        assertEq(balanceAfter - balanceBefore, expectedPending);
        assertEq(mining.balanceOf(alice), 200e18);
        assertEq(mining.totalShares(), 200e18);
        assertEq(mining.pendingReward(alice), 0);
    }

    // 测试份额减少为 0 时自动结算，奖励金额精确匹配计算
    function test_UpdateBalance_AutoSettleOnWithdraw() public {
        mining.startMining();
        vm.prank(address(vault));
        mining.updateBalance(alice, 100e18);

        uint256 oldUserDebt = mining.rewardDebt(alice);
        uint256 oldGlobalRps = mining.rewardPerShare();

        skip(1 days);

        uint256 timeDelta = 1 days;
        uint256 rewardPerSecond = mining.currentRewardPerSecond();

        uint256 totalReward = timeDelta * rewardPerSecond;
        uint256 expectedNewRps = oldGlobalRps + FullMath.mulDiv(totalReward, 1e18, mining.totalShares());
        
        uint256 aliceShare = mining.balanceOf(alice);
        uint256 expectedPending = FullMath.mulDiv(aliceShare, expectedNewRps - oldUserDebt, 1e18);

        uint256 balanceBefore = govToken.balanceOf(alice);

        vm.prank(address(vault));
        mining.updateBalance(alice, 0);
        uint256 balanceAfter = govToken.balanceOf(alice);

        assertEq(balanceAfter - balanceBefore, expectedPending);
        assertEq(mining.balanceOf(alice), 0);
        assertEq(mining.totalShares(), 0);
        assertEq(mining.pendingReward(alice), 0);
    }

    // 测试正常领取奖励
    function test_ClaimReward_Normal() public {
        mining.startMining();

        vm.prank(address(vault));
        mining.updateBalance(alice, 100e18);

        skip(1 days);
        uint256 pending = mining.pendingReward(alice);

        assertGt(pending, 0);
        uint256 balanceBefore = govToken.balanceOf(alice);

        vm.prank(alice);
        mining.claimReward();
        
        uint256 balanceAfter = govToken.balanceOf(alice);
        assertEq(balanceAfter - balanceBefore, pending);
        assertEq(mining.pendingReward(alice), 0);
    }

    // 测试无奖励时领取 revert
    function test_Revert_ClaimReward_NoRewards() public {
        mining.startMining();
        vm.prank(alice);
        vm.expectRevert(bytes("LiquidityMining: no rewards"));
        mining.claimReward();
    }

    // ============ pendingReward ============

    // 测试查询待领奖励为 0
    function test_PendingReward_Zero() public {
        mining.startMining();
        assertEq(mining.pendingReward(alice), 0);
    }

    // 测试查询待领奖励随时间增长
    function test_PendingReward_IncreasesOverTime() public {
        mining.startMining();

        vm.prank(address(vault));
        mining.updateBalance(alice, 100e18);
        uint256 pending1 = mining.pendingReward(alice);

        skip(1 days);
        uint256 pending2 = mining.pendingReward(alice);
        assertGt(pending2, pending1);
    }

    // ============ distribute ============

    // 测试任何人可调用 distribute
    function test_Distribute_AnyoneCanCall() public {
        mining.startMining();

        vm.prank(address(vault));
        mining.updateBalance(alice, 100e18);

        skip(1 days);
        uint256 rpsBefore = mining.rewardPerShare();
        
        vm.prank(bob);
        mining.distribute();
        uint256 rpsAfter = mining.rewardPerShare();
        assertGt(rpsAfter, rpsBefore);
    }
}
