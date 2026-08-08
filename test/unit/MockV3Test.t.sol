// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockWETH, MockUSDC} from "../../src/tokens/MockTokens.sol";
import {MockUniswapV3Factory, MockUniswapV3Pool} from "../mocks/MockUniswapV3.sol";

/**
 * @title MockV3Test - MockUniswapV3测试
 */
contract MockV3Test is Test {
    MockWETH weth;
    MockUSDC usdc;
    MockUniswapV3Factory factory;
    MockUniswapV3Pool pool;
    address alice = address(0x1234);

    function setUp() public {
        weth = new MockWETH();
        usdc = new MockUSDC();
        factory = new MockUniswapV3Factory();
        pool = MockUniswapV3Pool(factory.createPool(address(weth), address(usdc), 500));

        weth.mint(alice, 100 ether);
        usdc.mint(alice, 100_000e6);
    }

    function test_CreatePool() public {
        // 测试创建池子
        address poolAddr = factory.createPool(address(weth), address(usdc), 3000);
        assertNotEq(poolAddr, address(0));
        assertEq(factory.getPool(address(weth), address(usdc), 3000), poolAddr);
    }

    // function test_Revert_CreatePool_Exists() public {
    //     // 测试重复创建池子
    //     factory.createPool(address(weth), address(usdc), 500);
    //     vm.expectRevert("V3: POOL EXISTS");
    //     factory.createPool(address(weth), address(usdc), 500);
    // }

    // function test_FeeAmountTickSpacing() public view {
    //     // 测试feeAmountTickSpacing
    //     assertEq(factory.feeAmountTickSpacing(500), 10);
    //     assertEq(factory.feeAmountTickSpacing(3000), 60);
    // }

    // function test_SetPrice() public {
    //     // 测试设置价格
    //     pool.setPrice(2000);
    //     (, int24 tick, , , , , ) = pool.slot0();
    //     assertGt(tick, 0);
    // }

    // function test_Mint() public {
    //     // 测试mint流动性
    //     pool.setPrice(2000);
    //     weth.mint(address(pool), 10 ether);
    //     usdc.mint(address(pool), 20000e6);

    //     int24 tickLower = -100;
    //     int24 tickUpper = 100;
    //     (uint256 amount0, uint256 amount1) = pool.mint(address(this), tickLower, tickUpper, 1000, "");
    //     assertGt(amount0, 0);
    //     assertGt(amount1, 0);
    // }

    // function test_Burn() public {
    //     // 测试burn流动性
    //     pool.setPrice(2000);
    //     weth.mint(address(pool), 10 ether);
    //     usdc.mint(address(pool), 20000e6);

    //     int24 tickLower = -100;
    //     int24 tickUpper = 100;
    //     pool.mint(address(this), tickLower, tickUpper, 1000, "");

    //     (uint256 amount0, uint256 amount1) = pool.burn(tickLower, tickUpper, 1000);
    //     assertGt(amount0, 0);
    //     assertGt(amount1, 0);
    // }

    // function test_Collect() public {
    //     // 测试collect手续费
    //     pool.setPrice(2000);
    //     weth.mint(address(pool), 10 ether);
    //     usdc.mint(address(pool), 20000e6);

    //     int24 tickLower = -100;
    //     int24 tickUpper = 100;
    //     pool.mint(address(this), tickLower, tickUpper, 1000, "");

    //     // 模拟一些手续费
    //     pool.setMockFees(1e6);

    //     (uint256 amount0, uint256 amount1) = pool.collect(alice, tickLower, tickUpper, type(uint128).max, type(uint128).max);
    //     // 可能有手续费，也可能没有
    // }

    function test_Observe() public view {
        // 测试observe函数
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 0;
        secondsAgos[1] = 100;

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) = pool.observe(secondsAgos);
        assertEq(tickCumulatives.length, 2);
        assertEq(secondsPerLiquidityCumulativeX128s.length, 2);
    }

    function test_Positions() public view {
        // 测试positions函数
        bytes32 key = keccak256(abi.encodePacked(address(this), int24(-100), int24(100)));
        (uint128 liquidity, , , , , , ) = pool.positions(key);
        assertEq(liquidity, 0);
    }

    function test_Token0Token1() public view {
        // 测试token0和token1
        assertEq(pool.token0(), address(weth));
        assertEq(pool.token1(), address(usdc));
    }

    function test_Fee() public view {
        // 测试fee
        assertEq(pool.fee(), 500);
    }

    function test_TickSpacing() public view {
        // 测试tickSpacing
        assertEq(pool.tickSpacing(), 10);
    }
}
