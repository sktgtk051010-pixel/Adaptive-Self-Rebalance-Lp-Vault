// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";
import {AdaptiveGovernance} from "../../src/governance/AdaptiveGovernance.sol";

/**
 * @title GovernanceExecutionTest
 * @notice 治理执行集成测试
 */
contract GovernanceExecutionTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    /// @notice 完整治理流程：提案→投票→执行→时间锁→参数生效
    function test_Propose_Vote_Execute_ParamApplied() public {
        // 给提案者和投票者代币
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);

        // 1. 提案
        vm.startPrank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_REBALANCE_THRESHOLD,
            1000, 0, 0, "increase threshold"
        );
        vm.stopPrank();

        // 2. 投票
        vm.roll(block.number + governance.votingDelay() + 1);
        vm.startPrank(bob);
        governance.castVote(id, true);
        vm.stopPrank();

        // 3. 投票结束，提案通过
        vm.roll(block.number + governance.votingPeriod() + 1);
        assertEq(
            uint256(governance.getProposalState(id)),
            uint256(AdaptiveGovernance.ProposalState.Succeeded)
        );

        // 4. 执行提案（加入时间锁）
        governance.executeProposal(id);

        // 5. 时间锁到期后执行
        uint256 oldThreshold = governance.getParams().rebalanceThreshold;
        skip(governance.timelockDelay() + 1);
        governance.executeTimelock(id);

        assertEq(governance.getParams().rebalanceThreshold, 1000);
        assertNotEq(oldThreshold, 1000);
    }

    /// @notice 时间锁延迟强制执行
    function test_TimelockDelay_Enforced() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);

        vm.startPrank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        vm.stopPrank();

        vm.roll(block.number + governance.votingDelay() + 1);
        vm.prank(bob);
        governance.castVote(id, true);
        vm.roll(block.number + governance.votingPeriod() + 1);

        governance.executeProposal(id);

        // 立即执行timelock应该revert
        vm.expectRevert(bytes("Governance: timelock not ready"));
        governance.executeTimelock(id);
    }

    /// @notice owner紧急设置参数
    function test_OwnerEmergencySet() public {
        // owner可以直接设置，不需要提案
        governance.setTWAPWindow(900);
        assertEq(governance.getParams().twapWindow, 900);

        governance.setMaxSlippageBps(200);
        assertEq(governance.getParams().maxSlippageBps, 200);

        governance.setWeightCaps(5000, 3000, 2000);
        assertEq(governance.getParams().v2WeightCap, 5000);

        governance.setRangeBps(300, 1500, 4000);
        assertEq(governance.getParams().tightRangeBps, 300);
    }

    /// @notice 提案被否决后不能执行
    function test_DefeatedProposal_CannotExecute() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 5000e18); // < quorum 10000

        vm.startPrank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        vm.stopPrank();

        vm.roll(block.number + governance.votingDelay() + 1);
        vm.prank(bob);
        governance.castVote(id, true);
        vm.roll(block.number + governance.votingPeriod() + 1);

        assertEq(
            uint256(governance.getProposalState(id)),
            uint256(AdaptiveGovernance.ProposalState.Defeated)
        );

        vm.expectRevert(bytes("Governance: not succeeded"));
        governance.executeProposal(id);
    }

    /// @notice 多类型提案参数都能正确应用
    function test_MultipleProposalTypes() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);

        // SET_INCENTIVE_BPS
        vm.startPrank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_INCENTIVE_BPS,
            1000, 0, 0, "test"
        );
        vm.stopPrank();

        vm.roll(block.number + governance.votingDelay() + 1);
        vm.prank(bob);
        governance.castVote(id, true);
        vm.roll(block.number + governance.votingPeriod() + 1);
        governance.executeProposal(id);
        skip(governance.timelockDelay() + 1);
        governance.executeTimelock(id);

        assertEq(governance.getParams().incentiveBps, 1000);
    }
}
