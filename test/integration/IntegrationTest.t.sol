// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";
import {AdaptiveGovernance} from "../../src/governance/AdaptiveGovernance.sol";

contract IntegrationTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    function test_FullFlow_Deposit_Rebalance_Fees_Withdraw() public {
        uint256 shares = _deposit(alice, 50 ether, 100_000e6);
        assertGt(shares, 0);

        uint256 assetsAfterDeposit = vault.totalAssets();

        vault.rebalance();
        assertEq(vault.rebalanceCount(), 1);
        assertApproxEqRel(vault.totalAssets(), assetsAfterDeposit, 0.01e18);

        v3PoolHighFee.setMockFees(10e18);
        v3PoolLowFee.setMockFees(5e18);

        skip(700);
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 2);

        assertGt(vault.totalAssets(), assetsAfterDeposit, "fees should increase assets");
        assertGt(vault.cumulativeFeesUSDC(), 0, "cumulative fees > 0");

        uint256 wethBefore = weth.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(shares, 0, 0);

        assertGt(wethOut, 0);
        assertGt(usdcOut, 0);
        assertEq(weth.balanceOf(alice), wethBefore + wethOut);
        assertEq(usdc.balanceOf(alice), usdcBefore + usdcOut);
        assertEq(vault.totalSupply(), 0);
    }

    function test_FullFlow_MultipleRebalances_PriceChanges() public {
        _deposit(alice, 50 ether, 100_000e6);
        uint256 initialAssets = vault.totalAssets();

        vault.rebalance();
        (uint256 v2_0, uint256 v3Low_0, uint256 v3High_0) = vault.currentWeights();
        assertEq(v2_0, 1000, "low vol: v2=10%");
        assertEq(v3Low_0, 3000, "low vol: v3Low=30%");
        assertEq(v3High_0, 6000, "low vol: v3High=60%");

        _setPrice(2800);
        skip(700);
        vault.rebalance();
        (uint256 v2_1, uint256 v3Low_1, uint256 v3High_1) = vault.currentWeights();
        assertEq(v2_1, 2500, "medium vol: v2=25%");
        assertEq(v3Low_1, 3000, "medium vol: v3Low=30%");
        assertEq(v3High_1, 4500, "medium vol: v3High=45%");
        assertGt(v2_1, v2_0, "medium vol v2 > low vol v2");

        skip(1801);
        _setPrice(5000);
        vault.rebalance();
        (uint256 v2_2, uint256 v3Low_2, uint256 v3High_2) = vault.currentWeights();
        assertEq(v2_2, 5000, "high vol: v2=50%");
        assertEq(v3Low_2, 2500, "high vol: v3Low=25%");
        assertEq(v3High_2, 2500, "high vol: v3High=25%");
        assertGt(v2_2, v2_1, "high vol v2 > medium vol v2");

        _setPrice(2200);
        skip(1801);
        vault.rebalance();
        (uint256 v2_3, , ) = vault.currentWeights();
        assertLt(v2_3, v2_2, "after pullback v2 < high vol v2");

        assertEq(vault.rebalanceCount(), 4, "should have 4 rebalances");

        assertApproxEqRel(vault.totalAssets(), initialAssets, 0.05e18, "assets conserved");
    }

    function test_FullFlow_IncentiveClaim() public {
        _deposit(alice, 50 ether, 100_000e6);
        vault.rebalance();

        v3PoolHighFee.setMockFees(20e18);
        v3PoolLowFee.setMockFees(10e18);

        skip(700);
        uint256 rewardBefore = incentives.pendingReward(address(this));
        vault.rebalance();
        uint256 rewardAfter = incentives.pendingReward(address(this));

        assertGt(rewardAfter, rewardBefore, "should earn reward");

        uint256 usdcBefore = usdc.balanceOf(address(this));
        incentives.claimReward();
        uint256 usdcAfter = usdc.balanceOf(address(this));

        assertEq(usdcAfter, usdcBefore + rewardAfter - rewardBefore);
        assertEq(incentives.pendingReward(address(this)), 0);
    }

    function test_AllExit_EmptyVault() public {
        uint256 sharesA = _deposit(alice, 5 ether, 10_000e6);
        uint256 sharesB = _deposit(bob, 5 ether, 10_000e6);
        uint256 sharesC = _deposit(charlie, 5 ether, 10_000e6);

        vault.rebalance();

        vm.prank(alice);
        vault.withdrawDual(sharesA, 0, 0);

        vm.prank(bob);
        vault.withdrawDual(sharesB, 0, 0);

        vm.prank(charlie);
        vault.withdrawDual(sharesC, 0, 0);

        assertEq(vault.totalSupply(), 0);
        (uint256 totalW, uint256 totalU) = _getTotalUnderlying();

        assertEq(totalW, 0);
        assertEq(totalU, 0);
    }

    function test_FeesAccumulateOverCycles() public {
        _deposit(alice, 50 ether, 100_000e6);
        vault.rebalance();

        uint256 totalFees = 0;

        for (uint256 i = 0; i < 3; i++) {
            v3PoolHighFee.setMockFees(5e18);
            v3PoolLowFee.setMockFees(2e18);

            skip(700);
            uint256 feesBefore = vault.cumulativeFeesUSDC();
            vault.rebalance();
            uint256 feesAfter = vault.cumulativeFeesUSDC();

            assertGt(feesAfter, feesBefore, "fees should increase each cycle");
            totalFees += (feesAfter - feesBefore);
        }

        assertGt(vault.cumulativeFeesUSDC(), 0);
        assertEq(vault.rebalanceCount(), 4);
    }

    function test_MultipleProposalTypes() public {
        govToken.mint(alice, 2000e18);
        govToken.mint(bob, 20000e18);

        vm.prank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_INCENTIVE_BPS,
            1000, 0, 0, "test"
        );

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
