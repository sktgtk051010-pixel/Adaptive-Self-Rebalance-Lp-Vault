// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../../base/BaseTest.t.sol";
import {AdaptiveLPVault} from "../../../src/vault/AdaptiveLPVault.sol";

contract VaultRebalanceTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // 测试首次再平衡无冷却期限制，rebalanceCount从0变为1
    function test_Rebalance_FirstTime_NoCooldown() public {
        _deposit(alice, 20 ether, 40_000e6);
        assertEq(vault.rebalanceCount(), 0);
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 1);
    }

    // 测试再平衡后rebalanceCount递增且lastRebalanceTimestamp被更新
    function test_Rebalance_EmitRebalancedEvent() public {
        _deposit(alice, 20 ether, 40_000e6);
        uint256 countBefore = vault.rebalanceCount();

        vault.rebalance();

        assertEq(vault.rebalanceCount(), countBefore + 1);
        assertGt(vault.lastRebalanceTimestamp(), 0);
    }

    // 测试价格变动后再平衡会更新V2/V3低/V3高的权重分配，且权重之和为10000
    function test_Rebalance_EmitWeightsUpdated() public {
        _deposit(alice, 20 ether, 40_000e6);

        (uint256 v2Before, uint256 v3LowBefore, uint256 v3HighBefore) = vault.currentWeights();

        _setPrice(2500);
        skip(700);

        vault.rebalance();

        (uint256 v2After, uint256 v3LowAfter, uint256 v3HighAfter) = vault.currentWeights();
        assertTrue(
            v2After != v2Before || v3LowAfter != v3LowBefore || v3HighAfter != v3HighBefore,
            "weights should be updated after rebalance"
        );

        assertEq(v2After + v3LowAfter + v3HighAfter, 10000);
        assertGt(v2After, 0, "v2 weight should be > 0");
        assertGt(v3LowAfter, 0, "v3Low weight should be > 0");
        assertGt(v3HighAfter, 0, "v3High weight should be > 0");
    }

    // 测试价格不变时再平衡前后总资产守恒（无无常损失）
    function test_Rebalance_FundsConserved_NoPriceChange() public {
        _deposit(alice, 20 ether, 40_000e6);
        uint256 assetBefore = vault.totalAssets();

        vault.rebalance();

        uint256 assetAfter = vault.totalAssets();
        assertApproxEqAbs(assetBefore, assetAfter, 0.01e6);
    }

    // 测试再平衡后lastRebalanceTimestamp被设置为当前区块时间
    function test_Rebalance_UpdatesLastRebalanceTimestamp() public {
        _deposit(alice, 20 ether, 40_000e6);
        assertEq(vault.lastRebalanceTimestamp(), 0);

        uint256 tsBefore = block.timestamp;
        vault.rebalance();

        assertEq(vault.lastRebalanceTimestamp(), tsBefore);
    }

    // 测试普通冷却期：首次再平衡后500秒内再次调用revert CooldownActive
    function test_Revert_Rebalance_Cooldown_Normal() public {
        _deposit(alice, 20 ether, 40_000e6);
        vault.rebalance();

        skip(500);
        vm.expectRevert(AdaptiveLPVault.CooldownActive.selector);
        vault.rebalance();
    }

    // 测试普通冷却期过后（601秒）可以正常再次再平衡
    function test_Rebalance_Cooldown_PassesAfter600s() public {
        _deposit(alice, 20 ether, 40_000e6);
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 1);

        skip(601);
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 2);
    }

    // 测试紧急冷却期：价格大幅波动后700秒内再次再平衡仍revert（紧急冷却更长）
    function test_Revert_Rebalance_EmergencyCooldown() public {
        _deposit(alice, 20 ether, 40_000e6);
        vault.rebalance();

        _setPrice(5000);

        skip(700);
        vm.expectRevert(AdaptiveLPVault.CooldownActive.selector);
        vault.rebalance();
    }

    // 测试紧急冷却期过后（1801秒）可以正常再次再平衡
    function test_Rebalance_EmergencyCooldown_PassesAfter1800s() public {
        _deposit(alice, 20 ether, 40_000e6);
        vault.rebalance();

        _setPrice(5000);
        skip(1801);
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 2);
    }

    // 测试冷却期内再平衡被阻止，但存款功能不受影响
    function test_DepositDuringCooldown() public {
        _deposit(alice, 20 ether, 40_000e6);
        vault.rebalance();

        vm.expectRevert();
        vault.rebalance();

        uint256 supplyBefore = vault.totalSupply();
        _deposit(bob, 10 ether, 20_000e6);

        assertGt(vault.totalSupply(), supplyBefore, "deposit should work during cooldown");
    }

    // 测试低波动率下权重分配：V2=10%, V3低=30%, V3高=60%
    function test_Rebalance_LowVolatility_Allocation() public {
        _deposit(alice, 50 ether, 100_000e6);
        vault.rebalance();

        (uint256 v2, uint256 v3Low, uint256 v3High) = vault.currentWeights();
        assertEq(v2, 1000, "v2 weight should be 10%");
        assertEq(v3Low, 3000, "v3Low weight should be 30%");
        assertEq(v3High, 6000, "v3High weight should be 60%");
    }

    // 测试中波动率下权重分配：V2=25%, V3低=30%, V3高=45%
    function test_Rebalance_MediumVolatility_Allocation() public {
        _deposit(alice, 50 ether, 100_000e6);
        vault.rebalance();

        _setPrice(2800);
        skip(700);
        vault.rebalance();

        (uint256 v2, uint256 v3Low, uint256 v3High) = vault.currentWeights();
        assertEq(v2, 2500, "v2 weight should be 25%");
        assertEq(v3Low, 3000, "v3Low weight should be 30%");
        assertEq(v3High, 4500, "v3High weight should be 45%");
    }

    // 测试高波动率下权重分配：V2=50%, V3低=25%, V3高=25%
    function test_Rebalance_HighVolatility_Allocation() public {
        _deposit(alice, 50 ether, 100_000e6);
        vault.rebalance();

        skip(1801);
        _setPrice(5000);
        vault.rebalance();

        (uint256 v2, uint256 v3Low, uint256 v3High) = vault.currentWeights();
        assertEq(v2, 5000, "v2 weight should be 50%");
        assertEq(v3Low, 2500, "v3Low weight should be 25%");
        assertEq(v3High, 2500, "v3High weight should be 25%");
    }

    // 测试再平衡时收取V3池手续费，cumulativeFeesUSDC增加
    function test_Rebalance_CollectsFees() public {
        _deposit(alice, 50 ether, 100_000e6);
        vault.rebalance();

        v3PoolHighFee.setMockFees(1e18);
        v3PoolLowFee.setMockFees(1e18);

        uint256 feesBefore = vault.cumulativeFeesUSDC();

        skip(700);
        vault.rebalance();

        uint256 feesAfter = vault.cumulativeFeesUSDC();
        assertGt(feesAfter, feesBefore, "cumulative fees should increase");
    }

    // 测试无手续费时总资产不变，有手续费时总资产和累计手续费均增加
    function test_Rebalance_FeesIncreaseTotalAssets() public {
        _deposit(alice, 50 ether, 100_000e6);
        vault.rebalance();

        uint256 assetsBeforeNoFees = vault.totalAssets();
        uint256 feesBeforeNoFees = vault.cumulativeFeesUSDC();
        skip(700);
        vault.rebalance();
        uint256 assetsAfterNoFees = vault.totalAssets();
        uint256 feesAfterNoFees = vault.cumulativeFeesUSDC();

        assertApproxEqRel(
            assetsAfterNoFees,
            assetsBeforeNoFees,
            0.01e18,
            "without fees, total assets should not change"
        );

        assertEq(feesAfterNoFees, feesBeforeNoFees);

        v3PoolHighFee.setMockFees(5e18);
        v3PoolLowFee.setMockFees(5e18);

        uint256 assetsBeforeWithFees = vault.totalAssets();
        uint256 feesBeforeWithFees = vault.cumulativeFeesUSDC();
        skip(700);
        vault.rebalance();
        uint256 assetsAfterWithFees = vault.totalAssets();
        uint256 feesAfterWithFees = vault.cumulativeFeesUSDC();

        assertGt(assetsAfterWithFees, assetsBeforeWithFees, "with fees, total assets should increase");
        assertGt(feesAfterWithFees, feesBeforeWithFees, "with fees, cumulative fees should increase");
    }

    // 测试有激励合约且再平衡盈利时，调用者获得激励奖励
    function test_Rebalance_WithIncentives_Profitable() public {
        _deposit(alice, 50 ether, 100_000e6);
        vault.rebalance();

        v3PoolHighFee.setMockFees(10e18);
        v3PoolLowFee.setMockFees(10e18);

        skip(700);
        uint256 rewardBefore = incentives.pendingReward(address(this));
        vault.rebalance();
        uint256 rewardAfter = incentives.pendingReward(address(this));

        assertGt(rewardAfter, rewardBefore, "should earn incentive reward");
    }

    // 测试激励合约地址设为0时再平衡仍正常执行（不依赖激励）
    function test_Rebalance_WithZeroIncentives() public {
        _deposit(alice, 20 ether, 40_000e6);
        vault.setIncentives(address(0));

        vault.rebalance();
        assertEq(vault.rebalanceCount(), 1);
    }

    // 测试激励合约调用失败时再平衡不会revert（容错设计，激励失败不阻塞核心逻辑）
    function test_Rebalance_IncentivesFail_DoesNotRevert() public {
        _deposit(alice, 20 ether, 40_000e6);
        vault.rebalance();

        vm.mockCallRevert(
            address(incentives),
            abi.encodeWithSignature("onRebalanceExecuted(address,uint256,uint256)"),
            abi.encode("incentive fail")
        );

        skip(700);
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 2);
    }

    // 测试暂停状态下再平衡revert，取消暂停后恢复正常
    function test_Revert_Rebalance_WhenPaused() public {
        _deposit(alice, 10 ether, 20_000e6);
        vault.setPaused(true);
        vm.expectRevert(AdaptiveLPVault.PausedError.selector);
        vault.rebalance();

        vault.setPaused(false);
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 1);
    }
}
