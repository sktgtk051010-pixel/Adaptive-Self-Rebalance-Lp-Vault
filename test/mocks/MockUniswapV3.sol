// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TickMath, LiquidityAmounts} from "../../src/libraries/UniswapMath.sol";
import {IUniswapV3Pool, IUniswapV3MintCallback} from "../../src/interfaces/IUniswapV3.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/**
 * @title MockUniswapV3Pool
 * @notice 模拟Uniswap V3 Pool，支持基本mint/burn/collect/observe
 */
contract MockUniswapV3Pool {
    using SafeERC20 for IERC20;

    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickSpacing;

    // slot0
    uint160 public sqrtPriceX96;
    int24 public tick;
    uint16 public observationIndex;
    uint16 public observationCardinality;
    uint16 public observationCardinalityNext;

    uint128 public liquidity;

    // Position
    struct PositionInfo {
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        uint256 amount0Deposited;  // 记录实际存入的token0
        uint256 amount1Deposited;  // 记录实际存入的token1
    }
    mapping(bytes32 => PositionInfo) public positions;

    // Tick info
    struct TickInfo {
        uint128 liquidityGross;
        int128 liquidityNet;
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
        int56 tickCumulativeOutside;
        uint160 secondsPerLiquidityOutsideX128;
        uint32 secondsOutside;
        bool initialized;
    }
    mapping(int24 => TickInfo) public ticks;

    // Observations for TWAP
    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        uint160 secondsPerLiquidityCumulativeX128;
        bool initialized;
    }
    Observation[] public observations;

    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

    // 模拟手续费累积
    uint256 public mockFeesPerPosition;

    constructor(
        address _token0,
        address _token1,
        uint24 _fee,
        int24 _tickSpacing
    ) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;

        // 初始化observation
        observations.push(Observation({
            blockTimestamp: uint32(block.timestamp),
            tickCumulative: 0,
            secondsPerLiquidityCumulativeX128: 0,
            initialized: true
        }));
        observationCardinality = 1;
        observationCardinalityNext = 1;

        // 默认价格: 1 ETH = 2000 USDC
        setPrice(2000); // 2000 USDC per ETH
    }

    function setPrice(uint256 priceUsdcPerEth) public {
        _updateObservation();
        bool wethIsToken0 = _isWETH(token0);
        uint256 Q96 = 2 ** 96;
        if (wethIsToken0) {
            uint256 sqrtPrice = _sqrt(priceUsdcPerEth * 1e6);
            sqrtPriceX96 = uint160((sqrtPrice * Q96) / 1e9);
        } else {
            uint256 sqrtPrice = _sqrt(priceUsdcPerEth * 1e6);
            sqrtPriceX96 = uint160((1e9 * Q96) / sqrtPrice);
        }
        tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
    }

    function _isWETH(address token) internal view returns (bool) {
        // 简单判断：WETH有18位decimals
        try ERC20(token).decimals() returns (uint8 d) {
            return d == 18;
        } catch {
            return false;
        }
    }

    function setSqrtPriceX96(uint160 _sqrtPriceX96) external {
        sqrtPriceX96 = _sqrtPriceX96;
        tick = TickMath.getTickAtSqrtRatio(_sqrtPriceX96);
        _updateObservation();
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) { z = x; x = (y / x + x) / 2; }
        } else if (y != 0) { z = 1; }
    }

    function _updateObservation() internal {
        if (observations.length > 0) {
            Observation storage last = observations[observations.length - 1];
            if (last.blockTimestamp == uint32(block.timestamp)) return;
            uint32 delta = uint32(block.timestamp) - last.blockTimestamp;
            int56 newTickCumulative = last.tickCumulative + int56(tick) * int56(uint56(delta));
            observations.push(Observation({
                blockTimestamp: uint32(block.timestamp),
                tickCumulative: newTickCumulative,
                secondsPerLiquidityCumulativeX128: 0,
                initialized: true
            }));
        } else {
            observations.push(Observation({
                blockTimestamp: uint32(block.timestamp),
                tickCumulative: 0,
                secondsPerLiquidityCumulativeX128: 0,
                initialized: true
            }));
        }
        observationIndex = uint16(observations.length - 1);
        observationCardinality = uint16(observations.length);
        observationCardinalityNext = uint16(observations.length);
    }

    function slot0() external view returns (
        uint160, int24, uint16, uint16, uint16, uint8, bool
    ) {
        return (sqrtPriceX96, tick, observationIndex, observationCardinality,
                observationCardinalityNext, 0, false);
    }

    function increaseObservationCardinalityNext(uint16 _cardinality) external {
        if (_cardinality > observationCardinalityNext) {
            observationCardinalityNext = _cardinality;
        }
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        int56 currentCum = observations.length > 0
            ? observations[observations.length - 1].tickCumulative
            : int56(0);

        for (uint256 i = 0; i < secondsAgos.length; i++) {
            if (uint256(secondsAgos[i]) >= block.timestamp) {
                // 时间早于第一个观察，用当前tick外推（假设价格一直是当前价格）
                tickCumulatives[i] = currentCum - int56(tick) * int56(uint56(secondsAgos[i]));
            } else {
                uint32 targetTime = uint32(block.timestamp - secondsAgos[i]);
                tickCumulatives[i] = _getTickCumulativeAt(targetTime);
            }
        }
        uint160[] memory secLiq = new uint160[](secondsAgos.length);
        return (tickCumulatives, secLiq);
    }

    /// @notice 获取指定时间点的tickCumulative，使用历史观察插值
    function _getTickCumulativeAt(uint32 targetTime) internal view returns (int56) {
        if (observations.length == 0) return 0;

        // 找到blockTimestamp <= targetTime的最新观察
        int256 beforeIdx = -1;
        for (uint256 j = 0; j < observations.length; j++) {
            if (observations[j].blockTimestamp <= targetTime) {
                beforeIdx = int256(j);
            }
        }

        if (beforeIdx < 0) {
            // 目标时间早于第一个观察，用第一个观察外推
            return observations[0].tickCumulative;
        }

        Observation memory beforeOrAt = observations[uint256(beforeIdx)];
        if (beforeOrAt.blockTimestamp == targetTime) {
            return beforeOrAt.tickCumulative;
        }

        // 找blockTimestamp > targetTime的第一个观察
        int256 afterIdx = -1;
        for (uint256 j = 0; j < observations.length; j++) {
            if (observations[j].blockTimestamp > targetTime) {
                afterIdx = int256(j);
                break;
            }
        }

        if (afterIdx < 0) {
            // 没有后续观察，用当前tick外推
            uint32 delta = targetTime - beforeOrAt.blockTimestamp;
            return beforeOrAt.tickCumulative + int56(tick) * int56(uint56(delta));
        }

        // 在两个观察之间插值
        Observation memory atOrAfter = observations[uint256(afterIdx)];
        uint32 timeDelta = atOrAfter.blockTimestamp - beforeOrAt.blockTimestamp;
        uint32 targetDelta = targetTime - beforeOrAt.blockTimestamp;
        if (timeDelta == 0) return beforeOrAt.tickCumulative;
        int56 cumDelta = atOrAfter.tickCumulative - beforeOrAt.tickCumulative;
        return beforeOrAt.tickCumulative + (cumDelta * int56(uint56(targetDelta))) / int56(uint56(timeDelta));
    }

    function _positionKey(address owner, int24 tickLower, int24 tickUpper)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper));
    }

    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1) {
        require(amount > 0, "V3: ZERO");

        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount
        );

        // 回调支付
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);

        // 更新position
        bytes32 key = _positionKey(recipient, tickLower, tickUpper);
        positions[key].liquidity += amount;
        positions[key].amount0Deposited += amount0;
        positions[key].amount1Deposited += amount1;

        // 更新tick
        ticks[tickLower].liquidityGross += amount;
        ticks[tickLower].liquidityNet += int128(amount);
        ticks[tickLower].initialized = true;
        ticks[tickUpper].liquidityGross += amount;
        ticks[tickUpper].liquidityNet -= int128(amount);
        ticks[tickUpper].initialized = true;

        liquidity += amount;
    }

    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external returns (uint256 amount0, uint256 amount1) {
        bytes32 key = _positionKey(msg.sender, tickLower, tickUpper);
        require(positions[key].liquidity >= amount, "V3: INSUFFICIENT");

        // 按burn比例返回实际存入的本金（mock简化：不模拟无常损失，
        // 因为没有真实swap改变pool余额，价格变化只影响V3 getAmountsForLiquidity的理论值）
        uint256 ratio = uint256(amount) * 1e18 / uint256(positions[key].liquidity);
        amount0 = positions[key].amount0Deposited * ratio / 1e18;
        amount1 = positions[key].amount1Deposited * ratio / 1e18;
        positions[key].amount0Deposited -= amount0;
        positions[key].amount1Deposited -= amount1;

        positions[key].liquidity -= amount;
        // 本金变成tokensOwed（burn后可collect）
        positions[key].tokensOwed0 += uint128(amount0);
        positions[key].tokensOwed1 += uint128(amount1);
        // 模拟手续费收入（mint额外代币给pool，模拟交易者支付的手续费）
        if (mockFeesPerPosition > 0 && amount > 0) {
            IMintable(token0).mint(address(this), mockFeesPerPosition);
            IMintable(token1).mint(address(this), mockFeesPerPosition);
            positions[key].tokensOwed0 += uint128(mockFeesPerPosition);
            positions[key].tokensOwed1 += uint128(mockFeesPerPosition);
        }

        ticks[tickLower].liquidityGross -= amount;
        ticks[tickLower].liquidityNet -= int128(amount);
        ticks[tickUpper].liquidityGross -= amount;
        ticks[tickUpper].liquidityNet += int128(amount);

        if (amount > liquidity) { liquidity = 0; } else { liquidity -= amount; }
    }

    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1) {
        bytes32 key = _positionKey(msg.sender, tickLower, tickUpper);
        PositionInfo storage pos = positions[key];

        // 如果设置了mockFees，在collect时模拟手续费累积
        if (mockFeesPerPosition > 0 && pos.liquidity > 0) {
            IMintable(token0).mint(address(this), mockFeesPerPosition);
            IMintable(token1).mint(address(this), mockFeesPerPosition);
            pos.tokensOwed0 += uint128(mockFeesPerPosition);
            pos.tokensOwed1 += uint128(mockFeesPerPosition);
        }

        amount0 = amount0Requested > pos.tokensOwed0 ? pos.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > pos.tokensOwed1 ? pos.tokensOwed1 : amount1Requested;

        pos.tokensOwed0 -= amount0;
        pos.tokensOwed1 -= amount1;

        if (amount0 > 0) IERC20(token0).safeTransfer(recipient, amount0);
        if (amount1 > 0) IERC20(token1).safeTransfer(recipient, amount1);
    }

    function setMockFees(uint256 fees) external {
        mockFeesPerPosition = fees;
    }

    function initialize(uint160 _sqrtPriceX96) external {
        sqrtPriceX96 = _sqrtPriceX96;
        tick = TickMath.getTickAtSqrtRatio(_sqrtPriceX96);
    }
}

/**
 * @title MockUniswapV3Factory
 */
contract MockUniswapV3Factory {
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;
    int24 public constant tickSpacing = 60;

    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool) {
        require(getPool[tokenA][tokenB][fee] == address(0), "V3: EXISTS");
        int24 ts = fee == 500 ? int24(10) : int24(60);
        MockUniswapV3Pool _pool = new MockUniswapV3Pool(tokenA, tokenB, fee, ts);
        pool = address(_pool);
        getPool[tokenA][tokenB][fee] = pool;
        getPool[tokenB][tokenA][fee] = pool;
    }

    function feeAmountTickSpacing(uint24) external pure returns (int24) {
        return 60;
    }
}
