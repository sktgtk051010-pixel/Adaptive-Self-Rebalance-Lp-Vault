// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";
import {TWAPOracle} from "../../src/oracles/TWAPOracle.sol";

contract TWAPOracleTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    function test_GetTWAPPrice_ReturnsValidPrice() public view {
        (uint160 sqrtPriceX96, int24 tick) = oracle.getTWAPPrice();
        assertGt(uint256(sqrtPriceX96), 0, "sqrtPrice should be > 0");
        assertLt(tick, 0, "tick should be negative (USDC/WETH)");
    }

    function test_GetTWAPPrice_MatchesApproxSpot() public view {
        (uint160 twapPrice, ) = oracle.getTWAPPrice();
        (uint160 spotPrice, ) = oracle.getCurrentPrice();
        assertApproxEqRel(uint256(twapPrice), uint256(spotPrice), 0.01e18, "TWAP approx spot");
    }

    function test_GetCurrentPrice_ReturnsSpot() public view {
        (uint160 sqrtPriceX96, int24 tick) = oracle.getCurrentPrice();
        assertGt(uint256(sqrtPriceX96), 0);
        assertLt(int256(tick), 0);
    }

    function test_Quote_WETHToUSDC() public view {
        uint256 wethAmount = 1 ether;
        uint256 usdcOut = oracle.quote(wethAmount, true);
        assertApproxEqRel(usdcOut, 2000e6, 0.01e18, "1 WETH approx 2000 USDC");
    }

    function test_Quote_USDCToWETH() public view {
        uint256 usdcAmount = 2000e6;
        uint256 wethOut = oracle.quote(usdcAmount, false);
        assertApproxEqRel(wethOut, 1 ether, 0.01e18, "2000 USDC approx 1 WETH");
    }

    function test_Quote_RoundTrip() public view {
        uint256 wethAmount = 10 ether;
        uint256 usdcOut = oracle.quote(wethAmount, true);
        uint256 wethBack = oracle.quote(usdcOut, false);
        assertApproxEqRel(wethBack, wethAmount, 0.01e18, "round trip should conserve");
    }

    function test_SetTWAPWindow_Valid() public {
        oracle.setTWAPWindow(600);
        assertEq(oracle.twapWindow(), 600);
    }

    function test_Revert_SetTWAPWindow_TooSmall() public {
        vm.expectRevert(bytes("TWAPOracle: invalid window"));
        oracle.setTWAPWindow(100);
    }

    function test_Revert_SetTWAPWindow_TooLarge() public {
        vm.expectRevert(bytes("TWAPOracle: invalid window"));
        oracle.setTWAPWindow(100000);
    }

    function test_Revert_SetTWAPWindow_NotGovernance() public {
        vm.prank(alice);
        vm.expectRevert(bytes("TWAPOracle: not authorized"));
        oracle.setTWAPWindow(600);
    }

    function test_Revert_Constructor_ZeroPool() public {
        vm.expectRevert(bytes("TWAPOracle: zero pool"));
        new TWAPOracle(address(0), address(weth), address(usdc), address(governance));
    }

    function test_Revert_Constructor_TokenMismatch() public {
        vm.expectRevert();
        new TWAPOracle(address(weth), address(weth), address(usdc), address(governance));
    }

    function test_SetGovernance_Valid() public {
        address newGov = makeAddr("newGov");
        oracle.setGovernance(newGov);
        assertEq(oracle.governance(), newGov);
    }

    function test_Revert_SetGovernance_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        oracle.setGovernance(alice);
    }

    function test_SetTWAPWindow_ByOwner() public {
        uint32 newWindow = 600;
        oracle.setTWAPWindow(newWindow);
        assertEq(oracle.twapWindow(), newWindow);
    }

    function test_EnsureObservationCardinality() public {
        (, , , , uint16 cardinalityBefore, , ) = v3PoolHighFee.slot0();

        oracle.ensureObservationCardinality(10);

        (, , , , uint16 cardinalityAfter, , ) = v3PoolHighFee.slot0();
        assertEq(cardinalityAfter, 10);
        assertGt(cardinalityAfter, cardinalityBefore);
    }

    function test_Quote_SmallAmount() public view {
        uint256 wethAmount = 1 wei;
        uint256 usdcAmount = oracle.quote(wethAmount, true);

        assertEq(usdcAmount, 0);
    }
}
