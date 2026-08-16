// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";
import {TWAPOracle} from "../../src/oracles/TWAPOracle.sol";

/**
 * @title TWAPOracleTest
 * @notice TWAP预言机专项测试
 */
contract TWAPOracleTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    /// @notice getTWAPPrice返回非零价格
    function test_GetTWAPPrice_ReturnsValidPrice() public view {
        (uint160 sqrtPriceX96, int24 tick) = oracle.getTWAPPrice();
        assertGt(uint256(sqrtPriceX96), 0, "sqrtPrice should be > 0");
        assertLt(tick, 0, "tick should be negative (USDC/WETH)");
    }

    /// @notice TWAP价格与当前价格近似（无价格变动时）
    function test_GetTWAPPrice_MatchesApproxSpot() public view {
        (uint160 twapPrice, ) = oracle.getTWAPPrice();
        (uint160 spotPrice, ) = oracle.getCurrentPrice();
        assertApproxEqRel(uint256(twapPrice), uint256(spotPrice), 0.01e18, "TWAP approx spot");
    }

    /// @notice getCurrentPrice直接读slot0
    function test_GetCurrentPrice_ReturnsSpot() public view {
        (uint160 sqrtPriceX96, int24 tick) = oracle.getCurrentPrice();
        assertGt(uint256(sqrtPriceX96), 0);
        assertNotEq(int256(tick), 0);
    }

    /// @notice WETH→USDC换算
    function test_Quote_WETHToUSDC() public view {
        uint256 wethAmount = 1 ether;
        uint256 usdcOut = oracle.quote(wethAmount, true);
        // 价格约2000 USDC/ETH，1 WETH ≈ 2000e6 USDC
        assertApproxEqRel(usdcOut, 2000e6, 0.05e18, "1 WETH approx 2000 USDC");
    }

    /// @notice USDC→WETH换算
    function test_Quote_USDCToWETH() public view {
        uint256 usdcAmount = 2000e6;
        uint256 wethOut = oracle.quote(usdcAmount, false);
        assertApproxEqRel(wethOut, 1 ether, 0.05e18, "2000 USDC approx 1 WETH");
    }

    /// @notice WETH→USDC→WETH近似守恒
    function test_Quote_RoundTrip() public view {
        uint256 wethAmount = 10 ether;
        uint256 usdcOut = oracle.quote(wethAmount, true);
        uint256 wethBack = oracle.quote(usdcOut, false);
        assertApproxEqRel(wethBack, wethAmount, 0.01e18, "round trip should conserve");
    }

    /// @notice 设置合理TWAP窗口
    function test_SetTWAPWindow_Valid() public {
        oracle.setTWAPWindow(600);
        assertEq(oracle.twapWindow(), 600);
    }

    /// @notice 窗口过小revert
    function test_Revert_SetTWAPWindow_TooSmall() public {
        vm.expectRevert(bytes("TWAPOracle: invalid window"));
        oracle.setTWAPWindow(100); // < 300
    }

    /// @notice 窗口过大revert
    function test_Revert_SetTWAPWindow_TooLarge() public {
        vm.expectRevert(bytes("TWAPOracle: invalid window"));
        oracle.setTWAPWindow(100000); // > 86400
    }

    /// @notice 非治理/owner设置窗口revert
    function test_Revert_SetTWAPWindow_NotGovernance() public {
        vm.startPrank(alice);
        vm.expectRevert(bytes("TWAPOracle: not authorized"));
        oracle.setTWAPWindow(600);
        vm.stopPrank();
    }

    /// @notice 构造函数零地址revert
    function test_Revert_Constructor_ZeroPool() public {
        vm.expectRevert(bytes("TWAPOracle: zero pool"));
        new TWAPOracle(address(0), address(weth), address(usdc), address(governance));
    }

    /// @notice 构造函数token不匹配revert
    function test_Revert_Constructor_TokenMismatch() public {
        // 用一个不相关的地址作为pool
        vm.expectRevert();
        new TWAPOracle(address(weth), address(weth), address(usdc), address(governance));
    }

    /// @notice setGovernance更新地址
    function test_SetGovernance_Valid() public {
        address newGov = makeAddr("newGov");
        oracle.setGovernance(newGov);
        assertEq(oracle.governance(), newGov);
    }

    /// @notice 非owner设置governance revert
    function test_Revert_SetGovernance_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        oracle.setGovernance(alice);
        vm.stopPrank();
    }

    /// @notice owner也可以调用setTWAPWindow（onlyGovernance允许owner）
    function test_SetTWAPWindow_ByOwner() public {
        uint32 newWindow = 600;
        oracle.setTWAPWindow(newWindow);
        assertEq(oracle.twapWindow(), newWindow);
    }

    /// @notice ensureObservationCardinality
    function test_EnsureObservationCardinality() public {
        oracle.ensureObservationCardinality(10);
        // 不会revert即可
    }

    /// @notice 大额WETH换算USDC
    function test_Quote_WETHToUSDC_LargeAmount() public view {
        uint256 wethAmount = 100 ether;
        uint256 usdcAmount = oracle.quote(wethAmount, true);
        assertGt(usdcAmount, 0);
        // 100 WETH should be ~200,000 USDC at price 2000
        assertGt(usdcAmount, 100_000e6);
    }

    /// @notice 大额USDC换算WETH
    function test_Quote_USDCToWETH_LargeAmount() public view {
        uint256 usdcAmount = 200_000e6;
        uint256 wethAmount = oracle.quote(usdcAmount, false);
        assertGt(wethAmount, 0);
        // 200,000 USDC should be ~100 WETH at price 2000
        assertGt(wethAmount, 50 ether);
    }

    /// @notice 小额换算
    function test_Quote_SmallAmount() public view {
        uint256 wethAmount = 1 wei;
        uint256 usdcAmount = oracle.quote(wethAmount, true);
        // 1 wei WETH should give some USDC (may be 0 due to precision)
        assertLe(usdcAmount, 1e6);
    }
}
