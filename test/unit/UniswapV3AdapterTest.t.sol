// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.t.sol";
import {UniswapV3Adapter} from "../../src/adapters/UniswapV3Adapter.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";

contract UniswapV3AdapterTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    function _alignTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 mod = tick % spacing;
        if (mod < 0) {
            return tick - mod - spacing;
        } else {
            return tick - mod;
        }
    }

    function _getValidTicks() internal view returns (int24 lower, int24 upper) {
        (, int24 currentTick, , , , , ) = v3PoolHighFee.slot0();
        int24 aligned = _alignTick(currentTick, 60);
        lower = aligned - 600;
        upper = aligned + 600;
    }

    // 测试V3适配器在单个价格范围内添加双币流动性成功
    function test_AddLiquidity_SinglePosition() public {
        (int24 lower, int24 upper) = _getValidTicks();
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        weth.transfer(address(vault), amount0);
        usdc.transfer(address(vault), amount1);

        bytes memory data = abi.encode(lower, upper);
        vm.prank(address(vault));
        (uint256 a0, uint256 a1, ) = v3HighAdapter.addLiquidity(amount0, amount1, 0, 0, data);

        assertGt(a0, 0);
        assertGt(a1, 0);
        assertGt(v3HighAdapter.getLpBalance(), 0);
    }

    // 测试V3 positionId由lower和upper tick的keccak256哈希生成
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

    // 测试在两个不同价格范围分别添加流动性，activePositions返回2个
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
        (uint256 a0A, uint256 a1A, ) = v3HighAdapter.addLiquidity(2 ether, 4000e6, 0, 0, abi.encode(tick1L, tick1U));
        (uint256 a0B, uint256 a1B, ) = v3HighAdapter.addLiquidity(2 ether, 4000e6, 0, 0, abi.encode(tick2L, tick2U));
        vm.stopPrank();

        bytes32[] memory positions = v3HighAdapter.getActivePositions();
        assertGt(a0A + a1A, 0, "position1 should have some liquidity");
        assertGt(a0B + a1B, 0, "position2 should have some liquidity");
        assertGt(v3HighAdapter.getLpBalance(), 0);
        assertEq(positions.length, 2);
    }

    // 测试同一价格范围多次添加流动性会累积，activePositions仍为1个
    function test_AddLiquidity_SameRangeAccumulates() public {
        (int24 lower, int24 upper) = _getValidTicks();

        weth.transfer(address(vault), 10 ether);
        usdc.transfer(address(vault), 20_000e6);

        bytes memory data = abi.encode(lower, upper);
        vm.startPrank(address(vault));
        (uint256 a0A, uint256 a1A, ) = v3HighAdapter.addLiquidity(2 ether, 4000e6, 0, 0, data);
        uint256 lpAfterFirst = v3HighAdapter.getLpBalance();
        (uint256 a0B, uint256 a1B, ) = v3HighAdapter.addLiquidity(2 ether, 4000e6, 0, 0, data);
        uint256 lpAfterSecond = v3HighAdapter.getLpBalance();
        vm.stopPrank();

        assertEq(a0A, a0B);
        assertEq(a1A, a1B);
        assertGt(lpAfterSecond, lpAfterFirst);
        bytes32[] memory positions = v3HighAdapter.getActivePositions();
        assertEq(positions.length, 1, "should still be 1 position");
    }

    // 测试lower tick大于upper tick时revert（无效价格范围）
    function test_Revert_AddLiquidity_InvalidTicks() public {
        (int24 lower, int24 upper) = _getValidTicks();
        weth.transfer(address(vault), 1 ether);
        usdc.transfer(address(vault), 2000e6);

        bytes memory data = abi.encode(upper, lower);
        vm.prank(address(vault));
        vm.expectRevert();
        v3HighAdapter.addLiquidity(1 ether, 2000e6, 0, 0, data);
    }

    // 测试tick未对齐到tickSpacing时revert
    function test_Revert_AddLiquidity_UnalignedTicks() public {
        (, int24 currentTick, , , , , ) = v3PoolHighFee.slot0();
        int24 lower = currentTick - 599;
        int24 upper = currentTick + 601;

        weth.transfer(address(vault), 1 ether);
        usdc.transfer(address(vault), 2000e6);

        bytes memory data = abi.encode(lower, upper);
        vm.prank(address(vault));
        vm.expectRevert();
        v3HighAdapter.addLiquidity(1 ether, 2000e6, 0, 0, data);
    }

    // 测试非金库地址调用addLiquidity时revert
    function test_Revert_AddLiquidity_NotVault() public {
        (int24 lower, int24 upper) = _getValidTicks();
        bytes memory data = abi.encode(lower, upper);
        vm.prank(alice);
        vm.expectRevert();
        v3HighAdapter.addLiquidity(1 ether, 2000e6, 0, 0, data);
    }

    // 测试部分撤出V3流动性：撤出一半liquidity后收到对应代币
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
        assertEq(weth.balanceOf(address(vault)), vaultWethBefore + a0);
        assertEq(usdc.balanceOf(address(vault)), vaultUsdcBefore + a1);
    }

    // 测试全部撤出V3流动性后position被停用，activePositions为空
    function test_RemoveLiquidity_All_DeactivatesPosition() public {
        (int24 lower, int24 upper) = _getValidTicks();
        bytes32 id = keccak256(abi.encodePacked(lower, upper));

        weth.transfer(address(vault), 10 ether);
        usdc.transfer(address(vault), 20_000e6);

        bytes memory data = abi.encode(lower, upper);
        vm.prank(address(vault));
        v3HighAdapter.addLiquidity(5 ether, 10_000e6, 0, 0, data);

        uint256 lpBefore = v3HighAdapter.getLpBalance();

        bytes32[] memory positionsBefore = v3HighAdapter.getActivePositions();
        assertEq(positionsBefore.length, 1, "position should be deactivated");

        vm.prank(address(vault));
        v3HighAdapter.removeLiquidity(id, uint128(lpBefore), 0, 0);

        assertEq(v3HighAdapter.getLpBalance(), 0);
        bytes32[] memory positions = v3HighAdapter.getActivePositions();
        assertEq(positions.length, 0, "position should be deactivated");
    }

    // 测试collectFees收取V3池累积的手续费并转入金库
    function test_CollectFees_TransfersToVault() public {
        (int24 lower, int24 upper) = _getValidTicks();
        bytes32 id = keccak256(abi.encodePacked(lower, upper));

        weth.transfer(address(vault), 10 ether);
        usdc.transfer(address(vault), 20_000e6);

        bytes memory data = abi.encode(lower, upper);
        vm.prank(address(vault));
        v3HighAdapter.addLiquidity(5 ether, 10_000e6, 0, 0, data);

        v3PoolHighFee.setMockFees(1e18);

        uint256 vaultWethBefore = weth.balanceOf(address(vault));
        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));

        vm.prank(address(vault));
        (uint256 f0, uint256 f1) = v3HighAdapter.collectFees(id);

        assertGt(f0 + f1, 0, "should collect some fees");

        bool wethIncreased = weth.balanceOf(address(vault)) > vaultWethBefore;
        bool usdcIncreased = usdc.balanceOf(address(vault)) > vaultUsdcBefore;
        assertTrue(wethIncreased || usdcIncreased, "vault should receive fees");
    }

    // 测试getTotalAssets返回所有position的资产之和
    function test_GetTotalAssets_SumOfPositions() public {
        (, int24 currentTick, , , , , ) = v3PoolHighFee.slot0();
        int24 aligned = _alignTick(currentTick, 60);
        int24 t1L = aligned - 1200;
        int24 t1U = aligned - 600;
        int24 t2L = aligned + 600;
        int24 t2U = aligned + 1200;

        bytes32 id1 = keccak256(abi.encodePacked(t1L, t1U));
        bytes32 id2 = keccak256(abi.encodePacked(t2L, t2U));

        weth.transfer(address(vault), 10 ether);
        usdc.transfer(address(vault), 20_000e6);

        vm.startPrank(address(vault));
        v3HighAdapter.addLiquidity(2 ether, 4000e6, 0, 0, abi.encode(t1L, t1U));
        v3HighAdapter.addLiquidity(2 ether, 4000e6, 0, 0, abi.encode(t2L, t2U));
        vm.stopPrank();

        ILPAdapter.AdapterAssets memory pos1 = v3HighAdapter.getPositionAssets(id1);
        ILPAdapter.AdapterAssets memory pos2 = v3HighAdapter.getPositionAssets(id2);

        ILPAdapter.AdapterAssets memory total = v3HighAdapter.getTotalAssets();

        assertGt(pos1.amount0 + pos1.amount1, 0, "position1 should have assets");
        assertGt(pos2.amount0 + pos2.amount1, 0, "position2 should have assets");

        uint256 expectedAmount0 = pos1.amount0 + pos2.amount0;
        assertApproxEqRel(total.amount0, expectedAmount0, 0.01e18, "total amount0 should equal sum of positions");

        uint256 expectedAmount1 = pos1.amount1 + pos2.amount1;
        assertApproxEqRel(total.amount1, expectedAmount1, 0.01e18, "total amount1 should equal sum of positions");
    }

    // 测试getPositionInfo返回正确的tick范围、liquidity和active状态
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

    // 测试getActivePositions只返回active状态的position，全部撤出后为空
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

    // 测试withdrawAll撤出所有position的全部流动性，所有position停用
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

        bytes32 id1 = keccak256(abi.encodePacked(t1L, t1U));
        bytes32 id2 = keccak256(abi.encodePacked(t2L, t2U));

        ILPAdapter.AdapterAssets memory pos1 = v3HighAdapter.getPositionAssets(id1);
        ILPAdapter.AdapterAssets memory pos2 = v3HighAdapter.getPositionAssets(id2);

        assertEq(pos1.amount0 + pos1.amount1, 0);
        assertEq(pos2.amount0 + pos2.amount1, 0);
        assertEq(v3HighAdapter.getLpBalance(), 0);
        assertEq(v3HighAdapter.getActivePositions().length, 0);
    }

    // 测试高费率和低费率适配器返回正确的adapterType枚举值
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

    // 测试添加流动性金额过小导致liquidity为0时，仍返回有效的positionId
    function test_AddLiquidity_ZeroLiquidity() public {
        int24 tickLower = _alignTick(-100, 60);
        int24 tickUpper = _alignTick(100, 60);
        bytes memory data = abi.encode(tickLower, tickUpper);

        weth.transfer(address(vault), 1);
        usdc.transfer(address(vault), 1);

        vm.prank(address(vault));
        (uint256 amount0, uint256 amount1, bytes32 id) = v3HighAdapter.addLiquidity(1, 1, 0, 0, data);

        assertEq(amount0, 0);
        assertEq(amount1, 0);
        assertNotEq(id, bytes32(0));
    }

    // 测试无手续费累积时collectFees返回0
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

    // 测试查询不存在的position时active返回false
    function test_GetPositionInfo_NotExists() public view {
        bytes32 fakeId = keccak256("nonexistent_position_id");

        (
             ,
             ,
             ,
             ,
             ,
             ,
             ,
            bool active
        ) = v3HighAdapter.getPositionInfo(fakeId);

        assertFalse(active, "active should be false");
    }

    // 测试仅存入WETH（USDC为0）时添加流动性成功，只投入WETH
    function test_AddLiquidity_OnlyWETH() public {
        int24 tickLower = _alignTick(-100, 60);
        int24 tickUpper = _alignTick(100, 60);
        bytes memory data = abi.encode(tickLower, tickUpper);

        weth.transfer(address(vault), 1 ether);

        vm.prank(address(vault));
        (uint256 amount0, uint256 amount1, ) = v3HighAdapter.addLiquidity(1 ether, 0, 0, 0, data);

        assertGt(amount0, 0);
        assertEq(amount1, 0);
    }

    // 测试仅存入USDC（WETH为0）时添加流动性成功，只投入USDC
    function test_AddLiquidity_OnlyUSDC() public {
        (, int24 currentTick, , , , , ) = v3PoolHighFee.slot0();
        int24 aligned = _alignTick(currentTick, 60);
        int24 tickLower = aligned - 1200;
        int24 tickUpper = aligned - 600;

        bytes memory data = abi.encode(tickLower, tickUpper);

        usdc.transfer(address(vault), 2000e6);

        vm.prank(address(vault));
        (uint256 amount0, uint256 amount1, ) = v3HighAdapter.addLiquidity(0, 2000e6, 0, 0, data);

        assertEq(amount0, 0);
        assertGt(amount1, 0);
    }

    // 测试添加流动性时minAmount设置过高导致滑点超限revert
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

    // 测试撤出不存在的position时revert
    function test_Revert_RemoveLiquidity_NotFound() public {
        bytes32 fakeId = keccak256("fake");
        vm.prank(address(vault));
        vm.expectRevert(bytes("V3Adapter: position not found"));
        v3HighAdapter.removeLiquidity(fakeId, 100, 0, 0);
    }

    // 测试撤出超过position持有liquidity时revert
    function test_Revert_RemoveLiquidity_InvalidLiquidity() public {
        int24 tickLower = _alignTick(-100, 60);
        int24 tickUpper = _alignTick(100, 60);
        bytes memory data = abi.encode(tickLower, tickUpper);

        weth.transfer(address(vault), 10 ether);
        usdc.transfer(address(vault), 20000e6);

        vm.prank(address(vault));
        (, , bytes32 id) = v3HighAdapter.addLiquidity(10 ether, 20000e6, 0, 0, data);

        vm.prank(address(vault));
        vm.expectRevert(bytes("V3Adapter: invalid liquidity"));
        v3HighAdapter.removeLiquidity(id, 999999e18, 0, 0);
    }

    // 测试撤出流动性时minAmount设置过高导致滑点超限revert
    function test_Revert_RemoveLiquidity_Slippage() public {
        int24 tickLower = _alignTick(-100, 60);
        int24 tickUpper = _alignTick(100, 60);
        bytes memory data = abi.encode(tickLower, tickUpper);
        weth.transfer(address(vault), 10 ether);
        usdc.transfer(address(vault), 20000e6);
        vm.prank(address(vault));
        (, , bytes32 id) = v3HighAdapter.addLiquidity(10 ether, 20000e6, 0, 0, data);

        (, , uint128 liquidity,,,,,) = v3HighAdapter.getPositionInfo(id);

        vm.prank(address(vault));
        vm.expectRevert(bytes("V3Adapter: slippage"));
        v3HighAdapter.removeLiquidity(id, liquidity, 999999e18, 999999e6);
    }

    // 测试对不存在的position收取手续费时revert
    function test_Revert_CollectFees_NotFound() public {
        bytes32 fakeId = keccak256("fake");

        vm.prank(address(vault));
        vm.expectRevert(bytes("V3Adapter: position not found"));
        v3HighAdapter.collectFees(fakeId);
    }
}
