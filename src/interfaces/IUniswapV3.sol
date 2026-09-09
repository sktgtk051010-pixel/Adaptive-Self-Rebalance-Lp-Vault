// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IUniswapV3Pool
 * @notice Uniswap V3 Pool 最小接口
 */
interface IUniswapV3Pool {
    /**
     * @notice 获取token0地址
     * @return token0地址
     */
    function token0() external view returns (address);

    /**
     * @notice 获取token1地址
     * @return token1地址
     */
    function token1() external view returns (address);

    /**
     * @notice 获取费率
     * @return 费率（单位：百万分之一）
     */
    function fee() external view returns (uint24);

    /**
     * @notice 获取tick间距
     * @return tick间距
     */
    function tickSpacing() external view returns (int24);

    /**
     * @notice 获取每个tick最大流动性
     * @return 每个tick最大流动性
     */
    function maxLiquidityPerTick() external view returns (uint128);

    /**
     * @notice 获取池当前状态
     * @return sqrtPriceX96 当前价格（sqrt(price) * 2^96）
     * @return tick 当前tick
     * @return observationIndex 观测索引
     * @return observationCardinality 观测基数
     * @return observationCardinalityNext 下一个观测基数
     * @return feeProtocol 协议费率
     * @return unlocked 是否解锁
     */
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    /**
     * @notice 获取当前流动性
     * @return 当前流动性
     */
    function liquidity() external view returns (uint128);

    /**
     * @notice 获取token0全局手续费增长率
     * @return token0全局手续费增长率
     */
    function feeGrowthGlobal0X128() external view returns (uint256);

    /**
     * @notice 获取token1全局手续费增长率
     * @return token1全局手续费增长率
     */
    function feeGrowthGlobal1X128() external view returns (uint256);

    /**
     * @notice 获取tick信息
     * @param tick tick值
     * @return liquidityGross 总流动性
     * @return liquidityNet 净流动性
     * @return feeGrowthOutside0X128 tick外token0手续费增长率
     * @return feeGrowthOutside1X128 tick外token1手续费增长率
     * @return tickCumulativeOutside tick外累计tick
     * @return secondsPerLiquidityOutsideX128 tick外每秒流动性
     * @return secondsOutside tick外秒数
     * @return initialized 是否已初始化
     */
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );

    /**
     * @notice 获取仓位信息
     * @param key 仓位key（owner + tickLower + tickUpper的哈希）
     * @return liquidity 流动性
     * @return feeGrowthInside0LastX128 上次记录的token0手续费增长率
     * @return feeGrowthInside1LastX128 上次记录的token1手续费增长率
     * @return tokensOwed0 待领取token0
     * @return tokensOwed1 待领取token1
     */
    function positions(bytes32 key)
        external
        view
        returns (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    /**
     * @notice Mint流动性
     * @param recipient 接收地址
     * @param tickLower 区间下限tick
     * @param tickUpper 区间上限tick
     * @param amount 流动性数量
     * @param data 回调数据
     * @return amount0 实际存入token0数量
     * @return amount1 实际存入token1数量
     */
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Burn流动性
     * @param tickLower 区间下限tick
     * @param tickUpper 区间上限tick
     * @param amount 流动性数量
     * @return amount0 赎回的token0数量
     * @return amount1 赎回的token1数量
     */
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Collect手续费
     * @param recipient 接收地址
     * @param tickLower 区间下限tick
     * @param tickUpper 区间上限tick
     * @param amount0Requested 请求领取token0数量
     * @param amount1Requested 请求领取token1数量
     * @return amount0 实际领取token0数量
     * @return amount1 实际领取token1数量
     */
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1);

    /**
     * @notice Swap兑换
     * @param recipient 接收地址
     * @param zeroForOne true: token0->token1, false: token1->token0
     * @param amountSpecified 兑换数量（正数为精确输入，负数为精确输出）
     * @param sqrtPriceLimitX96 价格限制
     * @param data 回调数据
     * @return amount0 token0数量变化
     * @return amount1 token1数量变化
     */
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    /**
     * @notice 增加观测基数
     * @param observationCardinalityNext 下一个观测基数
     */
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;

    /**
     * @notice 观测历史数据
     * @param secondsAgos 秒数数组
     * @return tickCumulatives 累计tick数组
     * @return secondsPerLiquidityCumulativeX128s 每秒流动性累计数组
     */
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    /**
     * @notice 初始化池价格
     * @param sqrtPriceX96 初始价格（sqrt(price) * 2^96）
     */
    function initialize(uint160 sqrtPriceX96) external;
}

/**
 * @title IUniswapV3Factory
 * @notice Uniswap V3 Factory 最小接口
 */
interface IUniswapV3Factory {
    /**
     * @notice 获取池地址
     * @param tokenA tokenA地址
     * @param tokenB tokenB地址
     * @param fee 费率
     * @return pool 池地址
     */
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);

    /**
     * @notice 创建池
     * @param tokenA tokenA地址
     * @param tokenB tokenB地址
     * @param fee 费率
     * @return pool 池地址
     */
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);

    /**
     * @notice 获取费率对应的tick间距
     * @param fee 费率
     * @return tick间距
     */
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
}

/**
 * @title IUniswapV3SwapCallback
 * @notice V3 Swap 回调接口
 */
interface IUniswapV3SwapCallback {
    /**
     * @notice Swap回调，支付代币给池
     * @param amount0Delta 应付token0数量变化
     * @param amount1Delta 应付token1数量变化
     * @param data 回调数据
     */
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
}

/**
 * @title IUniswapV3MintCallback
 * @notice V3 Mint 回调接口
 */
interface IUniswapV3MintCallback {
    /**
     * @notice Mint回调，支付代币给池
     * @param amount0Owed 应付token0数量
     * @param amount1Owed 应付token1数量
     * @param data 回调数据
     */
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external;
}

/**
 * @title INonfungiblePositionManager
 * @notice Uniswap V3 NFT Position Manager 接口
 */
interface INonfungiblePositionManager {
    /**
     * @notice 获取仓位信息
     * @param tokenId NFT token ID
     * @return nonce nonce
     * @return operator 操作员
     * @return token0 token0地址
     * @return token1 token1地址
     * @return fee 费率
     * @return tickLower 区间下限tick
     * @return tickUpper 区间上限tick
     * @return liquidity 流动性
     * @return feeGrowthInside0LastX128 上次记录的token0手续费增长率
     * @return feeGrowthInside1LastX128 上次记录的token1手续费增长率
     * @return tokensOwed0 待领取token0
     * @return tokensOwed1 待领取token1
     */
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    /**
     * @notice Mint新仓位NFT
     * @param params Mint参数
     * @return tokenId NFT token ID
     * @return liquidity 流动性
     * @return amount0 实际存入token0数量
     * @return amount1 实际存入token1数量
     */
    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /**
     * @notice 增加流动性
     * @param params 增加流动性参数
     * @return liquidity 新增流动性
     * @return amount0 实际存入token0数量
     * @return amount1 实际存入token1数量
     */
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    /**
     * @notice 减少流动性
     * @param params 减少流动性参数
     * @return amount0 赎回的token0数量
     * @return amount1 赎回的token1数量
     */
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    /**
     * @notice 领取手续费
     * @param params 领取参数
     * @return amount0 领取的token0数量
     * @return amount1 领取的token1数量
     */
    function collect(CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Burn NFT
     * @param tokenId NFT token ID
     */
    function burn(uint256 tokenId) external payable;

    /**
     * @notice 创建并初始化池（如果不存在）
     * @param token0 token0地址
     * @param token1 token1地址
     * @param fee 费率
     * @param sqrtPriceX96 初始价格
     * @return pool 池地址
     */
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);

    /**
     * @notice Mint参数
     * @param token0 token0地址
     * @param token1 token1地址
     * @param fee 费率
     * @param tickLower 区间下限tick
     * @param tickUpper 区间上限tick
     * @param amount0Desired 期望存入token0数量
     * @param amount1Desired 期望存入token1数量
     * @param amount0Min 最小token0数量
     * @param amount1Min 最小token1数量
     * @param recipient 接收地址
     * @param deadline 交易截止时间
     */
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    /**
     * @notice 增加流动性参数
     * @param tokenId NFT token ID
     * @param amount0Desired 期望存入token0数量
     * @param amount1Desired 期望存入token1数量
     * @param amount0Min 最小token0数量
     * @param amount1Min 最小token1数量
     * @param deadline 交易截止时间
     */
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /**
     * @notice 减少流动性参数
     * @param tokenId NFT token ID
     * @param liquidity 减少的流动性数量
     * @param amount0Min 最小token0数量
     * @param amount1Min 最小token1数量
     * @param deadline 交易截止时间
     */
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /**
     * @notice 领取手续费参数
     * @param tokenId NFT token ID
     * @param recipient 接收地址
     * @param amount0Max 最大领取token0数量
     * @param amount1Max 最大领取token1数量
     */
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
}

/**
 * @title ISwapRouter
 * @notice Uniswap V3 Swap Router 接口
 */
interface ISwapRouter {
    /**
     * @notice 精确输入单池兑换参数
     * @param tokenIn 输入token地址
     * @param tokenOut 输出token地址
     * @param fee 费率
     * @param recipient 接收地址
     * @param deadline 交易截止时间
     * @param amountIn 输入数量
     * @param amountOutMinimum 最小输出数量
     * @param sqrtPriceLimitX96 价格限制
     */
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /**
     * @notice 精确输入单池兑换
     * @param params 兑换参数
     * @return amountOut 输出数量
     */
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}
