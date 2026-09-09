// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";
import {GovernanceToken, AdaptiveGovernance} from "../../src/governance/AdaptiveGovernance.sol";

contract GovernanceTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    function test_GovToken_Mint_ByMinter() public {
        uint256 before = govToken.balanceOf(alice);
        govToken.mint(alice, 1000e18);
        assertEq(govToken.balanceOf(alice), before + 1000e18);
    }

    function test_Revert_GovToken_Mint_NotMinter() public {
        vm.prank(alice);
        vm.expectRevert(bytes("GovToken: not minter"));
        govToken.mint(alice, 1000e18);
    }

    function test_GovToken_SetMinter() public {
        govToken.setMinter(alice);
        assertEq(govToken.minter(), alice);

        vm.prank(alice);
        govToken.mint(bob, 100e18);
        assertEq(govToken.balanceOf(bob), 100e18);
    }

    function test_GovToken_Burn() public {
        govToken.mint(alice, 1000e18);
        govToken.burn(alice, 500e18);
        assertEq(govToken.balanceOf(alice), 500e18);
    }

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

    function test_Revert_Propose_InsufficientBalance() public {
        govToken.mint(alice, 500e18);

        vm.prank(alice);
        vm.expectRevert(bytes("Governance: below proposal threshold"));
        governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
    }

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

    function test_OwnerSetTWAPWindow() public {
        governance.setTWAPWindow(900);
        assertEq(governance.getParams().twapWindow, 900);
    }

    function test_OwnerSetRebalanceThreshold() public {
        governance.setRebalanceThreshold(1000);
        assertEq(governance.getParams().rebalanceThreshold, 1000);
    }

    function test_GetParams_ReturnsAll() public view {
        AdaptiveGovernance.StrategyParams memory p = governance.getParams();
        assertEq(p.twapWindow, 1800);
        assertEq(p.rebalanceThreshold, 500);
        assertEq(p.incentiveBps, 500);
        assertEq(p.maxSlippageBps, 100);
    }

    function test_OwnerSetIncentiveBps() public {
        governance.setIncentiveBps(1000);
        assertEq(governance.getParams().incentiveBps, 1000);
    }

    function test_OwnerSetMaxSlippageBps() public {
        governance.setMaxSlippageBps(200);
        assertEq(governance.getParams().maxSlippageBps, 200);
    }

    function test_OwnerSetWeightCaps() public {
        governance.setWeightCaps(3000, 4000, 5000);
        AdaptiveGovernance.StrategyParams memory p = governance.getParams();
        assertEq(p.v2WeightCap, 3000);
        assertEq(p.v3LowFeeWeightCap, 4000);
        assertEq(p.v3HighFeeWeightCap, 5000);
    }

    function test_OwnerSetRangeBps() public {
        governance.setRangeBps(2000, 3000, 5000);
        AdaptiveGovernance.StrategyParams memory p = governance.getParams();
        assertEq(p.tightRangeBps, 2000);
        assertEq(p.mediumRangeBps, 3000);
        assertEq(p.wideRangeBps, 5000);
    }

    function test_OwnerSetVault() public {
        governance.setVault(address(0x1234));
        assertEq(governance.vault(), address(0x1234));
    }

    function test_Revert_SetTWAPWindow_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        governance.setTWAPWindow(3600);
    }

    function test_Revert_SetRebalanceThreshold_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        governance.setRebalanceThreshold(1000);
    }

    function test_Revert_SetIncentiveBps_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        governance.setIncentiveBps(1000);
    }

    function test_Revert_SetMaxSlippageBps_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        governance.setMaxSlippageBps(200);
    }

    function test_Revert_SetWeightCaps_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        governance.setWeightCaps(3000, 4000, 5000);
    }

    function test_Revert_SetRangeBps_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        governance.setRangeBps(2000, 3000, 5000);
    }

    function test_Revert_SetVault_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        governance.setVault(address(0x1234));
    }

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

    function test_Revert_CastVote_ProposalNotFound() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Governance: proposal not found"));
        governance.castVote(999, true);
    }

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

    function test_Revert_GetProposalState_NotFound() public {
        vm.expectRevert(bytes("Governance: proposal not found"));
        governance.getProposalState(999);
    }

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

    function test_Revert_ExecuteTimelock_NoTimelock() public {
        vm.expectRevert(bytes("Governance: no timelock"));
        governance.executeTimelock(999);
    }

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

    function test_ExecuteAsOwner_CallTarget() public {
        incentives.transferOwnership(address(governance));

        bytes memory data = abi.encodeWithSignature("setIncentiveBps(uint256)", 1000);
        governance.executeAsOwner(address(incentives), data);

        assertEq(incentives.incentiveBps(), 1000);
    }

    function test_Revert_ExecuteAsOwner_ZeroTarget() public {
        vm.expectRevert(bytes("Governance: zero target"));
        governance.executeAsOwner(address(0), "");
    }

    function test_Revert_ExecuteAsOwner_CallFailed() public {
        bytes memory data = abi.encodeWithSignature("nonExistentFunction()");
        vm.expectRevert(bytes("Governance: call failed"));
        governance.executeAsOwner(address(incentives), data);
    }

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
