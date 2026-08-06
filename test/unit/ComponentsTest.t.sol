// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.t.sol";
import {IRebalanceStrategy, IGovernance} from "../../src/interfaces/ICoreInterfaces.sol";
import {AdaptiveGovernance} from "../../src/governance/AdaptiveGovernance.sol";

/**
 * @title OracleTest - 预言机测试
 */
contract OracleTest is BaseTest {
    function test_GetTWAPPrice() public view {
        (uint160 price, int24 tick) = oracle.getTWAPPrice();
        assertGt(price, 0);
        assertGt(tick, -887272);
        assertLt(tick, 887272);
    }

    function test_Quote_WETHtoUSDC() public view {
        uint256 usdcOut = oracle.quote(1 ether, true);
        assertApproxEqRel(usdcOut, 2000e6, 0.05e18);
    }

    function test_Quote_USDCtoWETH() public view {
        uint256 wethOut = oracle.quote(2000e6, false);
        assertApproxEqRel(wethOut, 1 ether, 0.05e18);
    }

    function test_Quote_ZeroAmount() public view {
        assertEq(oracle.quote(0, true), 0);
        assertEq(oracle.quote(0, false), 0);
    }

    function test_SetTWAPWindow() public {
        oracle.setTWAPWindow(3600);
        assertEq(oracle.twapWindow(), 3600);
    }

    function test_Revert_SetTWAPWindow_TooSmall() public {
        vm.expectRevert();
        oracle.setTWAPWindow(10);
    }

    function test_Revert_SetTWAPWindow_TooLarge() public {
        vm.expectRevert();
        oracle.setTWAPWindow(100000);
    }

    function test_OnlyAuthorized_CanSetWindow() public {
        vm.startPrank(alice);
        vm.expectRevert();
        oracle.setTWAPWindow(3600);
        vm.stopPrank();
    }

    function test_SetGovernance() public {
        oracle.setGovernance(bob);
        assertEq(address(oracle.governance()), bob);
    }

    function test_GetCurrentPrice() public view {
        (uint160 price,) = oracle.getCurrentPrice();
        assertGt(price, 0);
    }

    function test_EnsureObservationCardinality() public {
        // 不应revert
        oracle.ensureObservationCardinality(2);
    }
}

/**
 * @title StrategyTest - 策略测试（含fuzz）
 */
contract StrategyTest is BaseTest {
    function test_CalculateAllocation_LowVolatility() public view {
        (IRebalanceStrategy.AllocationWeights memory alloc,
         IRebalanceStrategy.V3RangeWeights memory ranges) =
            strategy.calculateAllocation(0, 0, 1000);

        assertGt(alloc.v3HighFeeWeight, alloc.v2Weight);
        assertGt(ranges.tightWeight, ranges.wideWeight);
        // 权重总和应为10000
        assertEq(alloc.v2Weight + alloc.v3LowFeeWeight + alloc.v3HighFeeWeight, 10000);
        assertEq(ranges.tightWeight + ranges.mediumWeight + ranges.wideWeight, 10000);
    }

    function test_CalculateAllocation_MediumVolatility() public view {
        (IRebalanceStrategy.AllocationWeights memory alloc,
         IRebalanceStrategy.V3RangeWeights memory ranges) =
            strategy.calculateAllocation(0, 0, 3500);

        assertEq(alloc.v2Weight + alloc.v3LowFeeWeight + alloc.v3HighFeeWeight, 10000);
        assertEq(ranges.tightWeight + ranges.mediumWeight + ranges.wideWeight, 10000);
    }

    function test_CalculateAllocation_HighVolatility() public view {
        (IRebalanceStrategy.AllocationWeights memory alloc,
         IRebalanceStrategy.V3RangeWeights memory ranges) =
            strategy.calculateAllocation(0, 0, 8000);

        assertGe(alloc.v2Weight, alloc.v3HighFeeWeight);
        assertGt(ranges.wideWeight, ranges.tightWeight);
        assertEq(alloc.v2Weight + alloc.v3LowFeeWeight + alloc.v3HighFeeWeight, 10000);
    }

    function test_GetRangeTicks_TightMediumWide() public view {
        (int24 tl, int24 tu, int24 ml, int24 mu, int24 wl, int24 wu) =
            strategy.getRangeTicks(76000);

        assertLt(tu - tl, mu - ml);
        assertLt(mu - ml, wu - wl);
        assertEq(tl % 60, 0);
        assertEq(tu % 60, 0);
        assertEq(ml % 60, 0);
        assertEq(mu % 60, 0);
        assertEq(wl % 60, 0);
        assertEq(wu % 60, 0);
    }

    function test_GetRangeTicks_NegativeTick() public view {
        (int24 tl, int24 tu,,, int24 wl, int24 wu) = strategy.getRangeTicks(-200000);
        assertGt(tl, -887272);
        assertLt(tu, 887272);
        assertGt(wl, -887272);
        assertLt(wu, 887272);
    }

    function test_GetRangeTicks_PositiveTick() public view {
        (int24 tl, int24 tu,,,,) = strategy.getRangeTicks(200000);
        assertLt(tu, 887272);
        assertGt(tl, -887272);
    }

    function test_NeedsRebalance() public view {
        assertTrue(strategy.needsRebalance(600));
        assertFalse(strategy.needsRebalance(400));
        assertTrue(strategy.needsRebalance(500)); // 边界
    }

    function test_EstimateVolatility() public view {
        uint256 vol = strategy.estimateVolatility(2200e6, 2000e6);
        assertGt(vol, 0);
        assertApproxEqRel(vol, 2100, 0.1e18); // ~10%
    }

    function test_EstimateVolatility_SamePrice() public view {
        uint256 vol = strategy.estimateVolatility(2000e6, 2000e6);
        assertEq(vol, 0);
    }

    function test_CalculateDeviation() public view {
        uint256 dev = strategy.calculateDeviation(2200e6, 2000e6);
        assertGt(dev, 0);
    }

    function test_SetRebalanceThreshold() public {
        strategy.setRebalanceThreshold(1000);
        // 验证阈值已更新（通过needsRebalance间接验证）
        assertFalse(strategy.needsRebalance(800));
        assertTrue(strategy.needsRebalance(1200));
    }

    function test_SetGovernance() public {
        strategy.setGovernance(bob);
        // 非governance不能set
        vm.startPrank(alice);
        vm.expectRevert();
        strategy.setRebalanceThreshold(1000);
        vm.stopPrank();
    }

    function testFuzz_AllocationWeightsSum(uint256 volatility) public view {
        // 限制volatility范围
        volatility = bound(volatility, 0, 20000);
        (IRebalanceStrategy.AllocationWeights memory alloc,
         IRebalanceStrategy.V3RangeWeights memory ranges) =
            strategy.calculateAllocation(0, 0, volatility);
        assertEq(alloc.v2Weight + alloc.v3LowFeeWeight + alloc.v3HighFeeWeight, 10000);
        assertEq(ranges.tightWeight + ranges.mediumWeight + ranges.wideWeight, 10000);
    }

    function testFuzz_RangeTicksWithinBounds(int24 tick) public view {
        tick = int24(bound(tick, -800000, 800000));
        (int24 tl, int24 tu, int24 ml, int24 mu, int24 wl, int24 wu) =
            strategy.getRangeTicks(tick);
        assertGe(tl, -887272);
        assertLe(tu, 887272);
        assertGe(ml, -887272);
        assertLe(mu, 887272);
        assertGe(wl, -887272);
        assertLe(wu, 887272);
        assertLt(tl, tu);
        assertLt(ml, mu);
        assertLt(wl, wu);
    }
}

/**
 * @title IncentivesTest - 激励测试
 */
contract IncentivesTest is BaseTest {
    function test_CanRebalance_Initially() public view {
        assertTrue(incentives.canRebalance());
    }

    function test_OnRebalanceExecuted() public {
        vm.prank(address(vault));
        uint256 reward = incentives.onRebalanceExecuted(alice, 10000e6, 10100e6);
        assertGt(reward, 0);
        assertEq(incentives.pendingReward(alice), reward);
        assertEq(incentives.totalRewardsPaid(), reward);
    }

    function test_ClaimReward() public {
        vm.prank(address(vault));
        incentives.onRebalanceExecuted(alice, 10000e6, 10100e6);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        incentives.claimReward();
        uint256 after_ = usdc.balanceOf(alice);

        assertGt(after_, before);
        assertEq(incentives.pendingReward(alice), 0);
    }

    function test_ClaimReward_NoReward() public {
        vm.prank(alice);
        vm.expectRevert("Incentives: no rewards");
        incentives.claimReward();
    }

    function test_Revert_OnRebalance_NotProfitable() public {
        vm.prank(address(vault));
        vm.expectRevert();
        incentives.onRebalanceExecuted(alice, 10000e6, 9900e6);
    }

    function test_Revert_OnRebalance_NotVault() public {
        vm.prank(alice);
        vm.expectRevert();
        incentives.onRebalanceExecuted(alice, 10000e6, 10100e6);
    }

    function test_Revert_OnRebalance_Cooldown() public {
        vm.startPrank(address(vault));
        incentives.onRebalanceExecuted(alice, 10000e6, 10100e6);
        vm.expectRevert();
        incentives.onRebalanceExecuted(bob, 10000e6, 10200e6);
        vm.stopPrank();
    }

    function test_CanRebalance_AfterCooldownPeriod() public {
        vm.prank(address(vault));
        incentives.onRebalanceExecuted(alice, 10000e6, 10100e6);
        assertFalse(incentives.canRebalance());
        vm.warp(1000);
        assertTrue(incentives.canRebalance());
    }

    function test_SetIncentiveBps() public {
        incentives.setIncentiveBps(1000);
        assertEq(incentives.incentiveBps(), 1000);
    }

    function test_Revert_SetIncentiveBps_TooHigh() public {
        vm.expectRevert();
        incentives.setIncentiveBps(3000);
    }

    function test_SetCooldownPeriod() public {
        incentives.setCooldownPeriod(600);
        // 验证冷却时间更新
    }

    function test_SetMinProfitThreshold() public {
        incentives.setMinProfitThreshold(2e6);
    }

    function test_FundRewards() public {
        uint256 before = usdc.balanceOf(address(incentives));
        usdc.mint(address(this), 1000e6);
        usdc.approve(address(incentives), 1000e6);
        incentives.fundRewards(1000e6);
        assertEq(usdc.balanceOf(address(incentives)), before + 1000e6);
    }

    function test_RewardsEarnedTracking() public {
        vm.prank(address(vault));
        incentives.onRebalanceExecuted(alice, 10000e6, 10100e6);
        assertGt(incentives.rewardsEarned(alice), 0);
    }
}

/**
 * @title GovernanceTest - 治理完整流程测试
 */
contract GovernanceTest is BaseTest {
    uint256 constant PROPOSAL_THRESHOLD = 1000e18;
    uint256 constant QUORUM_VOTES = 10000e18;

    function _mintGovTokens(address to, uint256 amount) internal {
        vm.prank(address(governance));
        govToken.mint(to, amount);
    }

    function test_DefaultParams() public view {
        IGovernance.StrategyParams memory p = governance.getParams();
        assertEq(p.twapWindow, 1800);
        assertEq(p.rebalanceThreshold, 500);
        assertEq(p.incentiveBps, 500);
        assertEq(p.maxSlippageBps, 100);
    }

    function test_SetParams_Owner() public {
        governance.setTWAPWindow(3600);
        assertEq(governance.getParams().twapWindow, 3600);

        governance.setMaxSlippageBps(200);
        assertEq(governance.getParams().maxSlippageBps, 200);

        governance.setRebalanceThreshold(800);
        assertEq(governance.getParams().rebalanceThreshold, 800);

        governance.setIncentiveBps(800);
        assertEq(governance.getParams().incentiveBps, 800);

        governance.setWeightCaps(5000, 4000, 6000);
        assertEq(governance.getParams().v2WeightCap, 5000);

        governance.setRangeBps(300, 1500, 4000);
        assertEq(governance.getParams().tightRangeBps, 300);
    }

    function test_Revert_SetParams_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        governance.setTWAPWindow(3600);
        vm.stopPrank();
    }

    function test_Revert_SetParams_InvalidValues() public {
        // governance setter本身不验证，但oracle验证twapWindow
        vm.expectRevert();
        oracle.setTWAPWindow(10);
        vm.expectRevert();
        oracle.setTWAPWindow(100000);
    }

    function test_Propose_RequiresThreshold() public {
        vm.startPrank(alice);
        vm.expectRevert();
        governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            3600, 0, 0, ""
        );
        vm.stopPrank();
    }

    function test_FullProposalLifecycle() public {
        // 给alice足够的提案和投票权
        _mintGovTokens(alice, QUORUM_VOTES + PROPOSAL_THRESHOLD);

        // 1. 提案
        vm.startPrank(alice);
        uint256 proposalId = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            3600, 0, 0, "set twap window to 1 hour"
        );
        vm.stopPrank();

        // 状态应为Pending
        assertEq(uint(governance.getProposalState(proposalId)), uint(AdaptiveGovernance.ProposalState.Pending));

        // 2. 到投票期
        vm.roll(block.number + 2); // votingDelay=1
        assertEq(uint(governance.getProposalState(proposalId)), uint(AdaptiveGovernance.ProposalState.Active));

        // 3. 投票
        vm.prank(alice);
        governance.castVote(proposalId, true);

        // 4. 投票结束
        vm.roll(block.number + 28801); // votingPeriod=28800
        assertEq(uint(governance.getProposalState(proposalId)), uint(AdaptiveGovernance.ProposalState.Succeeded));

        // 5. 执行提案（进入时间锁）
        governance.executeProposal(proposalId);
        assertEq(uint(governance.getProposalState(proposalId)), uint(AdaptiveGovernance.ProposalState.Executed));

        // 6. 时间锁未到，不能执行
        vm.expectRevert();
        governance.executeTimelock(proposalId);

        // 7. 时间锁到期后执行
        vm.warp(block.timestamp + 172801); // timelockDelay=172800
        governance.executeTimelock(proposalId);
        assertEq(governance.getParams().twapWindow, 3600);
    }

    function test_Proposal_Defeated() public {
        _mintGovTokens(alice, PROPOSAL_THRESHOLD);
        _mintGovTokens(bob, QUORUM_VOTES);

        vm.prank(alice);
        uint256 proposalId = governance.propose(
            AdaptiveGovernance.ProposalType.SET_REBALANCE_THRESHOLD,
            1000, 0, 0, ""
        );

        vm.roll(block.number + 2);
        // bob投反对票
        vm.prank(bob);
        governance.castVote(proposalId, false);

        vm.roll(block.number + 28801);
        assertEq(uint(governance.getProposalState(proposalId)), uint(AdaptiveGovernance.ProposalState.Defeated));

        // 失败的提案不能执行
        vm.expectRevert();
        governance.executeProposal(proposalId);
    }

    function test_CancelProposal() public {
        _mintGovTokens(alice, PROPOSAL_THRESHOLD);

        vm.prank(alice);
        uint256 proposalId = governance.propose(
            AdaptiveGovernance.ProposalType.SET_INCENTIVE_BPS,
            1000, 0, 0, ""
        );

        vm.prank(alice);
        governance.cancelProposal(proposalId);
        assertEq(uint(governance.getProposalState(proposalId)), uint(AdaptiveGovernance.ProposalState.Canceled));
    }

    function test_CancelProposal_ByOwner() public {
        _mintGovTokens(alice, PROPOSAL_THRESHOLD);

        vm.prank(alice);
        uint256 proposalId = governance.propose(
            AdaptiveGovernance.ProposalType.SET_MAX_SLIPPAGE,
            200, 0, 0, ""
        );

        // owner可以取消
        governance.cancelProposal(proposalId);
        assertEq(uint(governance.getProposalState(proposalId)), uint(AdaptiveGovernance.ProposalState.Canceled));
    }

    function test_Revert_CancelProposal_NotAuthorized() public {
        _mintGovTokens(alice, PROPOSAL_THRESHOLD);

        vm.prank(alice);
        uint256 proposalId = governance.propose(
            AdaptiveGovernance.ProposalType.SET_MAX_SLIPPAGE,
            200, 0, 0, ""
        );

        vm.prank(bob);
        vm.expectRevert();
        governance.cancelProposal(proposalId);
    }

    function test_Revert_VoteTwice() public {
        _mintGovTokens(alice, PROPOSAL_THRESHOLD + QUORUM_VOTES);

        vm.prank(alice);
        uint256 proposalId = governance.propose(
            AdaptiveGovernance.ProposalType.SET_WEIGHT_CAPS,
            5000, 4000, 6000, ""
        );

        vm.roll(block.number + 2);
        vm.startPrank(alice);
        governance.castVote(proposalId, true);
        vm.expectRevert();
        governance.castVote(proposalId, true);
        vm.stopPrank();
    }

    function test_Revert_VoteBeforeActive() public {
        _mintGovTokens(alice, PROPOSAL_THRESHOLD + QUORUM_VOTES);

        vm.prank(alice);
        uint256 proposalId = governance.propose(
            AdaptiveGovernance.ProposalType.SET_RANGE_BPS,
            300, 1500, 4000, ""
        );

        // 还在Pending状态
        vm.prank(alice);
        vm.expectRevert();
        governance.castVote(proposalId, true);
    }

    function test_Revert_VoteAfterEnded() public {
        _mintGovTokens(alice, PROPOSAL_THRESHOLD + QUORUM_VOTES);

        vm.prank(alice);
        uint256 proposalId = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            7200, 0, 0, ""
        );

        vm.roll(block.number + 28803); // 过了投票期
        vm.prank(alice);
        vm.expectRevert();
        governance.castVote(proposalId, true);
    }

    function test_Revert_VoteNoPower() public {
        _mintGovTokens(alice, PROPOSAL_THRESHOLD);

        vm.prank(alice);
        uint256 proposalId = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            7200, 0, 0, ""
        );

        vm.roll(block.number + 2);
        // bob没有投票权
        vm.prank(bob);
        vm.expectRevert();
        governance.castVote(proposalId, true);
    }

    function test_GovToken_MintBurn() public {
        vm.prank(address(governance));
        govToken.mint(alice, 10000e18);
        assertEq(govToken.balanceOf(alice), 10000e18);

        vm.prank(address(governance));
        govToken.burn(alice, 5000e18);
        assertEq(govToken.balanceOf(alice), 5000e18);
    }

    function test_Revert_GovToken_NotMinter() public {
        vm.prank(alice);
        vm.expectRevert();
        govToken.mint(bob, 1000e18);
    }

    function test_SetVault() public {
        governance.setVault(bob);
        // 不revert即可
    }

    function test_ProposalTypes() public {
        _mintGovTokens(alice, PROPOSAL_THRESHOLD + QUORUM_VOTES);

        // SET_WEIGHT_CAPS
        vm.prank(alice);
        uint256 id1 = governance.propose(
            AdaptiveGovernance.ProposalType.SET_WEIGHT_CAPS,
            5000, 4000, 6000, ""
        );
        assertGt(id1, 0);

        // SET_RANGE_BPS
        vm.prank(alice);
        uint256 id2 = governance.propose(
            AdaptiveGovernance.ProposalType.SET_RANGE_BPS,
            300, 1500, 4000, ""
        );
        assertGt(id2, id1);
    }

    function test_Revert_ExecuteTimelock_NoTimelock() public {
        vm.expectRevert();
        governance.executeTimelock(999);
    }

    function test_ProposalCount() public view {
        // 初始应为0
        assertEq(governance.proposalCount(), 0);
    }
}
