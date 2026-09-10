// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";
import {RebalanceIncentives} from "../../src/incentives/RebalanceIncentives.sol";

contract IncentivesTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // 测试正常再平衡时奖励计算：利润200USDC，激励比例5%，应奖励10USDC
    function test_OnRebalanceExecuted_RewardCalculation() public {
        uint256 before = 1000e6;
        uint256 afterValue = 1200e6;

        vm.prank(address(vault));
        uint256 reward = incentives.onRebalanceExecuted(alice, before, afterValue);

        assertEq(reward, 10e6);
        assertEq(incentives.pendingReward(alice), 10e6);
    }

    // 测试奖励上限：当计算出的奖励超过合约余额时，奖励被截断为合约实际余额
    function test_OnRebalanceExecuted_RewardCappedByBalance() public {
        uint256 balance = usdc.balanceOf(address(incentives));
        uint256 before = 0;
        uint256 afterValue = 10_000_000e6;

        vm.prank(address(vault));
        uint256 reward = incentives.onRebalanceExecuted(alice, before, afterValue);

        assertLe(reward, balance);
    }

    // 测试权限控制：非金库地址调用 onRebalanceExecuted 应 revert
    function test_Revert_OnRebalanceExecuted_NotVault() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Incentives: not vault"));
        incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);
    }

    // 测试无利润 revert：再平衡后价值不大于再平衡前时应 revert
    function test_Revert_OnRebalanceExecuted_NoProfit() public {
        vm.prank(address(vault));
        vm.expectRevert(bytes("Incentives: not profitable"));
        incentives.onRebalanceExecuted(alice, 1100e6, 1000e6);
    }

    // 测试利润过低 revert：利润低于最低阈值1USDC时应 revert
    function test_Revert_OnRebalanceExecuted_BelowMinProfit() public {
        vm.prank(address(vault));
        vm.expectRevert(bytes("Incentives: profit too small"));
        incentives.onRebalanceExecuted(alice, 1000e6, 1000500000);
    }

    // 测试冷却期 revert：第一次再平衡后300秒内再次调用应 revert
    function test_Revert_OnRebalanceExecuted_Cooldown() public {
        vm.prank(address(vault));
        uint256 reward = incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);
        assertEq(reward, 5e6);

        vm.prank(address(vault));
        vm.expectRevert(bytes("Incentives: cooldown active"));
        incentives.onRebalanceExecuted(bob, 1000e6, 1100e6);
    }

    // 测试冷却期过后可正常执行：跳过301秒后第二次再平衡成功
    function test_OnRebalanceExecuted_AfterCooldown() public {
        vm.prank(address(vault));
        uint256 rewardA = incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);
        assertEq(rewardA, 5e6);

        skip(301);
        vm.prank(address(vault));
        uint256 rewardB = incentives.onRebalanceExecuted(bob, 1000e6, 1100e6);
        assertGt(rewardB, 0);
    }

    // 测试领取奖励：用户领取后代币正确转账且待领取奖励清零
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

    // 测试无奖励时领取 revert：待领取奖励为0时调用 claimReward 应 revert
    function test_Revert_ClaimReward_ZeroBalance() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Incentives: no rewards"));
        incentives.claimReward();
    }

    // 测试奖励累计：同一用户两次再平衡后待领取奖励应累计为两次之和
    function test_PendingReward_MatchesAccumulated() public {
        vm.prank(address(vault));
        incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);
        skip(301);
        vm.prank(address(vault));
        incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);

        assertEq(incentives.pendingReward(alice), 10e6);
    }

    // 测试首次 canRebalance：从未执行过再平衡时应返回 true
    function test_CanRebalance_FirstTimeTrue() public view {
        assertTrue(incentives.canRebalance());
    }

    // 测试冷却期内 canRebalance：刚执行完再平衡后应返回 false
    function test_CanRebalance_CooldownFalse() public {
        vm.prank(address(vault));
        incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);
        assertFalse(incentives.canRebalance());
    }

    // 测试设置激励比例上限：设置为最大允许值2000bps(20%)时成功
    function test_SetIncentiveBps_UpperLimit() public {
        incentives.setIncentiveBps(2000);
        assertEq(incentives.incentiveBps(), 2000);
    }

    // 测试激励比例超限 revert：设置超过2000bps时应 revert
    function test_Revert_SetIncentiveBps_TooHigh() public {
        vm.expectRevert(bytes("Incentives: too high"));
        incentives.setIncentiveBps(2001);
    }

    // 测试设置冷却期：设置为有效值600秒时成功
    function test_SetCooldownPeriod_Range() public {
        incentives.setCooldownPeriod(600);
        assertEq(incentives.cooldownPeriod(), 600);
    }

    // 测试冷却期过短 revert：设置小于60秒时应 revert
    function test_Revert_SetCooldownPeriod_TooSmall() public {
        vm.expectRevert(bytes("Incentives: invalid cooldown"));
        incentives.setCooldownPeriod(30);
    }

    // 测试非 owner 设置激励比例 revert：普通用户调用 setIncentiveBps 应 revert
    function test_Revert_SetIncentiveBps_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        incentives.setIncentiveBps(1000);
    }

    // 测试治理合约注入资金：governance 地址调用 fundRewards 成功注入
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

    // 测试金库注入资金：vault 地址调用 fundRewards 成功注入
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

    // 测试注入0金额 revert：amount 为0时调用 fundRewards 应 revert
    function test_Revert_FundRewards_ZeroAmount() public {
        vm.prank(address(governance));
        vm.expectRevert(bytes("Incentives: zero amount"));
        incentives.fundRewards(0);
    }

    // 测试未授权注入 revert：普通用户调用 fundRewards 应 revert
    function test_Revert_FundRewards_NotAuthorized() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Incentives: not authorized"));
        incentives.fundRewards(100e6);
    }

    // 测试设置最低利润阈值：设置新阈值后成功更新
    function test_SetMinProfitThreshold() public {
        uint256 newThreshold = 5e6;
        incentives.setMinProfitThreshold(newThreshold);
        assertEq(incentives.minProfitThreshold(), newThreshold);
    }

    // 测试零奖励场景：激励比例设为0时奖励为0且不累计到用户和总奖励
    function test_OnRebalanceExecuted_ZeroRewardWhenNoBalance() public {
        incentives.setIncentiveBps(0);
        vm.prank(address(vault));
        uint256 reward = incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);
        assertEq(reward, 0);
        assertEq(incentives.pendingReward(alice), 0);
        assertEq(incentives.totalRewardsPaid(), 0);
    }

    // 测试冷却期后 canRebalance：跳过301秒后 canRebalance 应返回 true
    function test_CanRebalance_AfterCooldownTrue() public {
        vm.prank(address(vault));
        incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);
        skip(301);
        assertTrue(incentives.canRebalance());
    }

    // 测试冷却期过长 revert：设置超过86400秒(1天)时应 revert
    function test_Revert_SetCooldownPeriod_TooLarge() public {
        vm.expectRevert(bytes("Incentives: invalid cooldown"));
        incentives.setCooldownPeriod(100000);
    }

    // 测试非 owner 设置冷却期 revert：普通用户调用 setCooldownPeriod 应 revert
    function test_Revert_SetCooldownPeriod_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        incentives.setCooldownPeriod(600);
    }

    // 测试非 owner 设置最低利润阈值 revert：普通用户调用 setMinProfitThreshold 应 revert
    function test_Revert_SetMinProfitThreshold_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        incentives.setMinProfitThreshold(5e6);
        vm.stopPrank();
    }
}
