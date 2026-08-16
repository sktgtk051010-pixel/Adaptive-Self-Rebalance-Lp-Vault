// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";
import {RebalanceIncentives} from "../../src/incentives/RebalanceIncentives.sol";

/**
 * @title IncentivesTest
 * @notice 再平衡激励专项测试
 */
contract IncentivesTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    /// @notice 首次再平衡不检查冷却
    function test_OnRebalanceExecuted_FirstTime() public {
        uint256 before = 1000e6;
        uint256 afterValue = 1100e6; // 盈利100 USDC

        vm.prank(address(vault));
        uint256 reward = incentives.onRebalanceExecuted(alice, before, afterValue);

        // reward = profit * 5% = 100e6 * 500/10000 = 5e6
        assertEq(reward, 5e6, "reward should be 5% of profit");
        assertEq(incentives.pendingReward(alice), 5e6);
    }

    /// @notice 奖励计算正确
    function test_OnRebalanceExecuted_RewardCalculation() public {
        uint256 before = 1000e6;
        uint256 afterValue = 1200e6; // 盈利200 USDC

        vm.prank(address(vault));
        uint256 reward = incentives.onRebalanceExecuted(alice, before, afterValue);

        // 200e6 * 500/10000 = 10e6
        assertEq(reward, 10e6);
    }

    /// @notice 奖励不超过合约余额
    function test_OnRebalanceExecuted_RewardCappedByBalance() public {
        uint256 balance = usdc.balanceOf(address(incentives));
        uint256 before = 0;
        uint256 afterValue = 10_000_000e6; // 超大profit，计算出的reward会超过余额

        vm.prank(address(vault));
        uint256 reward = incentives.onRebalanceExecuted(alice, before, afterValue);

        // reward应该被限制为合约余额
        assertLe(reward, balance);
        assertEq(reward, balance, "reward should equal available balance when capped");
    }

    /// @notice 非vault调用revert
    function test_Revert_OnRebalanceExecuted_NotVault() public {
        vm.startPrank(alice);
        vm.expectRevert(bytes("Incentives: not vault"));
        incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);
        vm.stopPrank();
    }

    /// @notice 非盈利revert
    function test_Revert_OnRebalanceExecuted_NoProfit() public {
        vm.prank(address(vault));
        vm.expectRevert(bytes("Incentives: not profitable"));
        incentives.onRebalanceExecuted(alice, 1100e6, 1000e6);
    }

    /// @notice 利润低于阈值revert
    function test_Revert_OnRebalanceExecuted_BelowMinProfit() public {
        // minProfitThreshold = 1e6 (1 USDC)
        vm.prank(address(vault));
        vm.expectRevert(bytes("Incentives: profit too small"));
        incentives.onRebalanceExecuted(alice, 1000e6, 1000500000); // 盈利0.5 USDC
    }

    /// @notice 冷却期内revert
    function test_Revert_OnRebalanceExecuted_Cooldown() public {
        vm.prank(address(vault));
        incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);

        // 立即再次调用（冷却期300s）
        vm.prank(address(vault));
        vm.expectRevert(bytes("Incentives: cooldown active"));
        incentives.onRebalanceExecuted(bob, 1000e6, 1100e6);
    }

    /// @notice 冷却期过后可以再次执行
    function test_OnRebalanceExecuted_AfterCooldown() public {
        vm.prank(address(vault));
        incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);

        skip(301);
        vm.prank(address(vault));
        uint256 reward = incentives.onRebalanceExecuted(bob, 1000e6, 1100e6);
        assertGt(reward, 0);
    }

    /// @notice claimReward转账代币
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

    /// @notice 无奖励时claim revert
    function test_Revert_ClaimReward_ZeroBalance() public {
        vm.startPrank(alice);
        vm.expectRevert(bytes("Incentives: no rewards"));
        incentives.claimReward();
        vm.stopPrank();
    }

    /// @notice pendingReward匹配累计奖励
    function test_PendingReward_MatchesAccumulated() public {
        vm.prank(address(vault));
        incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);
        skip(301);
        vm.prank(address(vault));
        incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);

        // 两次各5e6
        assertEq(incentives.pendingReward(alice), 10e6);
    }

    /// @notice 首次canRebalance为true
    function test_CanRebalance_FirstTimeTrue() public view {
        assertTrue(incentives.canRebalance());
    }

    /// @notice 冷却期内canRebalance为false
    function test_CanRebalance_CooldownFalse() public {
        vm.prank(address(vault));
        incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);
        assertFalse(incentives.canRebalance());
    }

    /// @notice 设置激励比例上限2000
    function test_SetIncentiveBps_UpperLimit() public {
        incentives.setIncentiveBps(2000);
        assertEq(incentives.incentiveBps(), 2000);
    }

    /// @notice 激励比例超过上限revert
    function test_Revert_SetIncentiveBps_TooHigh() public {
        vm.expectRevert(bytes("Incentives: too high"));
        incentives.setIncentiveBps(2001);
    }

    /// @notice 设置冷却期范围
    function test_SetCooldownPeriod_Range() public {
        incentives.setCooldownPeriod(600);
        assertEq(incentives.cooldownPeriod(), 600);
    }

    /// @notice 冷却期过小revert
    function test_Revert_SetCooldownPeriod_TooSmall() public {
        vm.expectRevert(bytes("Incentives: invalid cooldown"));
        incentives.setCooldownPeriod(30); // < 60
    }

    /// @notice 非owner设置参数revert
    function test_Revert_SetIncentiveBps_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        incentives.setIncentiveBps(1000);
        vm.stopPrank();
    }

    /// @notice 治理注入奖励资金
    function test_FundRewards_ByGovernance() public {
        uint256 amount = 1000e6;
        uint256 balanceBefore = usdc.balanceOf(address(incentives));
        // 给governance合约mint USDC并授权
        usdc.mint(address(governance), amount);
        vm.startPrank(address(governance));
        usdc.approve(address(incentives), amount);
        incentives.fundRewards(amount);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(incentives)), balanceBefore + amount);
    }

    /// @notice 金库注入奖励资金
    function test_FundRewards_ByVault() public {
        uint256 amount = 1000e6;
        uint256 balanceBefore = usdc.balanceOf(address(incentives));
        // 给vault合约mint USDC并授权
        usdc.mint(address(vault), amount);
        vm.startPrank(address(vault));
        usdc.approve(address(incentives), amount);
        incentives.fundRewards(amount);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(incentives)), balanceBefore + amount);
    }

    /// @notice 零金额注入revert
    function test_Revert_FundRewards_ZeroAmount() public {
        vm.prank(address(governance));
        vm.expectRevert(bytes("Incentives: zero amount"));
        incentives.fundRewards(0);
    }

    /// @notice 非授权地址注入revert
    function test_Revert_FundRewards_NotAuthorized() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Incentives: not authorized"));
        incentives.fundRewards(100e6);
    }

    /// @notice 设置最小利润阈值
    function test_SetMinProfitThreshold() public {
        uint256 newThreshold = 5e6;
        incentives.setMinProfitThreshold(newThreshold);
        assertEq(incentives.minProfitThreshold(), newThreshold);
    }

    /// @notice 奖励比例为0时奖励为0
    function test_OnRebalanceExecuted_ZeroRewardWhenNoBalance() public {
        incentives.setIncentiveBps(0);
        vm.prank(address(vault));
        uint256 reward = incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);
        assertEq(reward, 0);
        assertEq(incentives.pendingReward(alice), 0);
        assertEq(incentives.totalRewardsPaid(), 0);
    }

    /// @notice 冷却期过后canRebalance返回true
    function test_CanRebalance_AfterCooldownTrue() public {
        vm.prank(address(vault));
        incentives.onRebalanceExecuted(alice, 1000e6, 1100e6);
        skip(301);
        assertTrue(incentives.canRebalance());
    }

    /// @notice 冷却期过大revert
    function test_Revert_SetCooldownPeriod_TooLarge() public {
        vm.expectRevert(bytes("Incentives: invalid cooldown"));
        incentives.setCooldownPeriod(100000);
    }

    /// @notice 非owner设置冷却期revert
    function test_Revert_SetCooldownPeriod_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        incentives.setCooldownPeriod(600);
        vm.stopPrank();
    }

    /// @notice 非owner设置阈值revert
    function test_Revert_SetMinProfitThreshold_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        incentives.setMinProfitThreshold(5e6);
        vm.stopPrank();
    }
}
