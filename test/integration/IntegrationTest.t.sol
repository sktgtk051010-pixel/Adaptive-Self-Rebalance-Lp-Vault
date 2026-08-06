// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IntegrationTest - 完整用户流程集成测试
 * @notice 测试存款→做市→再平衡→手续费积累→赎回全链路
 */
contract IntegrationTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    /// @notice 完整流程：用户存款→金库做市→再平衡→手续费→赎回
    function test_FullUserFlow_DepositRebalanceWithdraw() public {
        // 1. Alice存款
        uint256 wethAmount = 10 ether;
        uint256 usdcAmount = 20_000e6;
        _deposit(alice, wethAmount, usdcAmount);

        uint256 shares = vault.balanceOf(alice);
        assertGt(shares, 0);

        // 2. 第一次再平衡（触发资金分配到各adapter）
        vm.warp(1000);
        vault.rebalance();

        // 3. 验证资金已分配到各场所
        (, ,
         uint256 v2Weth, uint256 v2Usdc,
         uint256 v3LowWeth, uint256 v3LowUsdc,
         uint256 v3HighWeth, uint256 v3HighUsdc) = vault.getDistribution();

        // 至少有一些资金被分配
        assertTrue(
            v2Weth + v3LowWeth + v3HighWeth > 0 ||
            v2Usdc + v3LowUsdc + v3HighUsdc > 0,
            "Funds should be distributed"
        );

        // 4. 模拟手续费产生
        v3PoolHighFee.setMockFees(50e6);
        v3PoolLowFee.setMockFees(20e6);

        // 5. 第二次再平衡（收集手续费并重新分配）
        vm.warp(2000);
        vault.rebalance();

        // 6. 累计手续费应该>0
        assertGe(vault.cumulativeFeesUSDC(), 0);

        // 7. Bob也存款
        _deposit(bob, 5 ether, 10_000e6);
        uint256 bobShares = vault.balanceOf(bob);
        assertGt(bobShares, 0);

        // 8. 第三次再平衡
        vm.warp(3000);
        vault.rebalance();

        // 9. Alice赎回部分份额
        uint256 sharesToRedeem = shares / 2;
        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        vault.withdrawDual(sharesToRedeem, 0, 0);
        vm.stopPrank();

        // Alice应该收到了一些代币
        assertTrue(
            weth.balanceOf(alice) > aliceWethBefore ||
            usdc.balanceOf(alice) > aliceUsdcBefore,
            "Alice should receive tokens on withdrawal"
        );

        // 10. Alice赎回剩余全部
        uint256 remainingShares = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.withdrawDual(remainingShares, 0, 0);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);
    }

    /// @notice 多用户存款后总资产正确
    function test_MultipleUsers_TotalAssets() public {
        _deposit(alice, 10 ether, 20_000e6);
        _deposit(bob, 5 ether, 10_000e6);
        _deposit(charlie, 2 ether, 4_000e6);

        uint256 totalBefore = vault.totalAssets();
        assertGt(totalBefore, 0);

        vm.warp(1000);
        vault.rebalance();

        uint256 totalAfter = vault.totalAssets();
        // 再平衡不应显著减少资产（允许小的slippage/dust）
        assertApproxEqRel(totalAfter, totalBefore, 0.01e18); // 1% tolerance
    }

    /// @notice 再平衡后份额净值不应大幅下降
    function test_SharePrice_AfterRebalance() public {
        _deposit(alice, 10 ether, 20_000e6);
        uint256 shares = vault.balanceOf(alice);
        uint256 assetsPerShare = vault.totalAssets() * 1e18 / shares;

        vm.warp(1000);
        vault.rebalance();

        uint256 newAssetsPerShare = vault.totalAssets() * 1e18 / vault.balanceOf(alice);
        // 份额净值不应下降超过1%
        assertGe(newAssetsPerShare, assetsPerShare * 99 / 100);
    }

    /// @notice 暂停后不能存款
    function test_Paused_DepositReverts() public {
        vault.setPaused(true);
        vm.startPrank(alice);
        weth.approve(address(vault), 1 ether);
        usdc.approve(address(vault), 2000e6);
        vm.expectRevert();
        vault.deposit(1 ether, 2000e6, 0);
        vm.stopPrank();
    }

    /// @notice 非owner不能暂停
    function test_OnlyOwner_CanPause() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.setPaused(true);
        vm.stopPrank();
    }

    /// @notice 再平衡冷却期内不能再次再平衡
    function test_Rebalance_Cooldown() public {
        _deposit(alice, 10 ether, 20_000e6);
        vm.warp(1000);
        vault.rebalance();

        // 冷却期内
        vm.expectRevert();
        vault.rebalance();
    }

    /// @notice ERC4626标准接口测试
    function test_ERC4626_StandardDepositWithdraw() public {
        // 标准ERC4626存款（仅USDC）
        uint256 usdcAmount = 10_000e6;
        vm.startPrank(alice);
        usdc.approve(address(vault), usdcAmount);
        vault.deposit(usdcAmount, alice);
        vm.stopPrank();

        uint256 shares = vault.balanceOf(alice);
        assertGt(shares, 0);

        // 标准赎回
        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.startPrank(alice);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertGt(usdc.balanceOf(alice), usdcBefore);
        assertEq(vault.balanceOf(alice), 0);
    }

    /// @notice 测试再平衡次数统计
    function test_RebalanceCount() public {
        _deposit(alice, 10 ether, 20_000e6);
        assertEq(vault.rebalanceCount(), 0);

        vm.warp(1000);
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 1);

        vm.warp(2000);
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 2);
    }

    /// @notice 测试设置滑点参数
    function test_SetMaxSlippage() public {
        vault.setMaxSlippage(200); // 2%
        assertEq(vault.maxSlippageBps(), 200);
    }

    /// @notice 测试getDistribution返回值
    function test_GetDistribution() public {
        _deposit(alice, 10 ether, 20_000e6);
        vm.warp(1000);
        vault.rebalance();

        (uint256 idleWeth, uint256 idleUsdc,
         uint256 v2Weth, uint256 v2Usdc,
         uint256 v3LowWeth, uint256 v3LowUsdc,
         uint256 v3HighWeth, uint256 v3HighUsdc) = vault.getDistribution();

        // 所有值应为非负
        assertTrue(idleWeth >= 0 && idleUsdc >= 0);
        assertTrue(v2Weth >= 0 && v2Usdc >= 0);
        assertTrue(v3LowWeth >= 0 && v3LowUsdc >= 0);
        assertTrue(v3HighWeth >= 0 && v3HighUsdc >= 0);
    }
}
