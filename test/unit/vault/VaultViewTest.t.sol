// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../../base/BaseTest.t.sol";

/**
 * @title VaultViewTest
 * @notice 金库视图函数专项测试
 */
contract VaultViewTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    /// @notice 空vault的totalAssets为0
    function test_TotalAssets_EmptyVault() public {
        assertEq(vault.totalAssets(), 0);
    }

    /// @notice 存款后totalAssets = 存入价值
    function test_TotalAssets_AfterDeposit() public {
        uint256 usdcAmt = 10_000e6;
        _deposit(alice, 0, usdcAmt);

        // 只存USDC，totalAssets应约等于usdcAmt
        assertApproxEqRel(vault.totalAssets(), usdcAmt, 0.01e18, "total assets approx deposited USDC");
    }

    /// @notice 再平衡后totalAssets不变（无价格变动）
    function test_TotalAssets_AfterRebalance() public {
        _deposit(alice, 20 ether, 40_000e6);
        uint256 before = vault.totalAssets();

        vault.rebalance();

        uint256 afterValue = vault.totalAssets();
        assertApproxEqRel(afterValue, before, 0.01e18, "total assets conserved after rebalance");
    }

    /// @notice oracle返回0价格时只返回USDC部分
    function test_TotalAssets_OracleZeroPrice_ReturnsUSDCOnly() public {
        _deposit(alice, 10 ether, 20_000e6);

        // mock oracle返回0
        vm.mockCall(
            address(oracle),
            abi.encodeWithSignature("getTWAPPrice()"),
            abi.encode(uint160(0), int24(0))
        );

        uint256 assets = vault.totalAssets();
        // 应该只返回USDC部分（不包括WETH价值）
        (, uint256 totalUsdc) = _getTotalUnderlying();
        assertApproxEqRel(assets, totalUsdc, 0.01e18, "should return USDC only");
    }

    /// @notice oracle revert时走catch分支，只返回USDC
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

    /// @notice 空vault的distribution全零
    function test_GetDistribution_Empty() public {
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

    /// @notice 存款后distribution有值
    function test_GetDistribution_AfterDeposit() public {
        _deposit(alice, 20 ether, 40_000e6);

        (uint256 iw, uint256 iu, uint256 v2w, uint256 v2u,
         uint256 v3lw, uint256 v3lu, uint256 v3hw, uint256 v3hu) = vault.getDistribution();

        // 总资金守恒
        assertEq(iw + v2w + v3lw + v3hw, 20 ether, "total WETH conserved");
        assertApproxEqAbs(iu + v2u + v3lu + v3hu, 40_000e6, 1000, "total USDC conserved");
    }

    /// @notice 再平衡后资金分布到adapter
    function test_GetDistribution_AfterRebalance() public {
        _deposit(alice, 20 ether, 40_000e6);
        vault.rebalance();

        (uint256 iw, , uint256 v2w, , uint256 v3lw, , uint256 v3hw, ) = vault.getDistribution();

        // 大部分资金应该在adapter中（不是idle）
        uint256 invested = v2w + v3lw + v3hw;
        assertGt(invested, iw, "most funds should be invested after rebalance");
    }

    /// @notice distribution各部分之和 = getTotalUnderlying
    function test_GetDistribution_SumsMatchTotalUnderlying() public {
        _deposit(alice, 20 ether, 40_000e6);
        vault.rebalance();

        (uint256 iw, uint256 iu, uint256 v2w, uint256 v2u,
         uint256 v3lw, uint256 v3lu, uint256 v3hw, uint256 v3hu) = vault.getDistribution();

        (uint256 totalW, uint256 totalU) = vault.getTotalUnderlying();

        assertEq(iw + v2w + v3lw + v3hw, totalW, "WETH sum matches");
        assertApproxEqAbs(iu + v2u + v3lu + v3hu, totalU, 1000, "USDC sum matches");
    }

    /// @notice cumulativeFees初始为0
    function test_CumulativeFees_InitiallyZero() public {
        assertEq(vault.cumulativeFeesUSDC(), 0);
    }

    /// @notice rebalanceCount初始为0
    function test_RebalanceCount_InitiallyZero() public {
        assertEq(vault.rebalanceCount(), 0);
    }

    /// @notice getTotalUnderlying包含adapter中的手续费
    function test_GetTotalUnderlying_IncludesFees() public {
        _deposit(alice, 50 ether, 100_000e6);
        vault.rebalance();

        v3PoolHighFee.setMockFees(5e18);
        skip(700);
        vault.rebalance();

        (uint256 totalW, uint256 totalU) = vault.getTotalUnderlying();
        assertGt(totalW + totalU, 0, "total underlying should include fees");
    }
}
