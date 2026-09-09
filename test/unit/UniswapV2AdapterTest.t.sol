// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";
import {UniswapV2Adapter} from "../../src/adapters/UniswapV2Adapter.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";

contract UniswapV2AdapterTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    function test_AddLiquidity_BothTokens() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        weth.transfer(address(vault), amount0);
        usdc.transfer(address(vault), amount1);

        vm.prank(address(vault));
        (uint256 a0, uint256 a1, bytes32 id) = v2Adapter.addLiquidity(amount0, amount1, 0, 0, "");

        assertEq(a0, amount0);
        assertEq(a1, amount1);
        assertEq(id, v2Adapter.POSITION_ID());
        assertGt(v2Adapter.getLpBalance(), 0);
    }

    function test_AddLiquidity_ReturnsPositionId() public view {
        assertEq(v2Adapter.POSITION_ID(), keccak256("UniswapV2Adapter.POSITION"));
    }

    function test_AddLiquidity_DustReturned() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        weth.transfer(address(vault), amount0);
        usdc.transfer(address(vault), amount1);

        vm.prank(address(vault));
        v2Adapter.addLiquidity(amount0, amount1, 0, 0, "");

        assertEq(weth.balanceOf(address(v2Adapter)), 0);
        assertEq(usdc.balanceOf(address(v2Adapter)), 0);
    }

    function test_Revert_AddLiquidity_ZeroAmount() public {
        vm.prank(address(vault));
        vm.expectRevert(bytes("V2Adapter: zero amounts"));
        v2Adapter.addLiquidity(0, 0, 0, 0, "");
    }

    function test_Revert_AddLiquidity_NotVault() public {
        vm.prank(alice);
        vm.expectRevert(bytes("V2Adapter: not vault"));
        v2Adapter.addLiquidity(1 ether, 2000e6, 0, 0, "");
    }

    function test_RemoveLiquidity_Partial() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20_000e6;
        weth.transfer(address(vault), amount0);
        usdc.transfer(address(vault), amount1);

        vm.prank(address(vault));
        v2Adapter.addLiquidity(amount0, amount1, 0, 0, "");

        uint256 lpBalance = v2Adapter.getLpBalance();
        uint256 halfLp = lpBalance / 2;
        bytes32 id = v2Adapter.POSITION_ID();

        uint256 vaultWethBefore = weth.balanceOf(address(vault));
        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));

        vm.prank(address(vault));
        (uint256 a0, uint256 a1) = v2Adapter.removeLiquidity(id, uint128(halfLp), 0, 0);

        assertGt(a0, 0);
        assertGt(a1, 0);
        assertEq(v2Adapter.getLpBalance(), lpBalance - halfLp);
        assertGt(weth.balanceOf(address(vault)), vaultWethBefore);
        assertGt(usdc.balanceOf(address(vault)), vaultUsdcBefore);
    }

    function test_RemoveLiquidity_All() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20_000e6;
        weth.transfer(address(vault), amount0);
        usdc.transfer(address(vault), amount1);

        vm.prank(address(vault));
        v2Adapter.addLiquidity(amount0, amount1, 0, 0, "");

        uint256 lpBalance = v2Adapter.getLpBalance();
        bytes32 id = v2Adapter.POSITION_ID();

        uint256 vaultWethBefore = weth.balanceOf(address(vault));
        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));

        vm.prank(address(vault));
        (uint256 a0, uint256 a1) = v2Adapter.removeLiquidity(id, uint128(lpBalance), 0, 0);

        assertGt(a0, 0);
        assertGt(a1, 0);
        assertEq(v2Adapter.getLpBalance(), 0);
        assertEq(weth.balanceOf(address(v2Adapter)), 0);
        assertEq(usdc.balanceOf(address(v2Adapter)), 0);
        assertGt(weth.balanceOf(address(vault)), vaultWethBefore);
        assertGt(usdc.balanceOf(address(vault)), vaultUsdcBefore);
    }

    function test_Revert_RemoveLiquidity_ExceedsBalance() public {
        bytes32 id = v2Adapter.POSITION_ID();
        vm.prank(address(vault));
        vm.expectRevert(bytes("V2Adapter: insufficient LP"));
        v2Adapter.removeLiquidity(id, uint128(1000), 0, 0);
    }

    function test_CollectFees_ReturnsZero() public {
        bytes32 id = v2Adapter.POSITION_ID();
        vm.prank(address(vault));
        (uint256 f0, uint256 f1) = v2Adapter.collectFees(id);
        assertEq(f0, 0);
        assertEq(f1, 0);
    }

    function test_GetTotalAssets_MatchesReserves() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20_000e6;
        weth.transfer(address(vault), amount0);
        usdc.transfer(address(vault), amount1);

        vm.prank(address(vault));
        v2Adapter.addLiquidity(amount0, amount1, 0, 0, "");

        ILPAdapter.AdapterAssets memory assets = v2Adapter.getTotalAssets();
        assertApproxEqRel(assets.amount0, amount0, 0.01e18);
        assertApproxEqRel(assets.amount1, amount1, 0.01e18);
    }

    function test_GetActivePositions_ReturnsPositionId() public view {
        bytes32[] memory positions = v2Adapter.getActivePositions();
        assertEq(positions.length, 1);
        assertEq(positions[0], v2Adapter.POSITION_ID());
    }

    function test_WithdrawAll_RemovesAllLP() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20_000e6;
        weth.transfer(address(vault), amount0);
        usdc.transfer(address(vault), amount1);

        vm.prank(address(vault));
        v2Adapter.addLiquidity(amount0, amount1, 0, 0, "");

        uint256 vaultWethBefore = weth.balanceOf(address(vault));
        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));

        assertGt(v2Adapter.getLpBalance(), 0);

        vm.prank(address(vault));
        v2Adapter.withdrawAll();

        assertGt(weth.balanceOf(address(vault)), vaultWethBefore);
        assertGt(usdc.balanceOf(address(vault)), vaultUsdcBefore);
        assertEq(v2Adapter.getLpBalance(), 0, "all LP should be removed");
    }

    function test_AdapterType() public view {
        assertEq(uint256(v2Adapter.adapterType()), uint256(ILPAdapter.AdapterType.UNISWAP_V2));
    }

    function test_GetTotalAssets_ZeroLP() public view {
        assertEq(v2Adapter.getLpBalance(), 0);
        ILPAdapter.AdapterAssets memory assets = v2Adapter.getTotalAssets();
        assertEq(assets.amount0, 0);
        assertEq(assets.amount1, 0);
    }
}
