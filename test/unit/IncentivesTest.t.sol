// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";
import {RebalanceIncentives} from "../../src/incentives/RebalanceIncentives.sol";

contract IncentivesTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    function test_OnRebalanceExecuted_RewardCalculation() public {
        uint256 before = 1000e6;
        uint256 afterValue = 1200e6;

        vm.prank(address(vault));
        uint256 reward = incentives.onRebalanceExecuted(alice, before, afterValue);

        assertEq(reward, 10e6);
        assertEq(incentives.pendingReward(alice), 10e6);
    }

    function test_OnRebalanceExecuted_RewardCappedByBalance() public {
        uint256 balance = usdc.balanceOf(address(incentives));
        uint256 before = 0;
        uint256 afterValue = 10_000_000e6;

        vm.prank(address(vault));
        uint256 reward = incentives.onRebalanceExecuted(alice, before, afterValue);

        assertLe(reward, balance);
    }

    function test_Revert_OnRebalanceExecuted_NotVault() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Incentives: not vault"));
        incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);
    }

    function test_Revert_OnRebalanceExecuted_NoProfit() public {
        vm.prank(address(vault));
        vm.expectRevert(bytes("Incentives: not profitable"));
        incentives.onRebalanceExecuted(alice, 1100e6, 1000e6);
    }

    function test_Revert_OnRebalanceExecuted_BelowMinProfit() public {
        vm.prank(address(vault));
        vm.expectRevert(bytes("Incentives: profit too small"));
        incentives.onRebalanceExecuted(alice, 1000e6, 1000500000);
    }

    function test_Revert_OnRebalanceExecuted_Cooldown() public {
        vm.prank(address(vault));
        uint256 reward = incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);
        assertEq(reward, 5e6);

        vm.prank(address(vault));
        vm.expectRevert(bytes("Incentives: cooldown active"));
        incentives.onRebalanceExecuted(bob, 1000e6, 1100e6);
    }

    function test_OnRebalanceExecuted_AfterCooldown() public {
        vm.prank(address(vault));
        uint256 rewardA = incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);
        assertEq(rewardA, 5e6);

        skip(301);
        vm.prank(address(vault));
        uint256 rewardB = incentives.onRebalanceExecuted(bob, 1000e6, 1100e6);
        assertGt(rewardB, 0);
    }

    function test_ClaimReward_TransfersTokens() public {
        vm.prank(address(vault));
        incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);

        uint256 pending = incentives.pendingReward(alice);
        uint256 balanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        incentives.claimReward();

        assertEq(usdc.balanceOf(alice), balanceBefore + pending);
        assertEq(incentives.pendingReward(alice), 0);
    }

    function test_Revert_ClaimReward_ZeroBalance() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Incentives: no rewards"));
        incentives.claimReward();
    }

    function test_PendingReward_MatchesAccumulated() public {
        vm.prank(address(vault));
        incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);
        skip(301);
        vm.prank(address(vault));
        incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);

        assertEq(incentives.pendingReward(alice), 10e6);
    }

    function test_CanRebalance_FirstTimeTrue() public view {
        assertTrue(incentives.canRebalance());
    }

    function test_CanRebalance_CooldownFalse() public {
        vm.prank(address(vault));
        incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);
        assertFalse(incentives.canRebalance());
    }

    function test_SetIncentiveBps_UpperLimit() public {
        incentives.setIncentiveBps(2000);
        assertEq(incentives.incentiveBps(), 2000);
    }

    function test_Revert_SetIncentiveBps_TooHigh() public {
        vm.expectRevert(bytes("Incentives: too high"));
        incentives.setIncentiveBps(2001);
    }

    function test_SetCooldownPeriod_Range() public {
        incentives.setCooldownPeriod(600);
        assertEq(incentives.cooldownPeriod(), 600);
    }

    function test_Revert_SetCooldownPeriod_TooSmall() public {
        vm.expectRevert(bytes("Incentives: invalid cooldown"));
        incentives.setCooldownPeriod(30);
    }

    function test_Revert_SetIncentiveBps_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        incentives.setIncentiveBps(1000);
    }

    function test_FundRewards_ByGovernance() public {
        uint256 amount = 1000e6;
        uint256 balanceBefore = usdc.balanceOf(address(incentives));
        usdc.mint(address(governance), amount);

        vm.startPrank(address(governance));
        usdc.approve(address(incentives), amount);
        incentives.fundRewards(amount);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(incentives)), balanceBefore + amount);
    }

    function test_FundRewards_ByVault() public {
        uint256 amount = 1000e6;
        uint256 balanceBefore = usdc.balanceOf(address(incentives));
        usdc.mint(address(vault), amount);

        vm.startPrank(address(vault));
        usdc.approve(address(incentives), amount);
        incentives.fundRewards(amount);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(incentives)), balanceBefore + amount);
    }

    function test_Revert_FundRewards_ZeroAmount() public {
        vm.prank(address(governance));
        vm.expectRevert(bytes("Incentives: zero amount"));
        incentives.fundRewards(0);
    }

    function test_Revert_FundRewards_NotAuthorized() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Incentives: not authorized"));
        incentives.fundRewards(100e6);
    }

    function test_SetMinProfitThreshold() public {
        uint256 newThreshold = 5e6;
        incentives.setMinProfitThreshold(newThreshold);
        assertEq(incentives.minProfitThreshold(), newThreshold);
    }

    function test_OnRebalanceExecuted_ZeroRewardWhenNoBalance() public {
        incentives.setIncentiveBps(0);
        vm.prank(address(vault));
        uint256 reward = incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);
        assertEq(reward, 0);
        assertEq(incentives.pendingReward(alice), 0);
        assertEq(incentives.totalRewardsPaid(), 0);
    }

    function test_CanRebalance_AfterCooldownTrue() public {
        vm.prank(address(vault));
        incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);
        skip(301);
        assertTrue(incentives.canRebalance());
    }

    function test_Revert_SetCooldownPeriod_TooLarge() public {
        vm.expectRevert(bytes("Incentives: invalid cooldown"));
        incentives.setCooldownPeriod(100000);
    }

    function test_Revert_SetCooldownPeriod_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        incentives.setCooldownPeriod(600);
    }

    function test_Revert_SetMinProfitThreshold_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        incentives.setMinProfitThreshold(5e6);
        vm.stopPrank();
    }
}
