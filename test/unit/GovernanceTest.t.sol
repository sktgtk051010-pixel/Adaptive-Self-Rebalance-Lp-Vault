// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";
import {GovernanceToken, AdaptiveGovernance} from "../../src/governance/AdaptiveGovernance.sol";

contract GovernanceTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // 测试minter地址调用mint铸造治理代币成功
    function test_GovToken_Mint_ByMinter() public {
        uint256 before = govToken.balanceOf(alice);
        govToken.mint(alice, 1000e18);
        assertEq(govToken.balanceOf(alice), before + 1000e18);
    }

    // 测试非minter地址调用mint时revert
    function test_Revert_GovToken_Mint_NotMinter() public {
        vm.prank(alice);
        vm.expectRevert(bytes("GovToken: not minter"));
        govToken.mint(alice, 1000e18);
    }

    // 测试设置新的minter后，新minter可以调用mint
    function test_GovToken_SetMinter() public {
        govToken.setMinter(alice);
        assertEq(govToken.minter(), alice);

        vm.prank(alice);
        govToken.mint(bob, 100e18);
        assertEq(govToken.balanceOf(bob), 100e18);
    }

    // 测试burn销毁指定地址的治理代币成功
    function test_GovToken_Burn() public {
        govToken.mint(alice, 1000e18);
        govToken.burn(alice, 500e18);
        assertEq(govToken.balanceOf(alice), 500e18);
    }

    // 测试持有足够代币的用户可以成功发起提案
    function test_Propose_Success() public {
        govToken.mint(alice, 2000e18);

        vm.prank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0 , "test"
        );

        assertEq(id, 1);
        assertEq(governance.proposalCount(), 1);
    }

    // 测试持有代币不足（低于提案阈值）时发起提案revert
    function test_Revert_Propose_InsufficientBalance() public {
        govToken.mint(alice, 500e18);

        vm.prank(alice);
        vm.expectRevert(bytes("Governance: below proposal threshold"));
        governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
    }

    // 测试提案的startBlock和endBlock设置正确（votingDelay和votingPeriod）
    function test_Propose_SetsCorrectBlocks() public {
        govToken.mint(alice, 2000e18);
        uint256 blockBefore = block.number;

        vm.prank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );

        (, , , , , , , uint256 startBlock, uint256 endBlock, , , , ) = governance.proposals(id);
        assertEq(startBlock, blockBefore + governance.votingDelay());
        assertEq(endBlock, startBlock + governance.votingPeriod());
    }

    // 测试用户对提案投赞成票，forVotes正确累加
    function test_CastVote_For() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);

        vm.prank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );

        vm.roll(block.number + governance.votingDelay() + 1);

        vm.prank(bob);
        governance.castVote(id, true);

        (, , , , , , , , , uint256 forVotes, , , ) = governance.proposals(id);
        assertEq(forVotes, 20000e18);
    }

    // 测试用户对提案投反对票，againstVotes正确累加
    function test_CastVote_Against() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);

        vm.prank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );

        vm.roll(block.number + governance.votingDelay() + 1);

        vm.prank(bob);
        governance.castVote(id, false);

        (, , , , , , , , , , uint256 againstVotes, , ) = governance.proposals(id);
        assertEq(againstVotes, 20000e18);
    }

    // 测试同一用户重复投票时revert
    function test_Revert_CastVote_AlreadyVoted() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);

        vm.prank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );

        vm.roll(block.number + governance.votingDelay() + 1);

        vm.startPrank(bob);
        governance.castVote(id, true);
        vm.expectRevert(bytes("Governance: already voted"));
        governance.castVote(id, true);
        vm.stopPrank();

        (, , , , , , , , , uint256 forVotes, , , ) = governance.proposals(id);
        assertEq(forVotes, 20000e18);
    }

    // 测试提案未进入投票期（not active）时投票revert
    function test_Revert_CastVote_NotActive() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);

        vm.prank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );

        vm.prank(bob);
        vm.expectRevert(bytes("Governance: not active"));
        governance.castVote(id, true);

        (, , , , , , , , , uint256 forVotes, , , ) = governance.proposals(id);
        assertEq(forVotes, 0);
    }

    // 测试赞成票超过法定人数后提案状态为Succeeded
    function test_GetProposalState_Succeeded() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);

        vm.prank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );

        vm.roll(block.number + governance.votingDelay() + 1);

        vm.prank(bob);
        governance.castVote(id, true);

        vm.roll(block.number + governance.votingPeriod() + 1);

        (, , , , , , , , , uint256 forVotes, , , ) = governance.proposals(id);
        assertGt(forVotes, 10000e18);

        assertEq(
            uint256(governance.getProposalState(id)),
            uint256(AdaptiveGovernance.ProposalState.Succeeded)
        );
    }

    // 测试赞成票不足时提案状态为Defeated
    function test_GetProposalState_Defeated() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 5000e18);

        vm.prank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );

        vm.roll(block.number + governance.votingDelay() + 1);

        vm.prank(bob);
        governance.castVote(id, true);

        vm.roll(block.number + governance.votingPeriod() + 1);

        (, , , , , , , , , uint256 forVotes, , , ) = governance.proposals(id);
        assertLt(forVotes, 10000e18);

        assertEq(
            uint256(governance.getProposalState(id)),
            uint256(AdaptiveGovernance.ProposalState.Defeated)
        );
    }

    // 测试executeProposal将成功的提案加入时间锁队列
    function test_ExecuteProposal_AddsToTimelock() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);

        vm.prank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );

        vm.roll(block.number + governance.votingDelay() + 1);

        vm.prank(bob);
        governance.castVote(id, true);

        vm.roll(block.number + governance.votingPeriod() + 1);

        governance.executeProposal(id);

        (uint256 readyTime, , , , ) = governance.timelockActions(id);
        assertEq(readyTime, block.timestamp + governance.timelockDelay());
    }

    // 测试时间锁到期后executeTimelock实际应用参数变更
    function test_ExecuteTimelock_AppliesParam() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);

        vm.prank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );

        vm.roll(block.number + governance.votingDelay() + 1);

        vm.prank(bob);
        governance.castVote(id, true);

        vm.roll(block.number + governance.votingPeriod() + 1);

        governance.executeProposal(id);

        uint256 oldWindow = governance.getParams().twapWindow;
        skip(governance.timelockDelay() + 1);
        governance.executeTimelock(id);

        assertEq(governance.getParams().twapWindow, 600);
        assertEq(oldWindow, 1800);
    }

    // 测试时间锁未到期时调用executeTimelock revert
    function test_Revert_ExecuteTimelock_NotReady() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);

        vm.prank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );

        vm.roll(block.number + governance.votingDelay() + 1);

        vm.prank(bob);
        governance.castVote(id, true);

        vm.roll(block.number + governance.votingPeriod() + 1);

        governance.executeProposal(id);

        vm.expectRevert(bytes("Governance: timelock not ready"));
        governance.executeTimelock(id);
    }

    // 测试提案者可以取消自己的提案，状态变为Canceled
    function test_CancelProposal_ByProposer() public {
        govToken.mint(alice, 2000e18);

        vm.startPrank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        governance.cancelProposal(id);
        vm.stopPrank();

        assertEq(
            uint256(governance.getProposalState(id)),
            uint256(AdaptiveGovernance.ProposalState.Canceled)
        );
    }

    // 测试owner直接设置TWAP窗口（绕过治理流程）
    function test_OwnerSetTWAPWindow() public {
        governance.setTWAPWindow(900);
        assertEq(governance.getParams().twapWindow, 900);
    }

    // 测试owner直接设置再平衡阈值
    function test_OwnerSetRebalanceThreshold() public {
        governance.setRebalanceThreshold(1000);
        assertEq(governance.getParams().rebalanceThreshold, 1000);
    }

    // 测试getParams返回所有默认参数值
    function test_GetParams_ReturnsAll() public view {
        AdaptiveGovernance.StrategyParams memory p = governance.getParams();
        assertEq(p.twapWindow, 1800);
        assertEq(p.rebalanceThreshold, 500);
        assertEq(p.incentiveBps, 500);
        assertEq(p.maxSlippageBps, 100);
    }

    // 测试owner直接设置激励比例
    function test_OwnerSetIncentiveBps() public {
        governance.setIncentiveBps(1000);
        assertEq(governance.getParams().incentiveBps, 1000);
    }

    // 测试owner直接设置最大滑点
    function test_OwnerSetMaxSlippageBps() public {
        governance.setMaxSlippageBps(200);
        assertEq(governance.getParams().maxSlippageBps, 200);
    }

    // 测试owner设置V2/V3低/V3高的权重上限
    function test_OwnerSetWeightCaps() public {
        governance.setWeightCaps(3000, 4000, 5000);
        AdaptiveGovernance.StrategyParams memory p = governance.getParams();
        assertEq(p.v2WeightCap, 3000);
        assertEq(p.v3LowFeeWeightCap, 4000);
        assertEq(p.v3HighFeeWeightCap, 5000);
    }

    // 测试owner设置tight/medium/wide范围的比例
    function test_OwnerSetRangeBps() public {
        governance.setRangeBps(2000, 3000, 5000);
        AdaptiveGovernance.StrategyParams memory p = governance.getParams();
        assertEq(p.tightRangeBps, 2000);
        assertEq(p.mediumRangeBps, 3000);
        assertEq(p.wideRangeBps, 5000);
    }

    // 测试owner设置金库地址
    function test_OwnerSetVault() public {
        governance.setVault(address(0x1234));
        assertEq(governance.vault(), address(0x1234));
    }

    // 测试非owner调用setTWAPWindow时revert
    function test_Revert_SetTWAPWindow_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        governance.setTWAPWindow(3600);
    }

    // 测试非owner调用setRebalanceThreshold时revert
    function test_Revert_SetRebalanceThreshold_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        governance.setRebalanceThreshold(1000);
    }

    // 测试非owner调用setIncentiveBps时revert
    function test_Revert_SetIncentiveBps_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        governance.setIncentiveBps(1000);
    }

    // 测试非owner调用setMaxSlippageBps时revert
    function test_Revert_SetMaxSlippageBps_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        governance.setMaxSlippageBps(200);
    }

    // 测试非owner调用setWeightCaps时revert
    function test_Revert_SetWeightCaps_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        governance.setWeightCaps(3000, 4000, 5000);
    }

    // 测试非owner调用setRangeBps时revert
    function test_Revert_SetRangeBps_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        governance.setRangeBps(2000, 3000, 5000);
    }

    // 测试非owner调用setVault时revert
    function test_Revert_SetVault_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        governance.setVault(address(0x1234));
    }

    // 测试非提案者调用cancelProposal时revert
    function test_Revert_CancelProposal_NotProposer() public {
        govToken.mint(alice, 2000e18);
        vm.prank(alice);
        uint256 proposalId = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );

        vm.prank(bob);
        vm.expectRevert();
        governance.cancelProposal(proposalId);
    }

    // 测试对不存在的提案投票时revert
    function test_Revert_CastVote_ProposalNotFound() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Governance: proposal not found"));
        governance.castVote(999, true);
    }

    // 测试无投票权（无代币）的用户投票时revert
    function test_Revert_CastVote_NoVotingPower() public {
        govToken.mint(alice, 2000e18);

        vm.prank(alice);
        uint256 proposalId = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );

        vm.roll(block.number + 2);

        vm.prank(bob);
        vm.expectRevert(bytes("Governance: no voting power"));
        governance.castVote(proposalId, true);
    }

    // 测试查询不存在的提案状态时revert
    function test_Revert_GetProposalState_NotFound() public {
        vm.expectRevert(bytes("Governance: proposal not found"));
        governance.getProposalState(999);
    }

    // 测试取消后的提案状态为Canceled
    function test_GetProposalState_Canceled() public {
        govToken.mint(alice, 2000e18);

        vm.startPrank(alice);
        uint256 proposalId = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        governance.cancelProposal(proposalId);
        vm.stopPrank();

        assertEq(
            uint256(governance.getProposalState(proposalId)),
            uint256(AdaptiveGovernance.ProposalState.Canceled)
        );
    }

    // 测试刚发起的提案状态为Pending（等待投票延迟）
    function test_GetProposalState_Pending() public {
        govToken.mint(alice, 2000e18);

        vm.prank(alice);
        uint256 proposalId = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );

        assertEq(
            uint256(governance.getProposalState(proposalId)),
            uint256(AdaptiveGovernance.ProposalState.Pending)
        );
    }

    // 测试对未成功的提案调用executeProposal时revert
    function test_Revert_ExecuteProposal_NotSucceeded() public {
        govToken.mint(alice, 2000e18);

        vm.prank(alice);
        uint256 proposalId = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );

        vm.expectRevert(bytes("Governance: not succeeded"));
        governance.executeProposal(proposalId);
    }

    // 测试对不存在的时间锁调用executeTimelock时revert
    function test_Revert_ExecuteTimelock_NoTimelock() public {
        vm.expectRevert(bytes("Governance: no timelock"));
        governance.executeTimelock(999);
    }

    // 测试owner可以取消任何提案
    function test_CancelProposal_ByOwner() public {
        govToken.mint(alice, 2000e18);

        vm.prank(alice);
        uint256 proposalId = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );

        governance.cancelProposal(proposalId);
        assertEq(
            uint256(governance.getProposalState(proposalId)),
            uint256(AdaptiveGovernance.ProposalState.Canceled)
        );
    }

    // 测试投票期内提案状态为Active
    function test_GetProposalState_Active() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);

        vm.prank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );

        vm.roll(block.number + governance.votingDelay() + 1);

        assertEq(
            uint256(governance.getProposalState(id)),
            uint256(AdaptiveGovernance.ProposalState.Active)
        );
    }

    // 测试执行提案后状态为Executed
    function test_GetProposalState_Executed() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);

        vm.prank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );

        vm.roll(block.number + governance.votingDelay() + 1);
        vm.prank(bob);
        governance.castVote(id, true);
        vm.roll(block.number + governance.votingPeriod() + 1);

        governance.executeProposal(id);

        assertEq(
            uint256(governance.getProposalState(id)),
            uint256(AdaptiveGovernance.ProposalState.Executed)
        );
    }

    // 测试反对票多于赞成票时提案状态为Defeated
    function test_GetProposalState_Defeated_AgainstMoreThanFor() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);
        govToken.mint(charlie, 30000e18);

        vm.prank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );

        vm.roll(block.number + governance.votingDelay() + 1);

        vm.prank(bob);
        governance.castVote(id, true);
        vm.prank(charlie);
        governance.castVote(id, false);

        vm.roll(block.number + governance.votingPeriod() + 1);

        assertEq(
            uint256(governance.getProposalState(id)),
            uint256(AdaptiveGovernance.ProposalState.Defeated)
        );
    }

    // 测试所有提案类型（SET_REBALANCE_THRESHOLD等）都能通过治理流程成功执行
    function test_ExecuteTimelock_AllProposalTypes() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);

        _testProposalType(AdaptiveGovernance.ProposalType.SET_REBALANCE_THRESHOLD, 800, 0, 0);
        _testProposalType(AdaptiveGovernance.ProposalType.SET_INCENTIVE_BPS, 800, 0, 0);
        _testProposalType(AdaptiveGovernance.ProposalType.SET_MAX_SLIPPAGE, 200, 0, 0);
        _testProposalType(AdaptiveGovernance.ProposalType.SET_WEIGHT_CAPS, 4000, 3000, 5000);
        _testProposalType(AdaptiveGovernance.ProposalType.SET_RANGE_BPS, 500, 1500, 4000);
    }

    function _testProposalType(
        AdaptiveGovernance.ProposalType pType,
        uint256 v1,
        uint256 v2,
        uint256 v3
    ) internal {
        if (pType == AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW) {
            oracle.transferOwnership(address(governance));
        } else if (pType == AdaptiveGovernance.ProposalType.SET_REBALANCE_THRESHOLD) {
            strategy.transferOwnership(address(governance));
        } else if (pType == AdaptiveGovernance.ProposalType.SET_INCENTIVE_BPS) {
            incentives.transferOwnership(address(governance));
        } else if (pType == AdaptiveGovernance.ProposalType.SET_MAX_SLIPPAGE) {
            vault.transferOwnership(address(governance));
        }

        vm.prank(alice);
        uint256 id = governance.propose(pType, v1, v2, v3, "test");

        vm.roll(block.number + governance.votingDelay() + 1);
        vm.prank(bob);
        governance.castVote(id, true);
        vm.roll(block.number + governance.votingPeriod() + 1);

        governance.executeProposal(id);
        skip(governance.timelockDelay() + 1);
        governance.executeTimelock(id);

        AdaptiveGovernance.StrategyParams memory p = governance.getParams();
        if (pType == AdaptiveGovernance.ProposalType.SET_REBALANCE_THRESHOLD) {
            assertEq(p.rebalanceThreshold, v1);
        } else if (pType == AdaptiveGovernance.ProposalType.SET_INCENTIVE_BPS) {
            assertEq(p.incentiveBps, v1);
        } else if (pType == AdaptiveGovernance.ProposalType.SET_MAX_SLIPPAGE) {
            assertEq(p.maxSlippageBps, v1);
        } else if (pType == AdaptiveGovernance.ProposalType.SET_WEIGHT_CAPS) {
            assertEq(p.v2WeightCap, v1);
            assertEq(p.v3LowFeeWeightCap, v2);
            assertEq(p.v3HighFeeWeightCap, v3);
        } else if (pType == AdaptiveGovernance.ProposalType.SET_RANGE_BPS) {
            assertEq(p.tightRangeBps, v1);
            assertEq(p.mediumRangeBps, v2);
            assertEq(p.wideRangeBps, v3);
        }
    }

    // 测试governance作为owner调用目标合约的函数（executeAsOwner）
    function test_ExecuteAsOwner_CallTarget() public {
        incentives.transferOwnership(address(governance));

        bytes memory data = abi.encodeWithSignature("setIncentiveBps(uint256)", 1000);
        governance.executeAsOwner(address(incentives), data);

        assertEq(incentives.incentiveBps(), 1000);
    }

    // 测试executeAsOwner目标地址为0时revert
    function test_Revert_ExecuteAsOwner_ZeroTarget() public {
        vm.expectRevert(bytes("Governance: zero target"));
        governance.executeAsOwner(address(0), "");
    }

    // 测试executeAsOwner调用失败时revert
    function test_Revert_ExecuteAsOwner_CallFailed() public {
        bytes memory data = abi.encodeWithSignature("nonExistentFunction()");
        vm.expectRevert(bytes("Governance: call failed"));
        governance.executeAsOwner(address(incentives), data);
    }

    // 测试owner直接设置参数时，即使目标合约地址为0也不会同步（不revert）
    function test_ApplyParam_ZeroAddressNoSync() public {
        governance.setTWAPWindow(900);
        assertEq(governance.getParams().twapWindow, 900);

        governance.setRebalanceThreshold(800);
        assertEq(governance.getParams().rebalanceThreshold, 800);

        governance.setIncentiveBps(800);
        assertEq(governance.getParams().incentiveBps, 800);

        governance.setMaxSlippageBps(200);
        assertEq(governance.getParams().maxSlippageBps, 200);
    }
}
