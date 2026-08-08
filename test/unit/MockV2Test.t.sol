// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockWETH, MockUSDC} from "../../src/tokens/MockTokens.sol";
import {MockUniswapV2Factory, MockUniswapV2Router, MockUniswapV2Pair} from "../mocks/MockUniswapV2.sol";

/**
 * @title MockV2Test - MockUniswapV2测试
 */
contract MockV2Test is Test {
    MockWETH weth;
    MockUSDC usdc;
    MockUniswapV2Factory factory;
    MockUniswapV2Router router;
    address alice = address(0x1234);

    function setUp() public {
        weth = new MockWETH();
        usdc = new MockUSDC();
        factory = new MockUniswapV2Factory();
        router = new MockUniswapV2Router(address(factory), address(weth));

        weth.mint(alice, 100 ether);
        usdc.mint(alice, 100_000e6);

        vm.startPrank(alice);
        weth.approve(address(router), type(uint256).max);
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function test_AddLiquidity_NewPair() public {
        // 测试添加流动性时创建新池子
        vm.prank(alice);
        (uint256 amountA, uint256 amountB, uint256 liquidity) = router.addLiquidity(
            address(weth),
            address(usdc),
            10 ether,
            20000e6,
            0,
            0,
            alice,
            block.timestamp
        );

        assertGt(amountA, 0);
        assertGt(amountB, 0);
        assertGt(liquidity, 0);
        assertEq(factory.allPairsLength(), 1);
    }

    function test_AddLiquidity_ExistingPair() public {
        // 先创建池子
        vm.startPrank(alice);
        router.addLiquidity(
            address(weth),
            address(usdc),
            10 ether,
            20000e6,
            0,
            0,
            alice,
            block.timestamp
        );

        // 再添加流动性
        (uint256 amountA, uint256 amountB, uint256 liquidity) = router.addLiquidity(
            address(weth),
            address(usdc),
            5 ether,
            10000e6,
            0,
            0,
            alice,
            block.timestamp
        );
        vm.stopPrank();

        assertGt(amountA, 0);
        assertGt(amountB, 0);
        assertGt(liquidity, 0);
        assertEq(factory.allPairsLength(), 1);
    }

    function test_Revert_AddLiquidity_Slippage() public {
        // 测试滑点超限
        vm.prank(alice);
        vm.expectRevert("V2: SLIPPAGE");
        router.addLiquidity(
            address(weth),
            address(usdc),
            10 ether,
            20000e6,
            100 ether, // amountAMin太大
            0,
            alice,
            block.timestamp
        );
    }

    // function test_RemoveLiquidity() public {
    //     // 先添加流动性
    //     vm.startPrank(alice);
    //     (, , uint256 liquidity) = router.addLiquidity(
    //         address(weth),
    //         address(usdc),
    //         10 ether,
    //         20000e6,
    //         0,
    //         0,
    //         alice,
    //         block.timestamp
    //     );

    //     // 移除流动性
    //     (uint256 amountA, uint256 amountB) = router.removeLiquidity(
    //         address(weth),
    //         address(usdc),
    //         liquidity,
    //         0,
    //         0,
    //         alice,
    //         block.timestamp
    //     );
    //     vm.stopPrank();

    //     assertGt(amountA, 0);
    //     assertGt(amountB, 0);
    // }

    // function test_Revert_RemoveLiquidity_Slippage() public {
    //     // 先添加流动性
    //     vm.startPrank(alice);
    //     (, , uint256 liquidity) = router.addLiquidity(
    //         address(weth),
    //         address(usdc),
    //         10 ether,
    //         20000e6,
    //         0,
    //         0,
    //         alice,
    //         block.timestamp
    //     );

    //     // 移除流动性，滑点超限
    //     vm.expectRevert("V2: SLIPPAGE");
    //     router.removeLiquidity(
    //         address(weth),
    //         address(usdc),
    //         liquidity,
    //         100 ether, // amountAMin太大
    //         0,
    //         alice,
    //         block.timestamp
    //     );
    //     vm.stopPrank();
    // }

    // function test_SwapExactTokensForTokens() public {
    //     // 先添加流动性
    //     vm.startPrank(alice);
    //     router.addLiquidity(
    //         address(weth),
    //         address(usdc),
    //         10 ether,
    //         20000e6,
    //         0,
    //         0,
    //         alice,
    //         block.timestamp
    //     );

    //     // swap
    //     address[] memory path = new address[](2);
    //     path[0] = address(weth);
    //     path[1] = address(usdc);
    //     uint256[] memory amounts = router.swapExactTokensForTokens(
    //         1 ether,
    //         0,
    //         path,
    //         alice,
    //         block.timestamp
    //     );
    //     vm.stopPrank();

    //     assertEq(amounts.length, 2);
    //     assertGt(amounts[1], 0);
    // }

    // function test_Revert_Swap_Slippage() public {
    //     // 先添加流动性
    //     vm.startPrank(alice);
    //     router.addLiquidity(
    //         address(weth),
    //         address(usdc),
    //         10 ether,
    //         20000e6,
    //         0,
    //         0,
    //         alice,
    //         block.timestamp
    //     );

    //     // swap，滑点超限
    //     address[] memory path = new address[](2);
    //     path[0] = address(weth);
    //     path[1] = address(usdc);
    //     vm.expectRevert("V2: SLIPPAGE");
    //     router.swapExactTokensForTokens(
    //         1 ether,
    //         100000e6, // amountOutMin太大
    //         path,
    //         alice,
    //         block.timestamp
    //     );
    //     vm.stopPrank();
    // }

    function test_Quote() public view {
        // 测试quote函数
        uint256 result = router.quote(1 ether, 10 ether, 20000e6);
        assertGt(result, 0);
    }

    function test_GetAmountsOut() public view {
        // 测试getAmountsOut函数
        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(usdc);
        uint256[] memory amounts = router.getAmountsOut(1 ether, path);
        assertEq(amounts.length, 2);
        assertGt(amounts[1], 0);
    }

    function test_Pair_SetReserves() public {
        // 测试setReserves函数
        address pair = factory.createPair(address(weth), address(usdc));
        MockUniswapV2Pair pairContract = MockUniswapV2Pair(pair);
        pairContract.setReserves(100, 200);
        (uint112 r0, uint112 r1, ) = pairContract.getReserves();
        assertEq(r0, 100);
        assertEq(r1, 200);
    }

    function test_Revert_CreatePair_Exists() public {
        // 测试重复创建池子
        factory.createPair(address(weth), address(usdc));
        vm.expectRevert("V2: EXISTS");
        factory.createPair(address(weth), address(usdc));
    }
}
