// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {GovernanceToken, AdaptiveGovernance} from "../../src/governance/AdaptiveGovernance.sol";
import {AdaptiveRebalanceStrategy} from "../../src/strategies/AdaptiveRebalanceStrategy.sol";

/// @notice PoC：SET_RANGE_BPS 提案通过后链上区间行为完全不变（F-09）
/// @dev 断言方向为"证明缺陷存在"；修复后 strategy 输出应随 params 变化，本测试届时失败
contract POC_GovernanceRangeBps is Test {
    GovernanceToken govToken;
    AdaptiveGovernance governance;
    AdaptiveRebalanceStrategy strategy;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    // WETH/USDC 0.05% 池当前 tick 附近（负值，验证 floor 对齐也走负余数分支）
    int24 constant CURRENT_TICK = -194_000;

    function setUp() public {
        govToken = new GovernanceToken();
        governance = new AdaptiveGovernance(address(govToken));
        strategy = new AdaptiveRebalanceStrategy(address(governance));

        govToken.mint(alice, 2_000e18);
        govToken.mint(bob, 20_000e18);

        vm.prank(alice);
        govToken.delegate(alice);
        vm.prank(bob);
        govToken.delegate(bob);
    }

    function test_RangeBpsProposalDoesNotAffectStrategy() public {
        (int24 tl0, int24 tu0, int24 ml0, int24 mu0, int24 wl0, int24 wu0) =
            strategy.getRangeTicks(CURRENT_TICK);

        // 走完整治理流程：propose -> 投票 -> executeProposal -> 时间锁 -> executeTimelock
        vm.prank(alice);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_RANGE_BPS, 500, 1500, 4000, "test"
        );

        vm.roll(block.number + governance.votingDelay() + 1);
        vm.prank(bob);
        governance.castVote(id, true);
        vm.roll(block.number + governance.votingPeriod() + 1);
        governance.executeProposal(id);
        skip(governance.timelockDelay() + 1);
        governance.executeTimelock(id);

        // 1) params 确实被写入新值
        AdaptiveGovernance.StrategyParams memory p = governance.getParams();
        assertEq(p.tightRangeBps, 500);
        assertEq(p.mediumRangeBps, 1500);
        assertEq(p.wideRangeBps, 4000);

        // 2) 但 strategy 的区间计算完全没有变化 —— 以下断言全部"通过"即为缺陷存在
        (int24 tl1, int24 tu1, int24 ml1, int24 mu1, int24 wl1, int24 wu1) =
            strategy.getRangeTicks(CURRENT_TICK);
        assertEq(tl1, tl0, "F-09: tightLower unchanged");
        assertEq(tu1, tu0, "F-09: tightUpper unchanged");
        assertEq(ml1, ml0, "F-09: mediumLower unchanged");
        assertEq(mu1, mu0, "F-09: mediumUpper unchanged");
        assertEq(wl1, wl0, "F-09: wideLower unchanged");
        assertEq(wu1, wu0, "F-09: wideUpper unchanged");

        console2.log("tightRangeBps after proposal:", p.tightRangeBps);
        console2.log("tightLower before:", int256(tl0));
        console2.log("tightLower after:", int256(tl1));
    }
}
