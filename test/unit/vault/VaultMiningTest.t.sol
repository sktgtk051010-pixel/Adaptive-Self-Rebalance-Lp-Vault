// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../../base/BaseTest.t.sol";
import {LiquidityMining} from "../../../src/distribution/LiquidityMining.sol";

contract VaultMiningTest is BaseTest {

    function setUp() public override {
        super.setUp();
        mining.startMining();
        vault.setLiquidityMining(address(mining));
    }

    // ============ setLiquidityMining ============

    // 测试 owner 正常设置挖矿合约地址
    function test_SetLiquidityMining_Normal() public {
        address newMining = address(new LiquidityMining(address(govToken), address(vault)));
        vault.setLiquidityMining(newMining);
        assertEq(address(vault.liquidityMining()), newMining);
    }

    // 测试非 owner 设置挖矿合约 revert
    function test_Revert_SetLiquidityMining_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setLiquidityMining(address(mining));
    }

    // ============ 存款时同步份额到挖矿合约 ============

    // 测试存款后挖矿合约里用户份额正确更新
    function test_Deposit_UpdatesMiningBalance() public {
        assertEq(mining.balanceOf(alice), 0);

        uint256 shares = _deposit(alice, 10 ether, 20_000e6);

        assertEq(mining.balanceOf(alice), shares);
        assertEq(mining.totalShares(), shares);
    }

    // ============ 取款时同步份额到挖矿合约 ============

    // 测试部分取款后挖矿合约份额正确减少
    function test_Withdraw_Partial_UpdatesMiningBalance() public {
        uint256 shares = _deposit(alice, 20 ether, 40_000e6);
        uint256 withdrawShares = shares / 2;

        vm.prank(alice);
        vault.withdrawDual(withdrawShares, 0, 0);

        assertEq(mining.balanceOf(alice), shares - withdrawShares);
        assertEq(mining.totalShares(), shares - withdrawShares);
    }

    // 测试全部取款后挖矿合约份额归零
    function test_Withdraw_All_BalanceBecomesZero() public {
        uint256 shares = _deposit(alice, 10 ether, 20_000e6);

        vm.prank(alice);
        vault.withdrawDual(shares, 0, 0);

        assertEq(mining.balanceOf(alice), 0);
        assertEq(mining.totalShares(), 0);
    }

    // ============ ERC4626 标准接口也同步份额 ============

    // 测试 ERC4626 deposit 也同步挖矿份额
    function test_ERC4626Deposit_UpdatesMiningBalance() public {
        uint256 usdcAmt = 20_000e6;
        usdc.mint(alice, usdcAmt);
        vm.prank(alice);
        usdc.approve(address(vault), usdcAmt);

        vm.prank(alice);
        uint256 shares = vault.deposit(usdcAmt, alice);

        assertEq(mining.balanceOf(alice), shares);
    }

    // 测试 ERC4626 mint 也同步挖矿份额
    function test_ERC4626Mint_UpdatesMiningBalance() public {
        uint256 shares = 1e18;
        uint256 assets = vault.previewMint(shares);
        usdc.mint(alice, assets);
        vm.prank(alice);
        usdc.approve(address(vault), assets);

        vm.prank(alice);
        vault.mint(shares, alice);

        assertEq(mining.balanceOf(alice), shares);
    }

    // ============ 挖矿奖励累积 ============

    // 测试存款后随时间推移待领奖励增加
    function test_Deposit_RewardsAccumulateOverTime() public {
        _deposit(alice, 10 ether, 20_000e6);

        uint256 pending1 = mining.pendingReward(alice);
        skip(1 days);
        uint256 pending2 = mining.pendingReward(alice);

        assertGt(pending2, pending1);
    }

    // 测试取款时自动结算之前累积的奖励
    function test_Withdraw_AutoSettlesRewards() public {
        _deposit(alice, 10 ether, 20_000e6);
        skip(1 days);

        uint256 balanceBefore = govToken.balanceOf(alice);
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.withdrawDual(shares, 0, 0);

        uint256 balanceAfter = govToken.balanceOf(alice);
        assertGt(balanceAfter, balanceBefore);
    }

    // 测试用户可以主动领取挖矿奖励
    function test_ClaimMiningReward() public {
        _deposit(alice, 10 ether, 20_000e6);
        skip(1 days);

        uint256 pending = mining.pendingReward(alice);
        assertGt(pending, 0);

        uint256 balanceBefore = govToken.balanceOf(alice);
        vm.prank(alice);
        mining.claimReward();
        uint256 balanceAfter = govToken.balanceOf(alice);

        assertEq(balanceAfter - balanceBefore, pending);
        assertEq(mining.pendingReward(alice), 0);
    }

    // ============ 挖矿合约异常容错（try-catch） ============

    /// @notice 运行时容错：挖矿合约执行 revert，存款不被阻断（try-catch 生效）
    function test_MiningContractRevert_DepositStillSucceeds() public {
        MockRevertMining badMining = new MockRevertMining();
        vault.setLiquidityMining(address(badMining));

        uint256 shares = _deposit(alice, 10 ether, 20_000e6);
        assertGt(shares, 0);
    }

    /// @notice 运行时容错：挖矿合约执行 revert，取款不被阻断（try-catch 生效）
    function test_MiningContractRevert_WithdrawStillSucceeds() public {
        uint256 shares = _deposit(alice, 10 ether, 20_000e6);

        MockRevertMining badMining = new MockRevertMining();
        vault.setLiquidityMining(address(badMining));

        vm.prank(alice);
        vault.withdrawDual(shares, 0, 0);

        assertEq(vault.balanceOf(alice), 0);
    }
}

// ============ 辅助合约 ============

/// @notice 模拟挖矿合约运行时报错（bug/revert），用于验证金库 try-catch 容错
contract MockRevertMining {
    function updateBalance(address, uint256) external pure {
        revert("mock mining bug");
    }
}
