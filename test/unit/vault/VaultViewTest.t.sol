// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../../base/BaseTest.t.sol";

contract VaultViewTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // 测试空金库的totalAssets返回0
    function test_TotalAssets_EmptyVault() public view {
        assertEq(vault.totalAssets(), 0);
    }

    // 测试存款后totalAssets等于存入的USDC金额（单币存款）
    function test_TotalAssets_AfterDeposit() public {
        uint256 usdcAmt = 10_000e6;
        _deposit(alice, 0, usdcAmt);

        assertEq(vault.totalAssets(), usdcAmt);
    }

    // 测试预言机返回价格为0时，totalAssets只计算USDC部分（降级处理）
    function test_TotalAssets_OracleZeroPrice_ReturnsUSDCOnly() public {
        _deposit(alice, 10 ether, 20_000e6);

        vm.mockCall(
            address(oracle),
            abi.encodeWithSignature("getTWAPPrice()"),
            abi.encode(uint160(0), int24(0))
        );

        uint256 assets = vault.totalAssets();
        (, uint256 totalUsdc) = _getTotalUnderlying();
        assertApproxEqRel(assets, totalUsdc, 0.01e18, "should return USDC only");
    }

    // 测试预言机调用失败时，totalAssets只计算USDC部分（容错降级）
    function test_TotalAssets_OracleFail_ReturnsUSDCOnly() public {
        _deposit(alice, 10 ether, 20_000e6);

        vm.mockCallRevert(
            address(oracle),
            abi.encodeWithSignature("getTWAPPrice()"),
            abi.encode("oracle down")
        );

        uint256 assets = vault.totalAssets();
        (, uint256 totalUsdc) = _getTotalUnderlying();
        assertApproxEqRel(assets, totalUsdc, 0.01e18, "should return USDC only on oracle fail");
    }

    // 测试空金库的getDistribution所有字段均为0
    function test_GetDistribution_Empty() public view {
        (uint256 iw, uint256 iu, uint256 v2w, uint256 v2u,
         uint256 v3lw, uint256 v3lu, uint256 v3hw, uint256 v3hu) = vault.getDistribution();
        assertEq(iw, 0);
        assertEq(iu, 0);
        assertEq(v2w, 0);
        assertEq(v2u, 0);
        assertEq(v3lw, 0);
        assertEq(v3lu, 0);
        assertEq(v3hw, 0);
        assertEq(v3hu, 0);
    }

    // 测试存款后getDistribution的WETH和USDC各部分之和等于存入总量
    function test_GetDistribution_AfterDeposit() public {
        _deposit(alice, 20 ether, 40_000e6);

        (uint256 iw, uint256 iu, uint256 v2w, uint256 v2u,
         uint256 v3lw, uint256 v3lu, uint256 v3hw, uint256 v3hu) = vault.getDistribution();

        assertEq(iw + v2w + v3lw + v3hw, 20 ether, "WETH sum should equal deposited");
        assertEq(iu + v2u + v3lu + v3hu, 40_000e6, "USDC sum should equal deposited");
    }

    // 测试再平衡后getDistribution显示大部分资金已投入适配器（投资比例上升）
    function test_GetDistribution_AfterRebalance() public {
        _deposit(alice, 20 ether, 40_000e6);
        vault.rebalance();

        (uint256 iw, uint256 iu, uint256 v2w, uint256 v2u,
         uint256 v3lw, uint256 v3lu, uint256 v3hw, uint256 v3hu) = vault.getDistribution();

        uint256 investedw = v2w + v3lw + v3hw;
        uint256 investedu = v2u + v3lu + v3hu;
        assertGt(investedw, iw);
        assertGt(investedu, iu);
    }

    // 测试getDistribution各部分之和与getTotalUnderlying返回的总量一致
    function test_GetDistribution_SumsMatchTotalUnderlying() public {
        _deposit(alice, 20 ether, 40_000e6);
        vault.rebalance();

        (uint256 iw, uint256 iu, uint256 v2w, uint256 v2u,
         uint256 v3lw, uint256 v3lu, uint256 v3hw, uint256 v3hu) = vault.getDistribution();

        (uint256 totalW, uint256 totalU) = vault.getTotalUnderlying();

        assertEq(iw + v2w + v3lw + v3hw, totalW, "WETH sum matches");
        assertApproxEqAbs(iu + v2u + v3lu + v3hu, totalU, 1000, "USDC sum matches");
    }

    // 测试初始状态cumulativeFeesUSDC为0
    function test_CumulativeFees_InitiallyZero() public view {
        assertEq(vault.cumulativeFeesUSDC(), 0);
    }

    // 测试初始状态rebalanceCount为0
    function test_RebalanceCount_InitiallyZero() public view {
        assertEq(vault.rebalanceCount(), 0);
    }
}
