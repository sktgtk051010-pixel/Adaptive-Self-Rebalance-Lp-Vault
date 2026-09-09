// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../../base/BaseTest.t.sol";

contract VaultViewTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    function test_TotalAssets_EmptyVault() public view {
        assertEq(vault.totalAssets(), 0);
    }

    function test_TotalAssets_AfterDeposit() public {
        uint256 usdcAmt = 10_000e6;
        _deposit(alice, 0, usdcAmt);

        assertEq(vault.totalAssets(), usdcAmt);
    }

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

    function test_GetDistribution_AfterDeposit() public {
        _deposit(alice, 20 ether, 40_000e6);

        (uint256 iw, uint256 iu, uint256 v2w, uint256 v2u,
         uint256 v3lw, uint256 v3lu, uint256 v3hw, uint256 v3hu) = vault.getDistribution();

        assertEq(iw + v2w + v3lw + v3hw, 20 ether, "WETH sum should equal deposited");
        assertEq(iu + v2u + v3lu + v3hu, 40_000e6, "USDC sum should equal deposited");
    }

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

    function test_GetDistribution_SumsMatchTotalUnderlying() public {
        _deposit(alice, 20 ether, 40_000e6);
        vault.rebalance();

        (uint256 iw, uint256 iu, uint256 v2w, uint256 v2u,
         uint256 v3lw, uint256 v3lu, uint256 v3hw, uint256 v3hu) = vault.getDistribution();

        (uint256 totalW, uint256 totalU) = vault.getTotalUnderlying();

        assertEq(iw + v2w + v3lw + v3hw, totalW, "WETH sum matches");
        assertApproxEqAbs(iu + v2u + v3lu + v3hu, totalU, 1000, "USDC sum matches");
    }

    function test_CumulativeFees_InitiallyZero() public view {
        assertEq(vault.cumulativeFeesUSDC(), 0);
    }

    function test_RebalanceCount_InitiallyZero() public view {
        assertEq(vault.rebalanceCount(), 0);
    }
}
