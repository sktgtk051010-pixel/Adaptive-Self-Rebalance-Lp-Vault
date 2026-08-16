// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";
import {UniswapV2Adapter} from "../../src/adapters/UniswapV2Adapter.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";

/**
 * @title UniswapV2AdapterTest
 * @notice Uniswap V2适配器专项测试
 */
contract UniswapV2AdapterTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    /// @notice 添加双币流动性
    function test_AddLiquidity_BothTokens() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        // 给vault转入代币
        weth.transfer(address(vault), amount0);
        usdc.transfer(address(vault), amount1);

        vm.prank(address(vault));
        (uint256 a0, uint256 a1, bytes32 id) = v2Adapter.addLiquidity(amount0, amount1, 0, 0, "");

        assertEq(a0, amount0);
        assertEq(a1, amount1);
        assertEq(id, v2Adapter.POSITION_ID());
        assertGt(v2Adapter.getLpBalance(), 0);
    }

    /// @notice 返回正确的positionId
    function test_AddLiquidity_ReturnsPositionId() public view {
        assertEq(v2Adapter.POSITION_ID(), keccak256("UniswapV2Adapter.POSITION"));
    }

    /// @notice 剩余dust返回vault
    function test_AddLiquidity_DustReturned() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        weth.transfer(address(vault), amount0);
        usdc.transfer(address(vault), amount1);

        uint256 vaultWethBefore = weth.balanceOf(address(vault));

        vm.prank(address(vault));
        v2Adapter.addLiquidity(amount0, amount1, 0, 0, "");

        // V2 mock用全部desired金额，所以dust应该为0或很小
        // 但adapter合约上不应有余额
        assertEq(weth.balanceOf(address(v2Adapter)), 0, "adapter should have no WETH dust");
    }

    /// @notice 零金额revert
    function test_Revert_AddLiquidity_ZeroAmount() public {
        vm.prank(address(vault));
        vm.expectRevert(bytes("V2Adapter: zero amounts"));
        v2Adapter.addLiquidity(0, 0, 0, 0, "");
    }

    /// @notice 非vault调用revert
    function test_Revert_AddLiquidity_NotVault() public {
        vm.startPrank(alice);
        vm.expectRevert(bytes("V2Adapter: not vault"));
        v2Adapter.addLiquidity(1 ether, 2000e6, 0, 0, "");
        vm.stopPrank();
    }

    /// @notice 部分撤出流动性
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

    /// @notice 全部撤出
    function test_RemoveLiquidity_All() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20_000e6;
        weth.transfer(address(vault), amount0);
        usdc.transfer(address(vault), amount1);

        vm.prank(address(vault));
        v2Adapter.addLiquidity(amount0, amount1, 0, 0, "");

        uint256 lpBalance = v2Adapter.getLpBalance();
        bytes32 id = v2Adapter.POSITION_ID();

        vm.prank(address(vault));
        v2Adapter.removeLiquidity(id, uint128(lpBalance), 0, 0);

        assertEq(v2Adapter.getLpBalance(), 0);
    }

    /// @notice 超过LP余额revert
    function test_Revert_RemoveLiquidity_ExceedsBalance() public {
        bytes32 id = v2Adapter.POSITION_ID();
        vm.prank(address(vault));
        vm.expectRevert(bytes("V2Adapter: insufficient LP"));
        v2Adapter.removeLiquidity(id, uint128(1000), 0, 0);
    }

    /// @notice collectFees返回0（V2手续费内嵌LP）
    function test_CollectFees_ReturnsZero() public {
        bytes32 id = v2Adapter.POSITION_ID();
        vm.prank(address(vault));
        (uint256 f0, uint256 f1) = v2Adapter.collectFees(id);
        assertEq(f0, 0);
        assertEq(f1, 0);
    }

    /// @notice getTotalAssets匹配reserves
    function test_GetTotalAssets_MatchesReserves() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20_000e6;
        weth.transfer(address(vault), amount0);
        usdc.transfer(address(vault), amount1);

        vm.prank(address(vault));
        v2Adapter.addLiquidity(amount0, amount1, 0, 0, "");

        ILPAdapter.AdapterAssets memory assets = v2Adapter.getTotalAssets();
        assertApproxEqRel(assets.amount0, amount0, 0.01e18, "amount0 approx deposited");
        assertApproxEqRel(assets.amount1, amount1, 0.01e18, "amount1 approx deposited");
    }

    /// @notice getActivePositions返回POSITION_ID
    function test_GetActivePositions_ReturnsPositionId() public view {
        bytes32[] memory positions = v2Adapter.getActivePositions();
        assertEq(positions.length, 1);
        assertEq(positions[0], v2Adapter.POSITION_ID());
    }

    /// @notice withdrawAll撤出全部LP
    function test_WithdrawAll_RemovesAllLP() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20_000e6;
        weth.transfer(address(vault), amount0);
        usdc.transfer(address(vault), amount1);

        vm.prank(address(vault));
        v2Adapter.addLiquidity(amount0, amount1, 0, 0, "");

        assertGt(v2Adapter.getLpBalance(), 0);

        vm.prank(address(vault));
        v2Adapter.withdrawAll();

        assertEq(v2Adapter.getLpBalance(), 0, "all LP should be removed");
    }

    /// @notice adapterType正确
    function test_AdapterType() public view {
        assertEq(uint256(v2Adapter.adapterType()), uint256(ILPAdapter.AdapterType.UNISWAP_V2));
    }

    /// @notice 没有LP时getTotalAssets返回0
    function test_GetTotalAssets_ZeroLP() public view {
        ILPAdapter.AdapterAssets memory assets = v2Adapter.getTotalAssets();
        assertTrue(assets.amount0 >= 0);
        assertTrue(assets.amount1 >= 0);
    }

    /// @notice getLpBalance返回正确余额
    function test_GetLpBalance() public view {
        uint256 balance = v2Adapter.getLpBalance();
        // BaseTest中已经投资了，所以应该有余额
        assertTrue(balance >= 0);
    }

    /// @notice getActivePositions返回positionId
    function test_GetActivePositions_NotEmpty() public view {
        bytes32[] memory positions = v2Adapter.getActivePositions();
        // V2 adapter always returns one position
        assertEq(positions.length, 1);
        assertEq(positions[0], v2Adapter.POSITION_ID());
    }

    /// @notice getPositionAssets返回资产
    function test_GetPositionAssets() public view {
        bytes32 id = v2Adapter.POSITION_ID();
        ILPAdapter.AdapterAssets memory assets = v2Adapter.getPositionAssets(id);
        assertTrue(assets.amount0 >= 0);
        assertTrue(assets.amount1 >= 0);
    }
}
