// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";
import {GovernanceToken, AdaptiveGovernance} from "../../src/governance/AdaptiveGovernance.sol";

/**
 * @title GovernanceTest
 * @notice 治理模块专项测试
 */
contract GovernanceTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // ============ GovernanceToken ============

    /// @notice minter可以mint
    function test_GovToken_Mint_ByMinter() public {
        uint256 before = govToken.balanceOf(alice);
        govToken.mint(alice, 1000e18);
        assertEq(govToken.balanceOf(alice), before + 1000e18);
    }

    /// @notice 非minter不能mint
    function test_Revert_GovToken_Mint_NotMinter() public {
        vm.startPrank(alice);
        vm.expectRevert(bytes("GovToken: not minter"));
        govToken.mint(alice, 1000e18);
        vm.stopPrank();
    }

    /// @notice setMinter更换minter
    function test_GovToken_SetMinter() public {
        govToken.setMinter(alice);
        assertEq(govToken.minter(), alice);
        vm.startPrank(alice);
        govToken.mint(bob, 100e18);
        vm.stopPrank();
        assertEq(govToken.balanceOf(bob), 100e18);
    }

    /// @notice minter可以burn
    function test_GovToken_Burn() public {
        govToken.mint(alice, 1000e18);
        govToken.burn(alice, 500e18);
        assertEq(govToken.balanceOf(alice), 500e18);
    }

    // ============ 提案 ============

    /// @notice 持有足够代币可以提案
    function test_Propose_Success() public {
        govToken.mint(alice, 2000e18);
        vm.startPrank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        vm.stopPrank();
        assertEq(id, 1);
        assertEq(governance.proposalCount(), 1);
    }

    /// @notice 余额不足不能提案
    function test_Revert_Propose_InsufficientBalance() public {
        govToken.mint(alice, 500e18); // < 1000e18
        vm.startPrank(alice);
        vm.expectRevert(bytes("Governance: below proposal threshold"));
        governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        vm.stopPrank();
    }

    /// @notice 提案设置正确的start/end block
    function test_Propose_SetsStartEndBlock() public view {
        // 已在setUp中创建了提案吗？没有，需要先创建
        // 这个测试需要先提案，所以改为非view
    }

    function test_Propose_SetsCorrectBlocks() public {
        govToken.mint(alice, 2000e18);
        uint256 blockBefore = block.number;
        vm.startPrank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        vm.stopPrank();

        (, , , , , , uint256 startBlock, uint256 endBlock, , , , ) = governance.proposals(id);
        assertEq(startBlock, blockBefore + governance.votingDelay());
        assertEq(endBlock, startBlock + governance.votingPeriod());
    }

    // ============ 投票 ============

    /// @notice 投票赞成
    function test_CastVote_For() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);
        vm.startPrank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        vm.stopPrank();

        // 快进到投票期
        vm.roll(block.number + governance.votingDelay() + 1);

        vm.startPrank(bob);
        governance.castVote(id, true);
        vm.stopPrank();

        (, , , , , , , , uint256 forVotes, , , ) = governance.proposals(id);
        assertEq(forVotes, 20000e18);
    }

    /// @notice 投票反对
    function test_CastVote_Against() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);
        vm.startPrank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        vm.stopPrank();

        vm.roll(block.number + governance.votingDelay() + 1);

        vm.startPrank(bob);
        governance.castVote(id, false);
        vm.stopPrank();

        (, , , , , , , , , uint256 againstVotes, , ) = governance.proposals(id);
        assertEq(againstVotes, 20000e18);
    }

    /// @notice 重复投票revert
    function test_Revert_CastVote_AlreadyVoted() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);
        vm.startPrank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        vm.stopPrank();

        vm.roll(block.number + governance.votingDelay() + 1);

        vm.startPrank(bob);
        governance.castVote(id, true);
        vm.expectRevert(bytes("Governance: already voted"));
        governance.castVote(id, true);
        vm.stopPrank();
    }

    /// @notice 非投票期投票revert
    function test_Revert_CastVote_NotActive() public {
        govToken.mint(alice, 2000e18);
        vm.startPrank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        // 立即投票（还在pending期）
        vm.expectRevert(bytes("Governance: not active"));
        governance.castVote(id, true);
        vm.stopPrank();
    }

    // ============ 状态与执行 ============

    /// @notice 通过的提案状态为Succeeded
    function test_GetProposalState_Succeeded() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18); // >= quorum 10000e18
        vm.startPrank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        vm.stopPrank();

        vm.roll(block.number + governance.votingDelay() + 1);
        vm.startPrank(bob);
        governance.castVote(id, true);
        vm.stopPrank();

        // 快进到投票结束
        vm.roll(block.number + governance.votingPeriod() + 1);

        assertEq(
            uint256(governance.getProposalState(id)),
            uint256(AdaptiveGovernance.ProposalState.Succeeded)
        );
    }

    /// @notice 未通过的提案状态为Defeated
    function test_GetProposalState_Defeated() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 5000e18); // < quorum
        vm.startPrank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        vm.stopPrank();

        vm.roll(block.number + governance.votingDelay() + 1);
        vm.startPrank(bob);
        governance.castVote(id, true);
        vm.stopPrank();

        vm.roll(block.number + governance.votingPeriod() + 1);

        assertEq(
            uint256(governance.getProposalState(id)),
            uint256(AdaptiveGovernance.ProposalState.Defeated)
        );
    }

    /// @notice 执行提案加入时间锁
    function test_ExecuteProposal_AddsToTimelock() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);
        vm.startPrank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        vm.stopPrank();

        vm.roll(block.number + governance.votingDelay() + 1);
        vm.startPrank(bob);
        governance.castVote(id, true);
        vm.stopPrank();
        vm.roll(block.number + governance.votingPeriod() + 1);

        governance.executeProposal(id);

        (uint256 readyTime, , , , ) = governance.timelockActions(id);
        assertEq(readyTime, block.timestamp + governance.timelockDelay());
    }

    /// @notice 时间锁到期后参数生效
    function test_ExecuteTimelock_AppliesParam() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);
        vm.startPrank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        vm.stopPrank();

        vm.roll(block.number + governance.votingDelay() + 1);
        vm.startPrank(bob);
        governance.castVote(id, true);
        vm.stopPrank();
        vm.roll(block.number + governance.votingPeriod() + 1);

        governance.executeProposal(id);

        uint256 oldWindow = governance.getParams().twapWindow;
        skip(governance.timelockDelay() + 1);
        governance.executeTimelock(id);

        assertEq(governance.getParams().twapWindow, 600);
        assertNotEq(oldWindow, 600);
    }

    /// @notice 时间锁未到期revert
    function test_Revert_ExecuteTimelock_NotReady() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);
        vm.startPrank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        vm.stopPrank();

        vm.roll(block.number + governance.votingDelay() + 1);
        vm.startPrank(bob);
        governance.castVote(id, true);
        vm.stopPrank();
        vm.roll(block.number + governance.votingPeriod() + 1);

        governance.executeProposal(id);

        // 立即执行（未到期）
        vm.expectRevert(bytes("Governance: timelock not ready"));
        governance.executeTimelock(id);
    }

    /// @notice 提案者可以取消提案
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

    // ============ owner直接设置参数 ============

    /// @notice owner可以直接设置参数
    function test_OwnerSetTWAPWindow() public {
        governance.setTWAPWindow(900);
        assertEq(governance.getParams().twapWindow, 900);
    }

    /// @notice owner可以设置rebalance阈值
    function test_OwnerSetRebalanceThreshold() public {
        governance.setRebalanceThreshold(1000);
        assertEq(governance.getParams().rebalanceThreshold, 1000);
    }

    /// @notice getParams返回完整参数
    function test_GetParams_ReturnsAll() public view {
        AdaptiveGovernance.StrategyParams memory p = governance.getParams();
        assertEq(p.twapWindow, 1800);
        assertEq(p.rebalanceThreshold, 500);
        assertEq(p.incentiveBps, 500);
        assertEq(p.maxSlippageBps, 100);
    }

    /// @notice owner设置incentiveBps
    function test_OwnerSetIncentiveBps() public {
        governance.setIncentiveBps(1000);
        assertEq(governance.getParams().incentiveBps, 1000);
    }

    /// @notice owner设置maxSlippageBps
    function test_OwnerSetMaxSlippageBps() public {
        governance.setMaxSlippageBps(200);
        assertEq(governance.getParams().maxSlippageBps, 200);
    }

    /// @notice owner设置weightCaps
    function test_OwnerSetWeightCaps() public {
        governance.setWeightCaps(3000, 4000, 5000);
        AdaptiveGovernance.StrategyParams memory p = governance.getParams();
        assertEq(p.v2WeightCap, 3000);
        assertEq(p.v3LowFeeWeightCap, 4000);
        assertEq(p.v3HighFeeWeightCap, 5000);
    }

    /// @notice owner设置rangeBps
    function test_OwnerSetRangeBps() public {
        governance.setRangeBps(2000, 3000, 5000);
        AdaptiveGovernance.StrategyParams memory p = governance.getParams();
        assertEq(p.tightRangeBps, 2000);
        assertEq(p.mediumRangeBps, 3000);
        assertEq(p.wideRangeBps, 5000);
    }

    /// @notice owner设置vault
    function test_OwnerSetVault() public {
        governance.setVault(address(0x1234));
        // 无法直接读取vault地址，但不会revert
    }

    /// @notice 非owner设置TWAPWindow revert
    function test_Revert_SetTWAPWindow_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        governance.setTWAPWindow(3600);
        vm.stopPrank();
    }

    /// @notice 非owner设置RebalanceThreshold revert
    function test_Revert_SetRebalanceThreshold_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        governance.setRebalanceThreshold(1000);
        vm.stopPrank();
    }

    /// @notice 非owner设置IncentiveBps revert
    function test_Revert_SetIncentiveBps_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        governance.setIncentiveBps(1000);
        vm.stopPrank();
    }

    /// @notice 非owner设置MaxSlippageBps revert
    function test_Revert_SetMaxSlippageBps_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        governance.setMaxSlippageBps(200);
        vm.stopPrank();
    }

    /// @notice 非owner设置WeightCaps revert
    function test_Revert_SetWeightCaps_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        governance.setWeightCaps(3000, 4000, 5000);
        vm.stopPrank();
    }

    /// @notice 非owner设置RangeBps revert
    function test_Revert_SetRangeBps_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        governance.setRangeBps(2000, 3000, 5000);
        vm.stopPrank();
    }

    /// @notice 非owner设置Vault revert
    function test_Revert_SetVault_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        governance.setVault(address(0x1234));
        vm.stopPrank();
    }

    /// @notice 非proposer取消提案revert
    function test_Revert_CancelProposal_NotProposer() public {
        govToken.mint(alice, 2000e18);
        vm.startPrank(alice);
        uint256 proposalId = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert();
        governance.cancelProposal(proposalId);
        vm.stopPrank();
    }

    /// @notice 投票不存在的提案revert
    function test_Revert_CastVote_ProposalNotFound() public {
        vm.startPrank(alice);
        vm.expectRevert(bytes("Governance: proposal not found"));
        governance.castVote(999, true);
        vm.stopPrank();
    }

    /// @notice 没有投票权revert
    function test_Revert_CastVote_NoVotingPower() public {
        // 创建提案
        govToken.mint(alice, 2000e18);
        vm.startPrank(alice);
        uint256 proposalId = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        vm.stopPrank();

        // 跳过到投票期
        vm.roll(block.number + 2);

        // bob没有代币，投票权为0
        vm.startPrank(bob);
        vm.expectRevert(bytes("Governance: no voting power"));
        governance.castVote(proposalId, true);
        vm.stopPrank();
    }

    /// @notice 查询不存在的提案状态revert
    function test_Revert_GetProposalState_NotFound() public {
        vm.expectRevert(bytes("Governance: proposal not found"));
        governance.getProposalState(999);
    }

    /// @notice 提案被取消后状态为Canceled
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

    /// @notice 提案在Pending状态
    function test_GetProposalState_Pending() public {
        govToken.mint(alice, 2000e18);
        vm.startPrank(alice);
        uint256 proposalId = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        vm.stopPrank();

        // 刚创建时是Pending状态（votingDelay=1）
        assertEq(
            uint256(governance.getProposalState(proposalId)),
            uint256(AdaptiveGovernance.ProposalState.Pending)
        );
    }

    /// @notice 执行未成功的提案revert
    function test_Revert_ExecuteProposal_NotSucceeded() public {
        govToken.mint(alice, 2000e18);
        vm.startPrank(alice);
        uint256 proposalId = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        vm.stopPrank();

        // Pending状态下执行revert
        vm.expectRevert(bytes("Governance: not succeeded"));
        governance.executeProposal(proposalId);
    }

    /// @notice 执行不存在的timelock revert
    function test_Revert_ExecuteTimelock_NoTimelock() public {
        vm.expectRevert(bytes("Governance: no timelock"));
        governance.executeTimelock(999);
    }

    /// @notice owner可以取消提案
    function test_CancelProposal_ByOwner() public {
        govToken.mint(alice, 2000e18);
        vm.startPrank(alice);
        uint256 proposalId = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test"
        );
        vm.stopPrank();

        // owner（测试合约本身）取消
        governance.cancelProposal(proposalId);
        assertEq(
            uint256(governance.getProposalState(proposalId)),
            uint256(AdaptiveGovernance.ProposalState.Canceled)
        );
    }
}
