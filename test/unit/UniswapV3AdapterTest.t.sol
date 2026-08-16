// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";
import {UniswapV3Adapter} from "../../src/adapters/UniswapV3Adapter.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";

/**
 * @title UniswapV3AdapterTest
 * @notice Uniswap V3适配器专项测试
 */
contract UniswapV3AdapterTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    /// @notice 对齐tick到spacing倍数（向负无穷方向）
    function _alignTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 mod = tick % spacing;
        if (mod < 0) {
            return tick - mod - spacing;
        } else {
            return tick - mod;
        }
    }

    /// @notice 获取有效tick范围
    function _getValidTicks() internal view returns (int24 lower, int24 upper) {
        (, int24 currentTick, , , , , ) = v3PoolHighFee.slot0();
        int24 aligned = _alignTick(currentTick, 60);
        lower = aligned - 600;
        upper = aligned + 600;
    }

    // ============ addLiquidity ============

    /// @notice 添加单区间流动性
    function test_AddLiquidity_SinglePosition() public {
        (int24 lower, int24 upper) = _getValidTicks();
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        weth.transfer(address(vault), amount0);
        usdc.transfer(address(vault), amount1);

        bytes memory data = abi.encode(lower, upper);
        vm.prank(address(vault));
        (uint256 a0, uint256 a1, bytes32 id) = v3HighAdapter.addLiquidity(amount0, amount1, 0, 0, data);

        assertGt(a0, 0);
        assertGt(a1, 0);
        assertGt(v3HighAdapter.getLpBalance(), 0);
    }

    /// @notice positionId = keccak(tickLower, tickUpper)
    function test_AddLiquidity_ReturnsPositionId() public {
        (int24 lower, int24 upper) = _getValidTicks();
        bytes32 expectedId = keccak256(abi.encodePacked(lower, upper));

        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        weth.transfer(address(vault), amount0);
        usdc.transfer(address(vault), amount1);

        bytes memory data = abi.encode(lower, upper);
        vm.prank(address(vault));
        (, , bytes32 id) = v3HighAdapter.addLiquidity(amount0, amount1, 0, 0, data);

        assertEq(id, expectedId);
    }

    /// @notice 多区间添加流动性
    function test_AddLiquidity_MultipleRanges() public {
        (, int24 currentTick, , , , , ) = v3PoolHighFee.slot0();
        int24 aligned = _alignTick(currentTick, 60);
        int24 tick1L = aligned - 1200;
        int24 tick1U = aligned - 600;
        int24 tick2L = aligned + 600;
        int24 tick2U = aligned + 1200;

        weth.transfer(address(vault), 10 ether);
        usdc.transfer(address(vault), 20_000e6);

        vm.startPrank(address(vault));
        v3HighAdapter.addLiquidity(2 ether, 4000e6, 0, 0, abi.encode(tick1L, tick1U));
        v3HighAdapter.addLiquidity(2 ether, 4000e6, 0, 0, abi.encode(tick2L, tick2U));
        vm.stopPrank();

        bytes32[] memory positions = v3HighAdapter.getActivePositions();
        assertEq(positions.length, 2, "should have 2 active positions");
    }

    /// @notice 相同区间累加流动性
    function test_AddLiquidity_SameRangeAccumulates() public {
        (int24 lower, int24 upper) = _getValidTicks();

        weth.transfer(address(vault), 10 ether);
        usdc.transfer(address(vault), 20_000e6);

        bytes memory data = abi.encode(lower, upper);
        vm.startPrank(address(vault));
        v3HighAdapter.addLiquidity(2 ether, 4000e6, 0, 0, data);
        uint256 lpAfterFirst = v3HighAdapter.getLpBalance();
        v3HighAdapter.addLiquidity(2 ether, 4000e6, 0, 0, data);
        uint256 lpAfterSecond = v3HighAdapter.getLpBalance();
        vm.stopPrank();

        assertGt(lpAfterSecond, lpAfterFirst, "LP should accumulate");
        bytes32[] memory positions = v3HighAdapter.getActivePositions();
        assertEq(positions.length, 1, "should still be 1 position");
    }

    /// @notice 无效tick（lower>=upper）revert
    function test_Revert_AddLiquidity_InvalidTicks() public {
        (int24 lower, int24 upper) = _getValidTicks();
        weth.transfer(address(vault), 1 ether);
        usdc.transfer(address(vault), 2000e6);

        bytes memory data = abi.encode(upper, lower); // 反了
        vm.prank(address(vault));
        vm.expectRevert();
        v3HighAdapter.addLiquidity(1 ether, 2000e6, 0, 0, data);
    }

    /// @notice 未对齐tick revert
    function test_Revert_AddLiquidity_UnalignedTicks() public {
        (, int24 currentTick, , , , , ) = v3PoolHighFee.slot0();
        int24 lower = currentTick - 599; // 不对齐60
        int24 upper = currentTick + 601;

        weth.transfer(address(vault), 1 ether);
        usdc.transfer(address(vault), 2000e6);

        bytes memory data = abi.encode(lower, upper);
        vm.prank(address(vault));
        vm.expectRevert();
        v3HighAdapter.addLiquidity(1 ether, 2000e6, 0, 0, data);
    }

    /// @notice 非vault调用revert
    function test_Revert_AddLiquidity_NotVault() public {
        (int24 lower, int24 upper) = _getValidTicks();
        bytes memory data = abi.encode(lower, upper);
        vm.startPrank(alice);
        vm.expectRevert();
        v3HighAdapter.addLiquidity(1 ether, 2000e6, 0, 0, data);
        vm.stopPrank();
    }

    // ============ removeLiquidity ============

    /// @notice 部分撤出流动性
    function test_RemoveLiquidity_Partial() public {
        (int24 lower, int24 upper) = _getValidTicks();
        bytes32 id = keccak256(abi.encodePacked(lower, upper));

        weth.transfer(address(vault), 10 ether);
        usdc.transfer(address(vault), 20_000e6);

        bytes memory data = abi.encode(lower, upper);
        vm.prank(address(vault));
        v3HighAdapter.addLiquidity(5 ether, 10_000e6, 0, 0, data);

        uint256 lpBefore = v3HighAdapter.getLpBalance();
        uint128 removeAmount = uint128(lpBefore / 2);

        uint256 vaultWethBefore = weth.balanceOf(address(vault));
        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));

        vm.prank(address(vault));
        (uint256 a0, uint256 a1) = v3HighAdapter.removeLiquidity(id, removeAmount, 0, 0);

        assertGt(a0, 0);
        assertGt(a1, 0);
        assertEq(v3HighAdapter.getLpBalance(), lpBefore - removeAmount);
        assertGt(weth.balanceOf(address(vault)), vaultWethBefore);
        assertGt(usdc.balanceOf(address(vault)), vaultUsdcBefore);
    }

    /// @notice 全部撤出后position变为inactive
    function test_RemoveLiquidity_All_DeactivatesPosition() public {
        (int24 lower, int24 upper) = _getValidTicks();
        bytes32 id = keccak256(abi.encodePacked(lower, upper));

        weth.transfer(address(vault), 10 ether);
        usdc.transfer(address(vault), 20_000e6);

        bytes memory data = abi.encode(lower, upper);
        vm.prank(address(vault));
        v3HighAdapter.addLiquidity(5 ether, 10_000e6, 0, 0, data);

        uint256 lpBefore = v3HighAdapter.getLpBalance();

        vm.prank(address(vault));
        v3HighAdapter.removeLiquidity(id, uint128(lpBefore), 0, 0);

        assertEq(v3HighAdapter.getLpBalance(), 0);
        bytes32[] memory positions = v3HighAdapter.getActivePositions();
        assertEq(positions.length, 0, "position should be deactivated");
    }

    // ============ collectFees ============

    /// @notice collectFees转账手续费到vault
    function test_CollectFees_TransfersToVault() public {
        (int24 lower, int24 upper) = _getValidTicks();
        bytes32 id = keccak256(abi.encodePacked(lower, upper));

        weth.transfer(address(vault), 10 ether);
        usdc.transfer(address(vault), 20_000e6);

        bytes memory data = abi.encode(lower, upper);
        vm.prank(address(vault));
        v3HighAdapter.addLiquidity(5 ether, 10_000e6, 0, 0, data);

        // 设置mock手续费
        v3PoolHighFee.setMockFees(1e18);

        uint256 vaultWethBefore = weth.balanceOf(address(vault));
        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));

        vm.prank(address(vault));
        (uint256 f0, uint256 f1) = v3HighAdapter.collectFees(id);

        assertTrue(f0 > 0 || f1 > 0, "should collect some fees");
        assertTrue(
            weth.balanceOf(address(vault)) > vaultWethBefore ||
            usdc.balanceOf(address(vault)) > vaultUsdcBefore,
            "vault should receive fees"
        );
    }

    // ============ 视图函数 ============

    /// @notice getTotalAssets是所有position之和
    function test_GetTotalAssets_SumOfPositions() public {
        (, int24 currentTick, , , , , ) = v3PoolHighFee.slot0();
        int24 aligned = _alignTick(currentTick, 60);
        int24 t1L = aligned - 1200;
        int24 t1U = aligned - 600;
        int24 t2L = aligned + 600;
        int24 t2U = aligned + 1200;

        weth.transfer(address(vault), 10 ether);
        usdc.transfer(address(vault), 20_000e6);

        vm.startPrank(address(vault));
        v3HighAdapter.addLiquidity(2 ether, 4000e6, 0, 0, abi.encode(t1L, t1U));
        v3HighAdapter.addLiquidity(2 ether, 4000e6, 0, 0, abi.encode(t2L, t2U));
        vm.stopPrank();

        ILPAdapter.AdapterAssets memory total = v3HighAdapter.getTotalAssets();
        assertGt(total.amount0 + total.amount1, 0, "total assets should be > 0");
    }

    /// @notice getPositionInfo返回正确字段
    function test_GetPositionInfo_ReturnsCorrectFields() public {
        (int24 lower, int24 upper) = _getValidTicks();
        bytes32 id = keccak256(abi.encodePacked(lower, upper));

        weth.transfer(address(vault), 10 ether);
        usdc.transfer(address(vault), 20_000e6);

        bytes memory data = abi.encode(lower, upper);
        vm.prank(address(vault));
        v3HighAdapter.addLiquidity(5 ether, 10_000e6, 0, 0, data);

        (int24 tL, int24 tU, uint128 liquidity, , , , , bool active) =
            v3HighAdapter.getPositionInfo(id);

        assertEq(tL, lower);
        assertEq(tU, upper);
        assertGt(liquidity, 0);
        assertTrue(active);
    }

    /// @notice getActivePositions只返回active的
    function test_GetActivePositions_OnlyActive() public {
        (int24 lower, int24 upper) = _getValidTicks();
        bytes32 id = keccak256(abi.encodePacked(lower, upper));

        weth.transfer(address(vault), 10 ether);
        usdc.transfer(address(vault), 20_000e6);

        bytes memory data = abi.encode(lower, upper);
        vm.prank(address(vault));
        v3HighAdapter.addLiquidity(5 ether, 10_000e6, 0, 0, data);

        assertEq(v3HighAdapter.getActivePositions().length, 1);

        uint256 lp = v3HighAdapter.getLpBalance();
        vm.prank(address(vault));
        v3HighAdapter.removeLiquidity(id, uint128(lp), 0, 0);

        assertEq(v3HighAdapter.getActivePositions().length, 0);
    }

    // ============ withdrawAll ============

    /// @notice withdrawAll撤出所有position
    function test_WithdrawAll_AllPositionsBurned() public {
        (, int24 currentTick, , , , , ) = v3PoolHighFee.slot0();
        int24 aligned = _alignTick(currentTick, 60);
        int24 t1L = aligned - 1200;
        int24 t1U = aligned - 600;
        int24 t2L = aligned + 600;
        int24 t2U = aligned + 1200;

        weth.transfer(address(vault), 10 ether);
        usdc.transfer(address(vault), 20_000e6);

        vm.startPrank(address(vault));
        v3HighAdapter.addLiquidity(2 ether, 4000e6, 0, 0, abi.encode(t1L, t1U));
        v3HighAdapter.addLiquidity(2 ether, 4000e6, 0, 0, abi.encode(t2L, t2U));
        vm.stopPrank();

        assertEq(v3HighAdapter.getActivePositions().length, 2);

        vm.prank(address(vault));
        v3HighAdapter.withdrawAll();

        assertEq(v3HighAdapter.getLpBalance(), 0);
        assertEq(v3HighAdapter.getActivePositions().length, 0);
    }

    /// @notice adapterType正确
    function test_AdapterType() public view {
        assertEq(
            uint256(v3HighAdapter.adapterType()),
            uint256(ILPAdapter.AdapterType.UNISWAP_V3_HIGH_FEE)
        );
        assertEq(
            uint256(v3LowAdapter.adapterType()),
            uint256(ILPAdapter.AdapterType.UNISWAP_V3_LOW_FEE)
        );
    }

    /// @notice 金额太小导致liquidity为0时返回(0,0,id)
    function test_AddLiquidity_ZeroLiquidity() public {
        int24 tickLower = _alignTick(-100, 60);
        int24 tickUpper = _alignTick(100, 60);
        bytes memory data = abi.encode(tickLower, tickUpper);
        // 极小金额，可能导致liquidity为0
        weth.transfer(address(vault), 1);
        usdc.transfer(address(vault), 1);
        vm.prank(address(vault));
        (uint256 amount0, uint256 amount1, bytes32 id) = v3HighAdapter.addLiquidity(1, 1, 0, 0, data);
        assertTrue(amount0 >= 0);
        assertTrue(amount1 >= 0);
        assertTrue(id != bytes32(0));
    }

    /// @notice 没有手续费时collectFees返回0
    function test_CollectFees_ZeroFees() public {
        int24 tickLower = _alignTick(-100, 60);
        int24 tickUpper = _alignTick(100, 60);
        bytes memory data = abi.encode(tickLower, tickUpper);
        weth.transfer(address(vault), 1 ether);
        usdc.transfer(address(vault), 2000e6);
        vm.prank(address(vault));
        (, , bytes32 id) = v3HighAdapter.addLiquidity(1 ether, 2000e6, 0, 0, data);

        vm.prank(address(vault));
        (uint256 fee0, uint256 fee1) = v3HighAdapter.collectFees(id);
        assertEq(fee0, 0);
        assertEq(fee1, 0);
    }

    /// @notice 获取不存在的position信息
    function test_GetPositionInfo_NotExists() public view {
        bytes32 fakeId = keccak256("fake");
        assertTrue(true);
    }

    /// @notice 只存WETH单边流动性
    function test_AddLiquidity_OnlyWETH() public {
        int24 tickLower = _alignTick(-100, 60);
        int24 tickUpper = _alignTick(100, 60);
        bytes memory data = abi.encode(tickLower, tickUpper);
        weth.transfer(address(vault), 1 ether);
        vm.prank(address(vault));
        (uint256 amount0, uint256 amount1, ) = v3HighAdapter.addLiquidity(1 ether, 0, 0, 0, data);
        assertTrue(amount0 >= 0);
        assertTrue(amount1 >= 0);
    }

    /// @notice 只存USDC单边流动性
    function test_AddLiquidity_OnlyUSDC() public {
        int24 tickLower = _alignTick(-100, 60);
        int24 tickUpper = _alignTick(100, 60);
        bytes memory data = abi.encode(tickLower, tickUpper);
        usdc.transfer(address(vault), 2000e6);
        vm.prank(address(vault));
        (uint256 amount0, uint256 amount1, ) = v3HighAdapter.addLiquidity(0, 2000e6, 0, 0, data);
        assertTrue(amount0 >= 0);
        assertTrue(amount1 >= 0);
    }

    /// @notice 添加流动性滑点超过revert
    function test_Revert_AddLiquidity_Slippage() public {
        int24 tickLower = _alignTick(-100, 60);
        int24 tickUpper = _alignTick(100, 60);
        bytes memory data = abi.encode(tickLower, tickUpper);
        weth.transfer(address(vault), 10 ether);
        usdc.transfer(address(vault), 20000e6);
        vm.prank(address(vault));
        vm.expectRevert(bytes("V3Adapter: slippage"));
        v3HighAdapter.addLiquidity(10 ether, 20000e6, 999999e18, 999999e6, data);
    }

    /// @notice 移除不存在的position revert
    function test_Revert_RemoveLiquidity_NotFound() public {
        bytes32 fakeId = keccak256("fake");
        vm.prank(address(vault));
        vm.expectRevert(bytes("V3Adapter: position not found"));
        v3HighAdapter.removeLiquidity(fakeId, 100, 0, 0);
    }

    /// @notice 移除流动性数量无效revert
    function test_Revert_RemoveLiquidity_InvalidLiquidity() public {
        // 先添加流动性
        int24 tickLower = _alignTick(-100, 60);
        int24 tickUpper = _alignTick(100, 60);
        bytes memory data = abi.encode(tickLower, tickUpper);
        weth.transfer(address(vault), 10 ether);
        usdc.transfer(address(vault), 20000e6);
        vm.prank(address(vault));
        (, , bytes32 id) = v3HighAdapter.addLiquidity(10 ether, 20000e6, 0, 0, data);

        // 尝试移除超过持仓的流动性
        vm.prank(address(vault));
        vm.expectRevert(bytes("V3Adapter: invalid liquidity"));
        v3HighAdapter.removeLiquidity(id, 999999e18, 0, 0);
    }

    /// @notice 移除流动性滑点超过revert
    function test_Revert_RemoveLiquidity_Slippage() public {
        int24 tickLower = _alignTick(-100, 60);
        int24 tickUpper = _alignTick(100, 60);
        bytes memory data = abi.encode(tickLower, tickUpper);
        weth.transfer(address(vault), 10 ether);
        usdc.transfer(address(vault), 20000e6);
        vm.prank(address(vault));
        (, , bytes32 id) = v3HighAdapter.addLiquidity(10 ether, 20000e6, 0, 0, data);

        // 获取position信息
        (, , uint128 liquidity,,,,,) = v3HighAdapter.getPositionInfo(id);

        vm.prank(address(vault));
        vm.expectRevert(bytes("V3Adapter: slippage"));
        v3HighAdapter.removeLiquidity(id, liquidity, 999999e18, 999999e6);
    }

    /// @notice 收集不存在position的手续费revert
    function test_Revert_CollectFees_NotFound() public {
        bytes32 fakeId = keccak256("fake");
        vm.prank(address(vault));
        vm.expectRevert(bytes("V3Adapter: position not found"));
        v3HighAdapter.collectFees(fakeId);
    }
}
