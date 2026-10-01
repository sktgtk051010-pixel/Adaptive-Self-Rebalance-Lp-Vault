// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";
import {FullMath} from "../../src/libraries/UniswapMath.sol";

contract TeamVestingTest is BaseTest {

    function setUp() public override {
        // 必须在 super.setUp() 之前设置 teamWallet，
        // 因为 BaseTest._deployDistribution() 用它创建 TeamVesting 合约
        teamWallet = alice;
        super.setUp();
    }

    // ============ startVesting ============

    // 测试正常开始锁仓和重复开始锁仓 revert
    function test_StartVestin_AlreadyStarted() public {
        assertEq(teamVesting.startTime(), 0);

        teamVesting.startVesting();
        assertEq(teamVesting.startTime(), block.timestamp);

        vm.expectRevert(bytes("TeamVesting: already started"));
        teamVesting.startVesting();
    }

    // ============ vestedAmount ============

    // 测试未开始时和悬崖期内都返回 0
    function test_VestedAmount_NotStartedAndDuringCliff() public {
        assertEq(teamVesting.vestedAmount(), 0);

        teamVesting.startVesting();
        skip(180 days); 

        assertEq(teamVesting.vestedAmount(), 0);
    }

    // 测试悬崖期刚结束时返回 0
    function test_VestedAmount_AtCliffEnd() public {
        teamVesting.startVesting();
        skip(365 days); 
        assertEq(teamVesting.vestedAmount(), 0);
    }

    // 测试线性释放期中间
    function test_VestedAmount_MidVesting() public {
        teamVesting.startVesting();

        skip(365 days + 547 days); // 悬崖 + 1.5年（释放期的一半）
        uint256 vested = teamVesting.vestedAmount();
        // 应该约等于总量的一半
        uint256 expected = FullMath.mulDiv(2_000_000e18, 547 days, 1095 days);
        assertApproxEqAbs(vested, expected, 1e18);
    }

    // 测试释放期结束返回总量
    function test_VestedAmount_AfterVestingEnd() public {
        teamVesting.startVesting();
        skip(365 days + 1095 days + 1); // 悬崖 + 释放期 + 1秒
        assertEq(teamVesting.vestedAmount(), 2_000_000e18);
    }

    // ============ claim ============

    // 测试团队钱包正常领取
    function test_Claim_Normal() public {
        teamVesting.startVesting();

        skip(365 days + 365 days); // 悬崖 + 1年释放
        uint256 claimable = teamVesting.vestedAmount();
        uint256 balanceBefore = govToken.balanceOf(alice);

        vm.prank(alice);
        teamVesting.claim();

        uint256 balanceAfter = govToken.balanceOf(alice);
        assertEq(balanceAfter - balanceBefore, claimable);
        assertEq(teamVesting.releasedAmount(), claimable);
    }

    // 测试非团队钱包领取 revert
    function test_Revert_Claim_NotTeamWallet() public {
        teamVesting.startVesting();

        skip(365 days + 365 days);

        vm.prank(bob);
        vm.expectRevert(bytes("TeamVesting: not team wallet"));
        teamVesting.claim();
    }

    // 测试未开始时和悬崖期内领取 revert
    function test_Revert_Claim_NotStartedAndDuringCliff() public {
        vm.prank(alice);
        vm.expectRevert(bytes("TeamVesting: not started"));
        teamVesting.claim();

        teamVesting.startVesting();

        skip(180 days);

        vm.prank(alice);
        vm.expectRevert(bytes("TeamVesting: nothing to claim"));
        teamVesting.claim();
    }

    // 测试重复领取 revert（已领完）
    function test_Revert_Claim_AlreadyClaimed() public {
        teamVesting.startVesting();

        skip(365 days + 1095 days + 1);
        vm.prank(alice);
        teamVesting.claim();

        // 全部释放量已领完，再次领取应 revert
        vm.prank(alice);
        vm.expectRevert(bytes("TeamVesting: nothing to claim"));
        teamVesting.claim();

        // releasedAmount 应等于全部释放总量
        assertEq(teamVesting.releasedAmount(), 2_000_000e18);
    }

    // 测试分批领取
    function test_Claim_MultipleTimes() public {
        teamVesting.startVesting();

        skip(365 days + 365 days);
        uint256 firstClaim = teamVesting.vestedAmount();
        vm.prank(alice);
        teamVesting.claim();

        skip(365 days);
        uint256 secondClaim = teamVesting.vestedAmount() - teamVesting.releasedAmount();
        vm.prank(alice);
        teamVesting.claim();

        assertEq(teamVesting.releasedAmount(), firstClaim + secondClaim);
    }

    // ============ released ============

    // 测试初始已领取为 0
    function test_Released_Initial() public {
        assertEq(teamVesting.released(), 0);
    }

}
