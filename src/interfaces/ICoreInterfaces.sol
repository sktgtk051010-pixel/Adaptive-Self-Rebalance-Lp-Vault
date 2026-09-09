// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniswapV3Pool} from "./IUniswapV3.sol";

/**
 * @title ITWAPOracle
 * @notice TWAP价格预言机接口
 */
interface ITWAPOracle {
    /**
     * @notice 获取预言机池
     * @return 预言机V3 Pool地址
     */
    function ORACLE_POOL() external view returns (IUniswapV3Pool);

    /**
     * @notice 获取WETH/USDC的TWAP价格
     * @return sqrtPriceX96Twap 时间加权均价 (sqrt(price) * 2^96)
     * @return tick 当前V3 tick
     */
    function getTWAPPrice() external view returns (uint160 sqrtPriceX96Twap, int24 tick);

    /**
     * @notice 获取TWAP采样窗口（秒）
     * @return 采样窗口秒数
     */
    function twapWindow() external view returns (uint32);

    /**
     * @notice 获取WETH地址
     * @return WETH地址
     */
    function WETH() external view returns (address);

    /**
     * @notice 获取USDC地址
     * @return USDC地址
     */
    function USDC() external view returns (address);

    /**
     * @notice 将token数量按TWAP价格换算
     * @param amount 输入数量
     * @param isWETHToUSDC true: WETH->USDC, false: USDC->WETH
     * @return 换算后的数量
     */
    function quote(uint256 amount, bool isWETHToUSDC) external view returns (uint256);
}

/**
 * @title IRebalanceStrategy
 * @notice 再平衡策略接口，决定资金分配
 */
interface IRebalanceStrategy {
    /**
     * @notice 资金分配权重
     * @param v2Weight V2权重 (basis points, 0-10000)
     * @param v3LowFeeWeight V3 0.05%权重
     * @param v3HighFeeWeight V3 0.30%权重
     */
    struct AllocationWeights {
        uint256 v2Weight;
        uint256 v3LowFeeWeight;
        uint256 v3HighFeeWeight;
    }

    /**
     * @notice V3多区间分配
     * @param tightWeight 窄区间权重
     * @param mediumWeight 中区间权重
     * @param wideWeight 宽区间权重
     */
    struct V3RangeWeights {
        uint256 tightWeight;
        uint256 mediumWeight;
        uint256 wideWeight;
    }

    /**
     * @notice 计算目标资金分配
     * @param totalWETH 总WETH数量
     * @param totalUSDC 总USDC数量
     * @param volatility 当前波动率指标 (0-10000)
     * @return allocations 各场所分配权重
     * @return v3Ranges V3多区间权重
     */
    function calculateAllocation(
        uint256 totalWETH,
        uint256 totalUSDC,
        uint256 volatility
    ) external view returns (AllocationWeights memory allocations, V3RangeWeights memory v3Ranges);

    /**
     * @notice 获取V3三层区间的tick范围
     * @param currentTick 当前tick
     * @return tightLower 窄区间下限
     * @return tightUpper 窄区间上限
     * @return mediumLower 中区间下限
     * @return mediumUpper 中区间上限
     * @return wideLower 宽区间下限
     * @return wideUpper 宽区间上限
     */
    function getRangeTicks(int24 currentTick)
        external
        view
        returns (
            int24 tightLower, int24 tightUpper,
            int24 mediumLower, int24 mediumUpper,
            int24 wideLower, int24 wideUpper
        );

    /**
     * @notice 判断是否需要再平衡
     * @param currentDeviation 当前偏离度 (basis points)
     * @return 是否需要再平衡
     */
    function needsRebalance(uint256 currentDeviation) external view returns (bool);

    /**
     * @notice 估算波动率
     * @param sqrtPriceX96Spot 当前现货价格
     * @param sqrtPriceX96Twap TWAP价格
     * @return 波动率指标 (0-10000)
     */
    function estimateVolatility(uint160 sqrtPriceX96Spot, uint160 sqrtPriceX96Twap) external pure returns (uint256);

    /**
     * @notice 计算价格偏离度
     * @param sqrtPriceX96Current 当前价格
     * @param sqrtPriceX96Target 目标价格
     * @return 偏离度 (basis points)
     */
    function calculateDeviation(uint160 sqrtPriceX96Current, uint160 sqrtPriceX96Target) external pure returns (uint256);
}

/**
 * @title IGovernance
 * @notice 治理参数接口
 */
interface IGovernance {
    /**
     * @notice 可治理参数
     * @param twapWindow TWAP窗口秒数
     * @param rebalanceThreshold 再平衡触发阈值 (bps)
     * @param incentiveBps 激励比例 (bps)
     * @param maxSlippageBps 最大滑点 (bps)
     * @param v2WeightCap V2权重上限
     * @param v3LowFeeWeightCap V3低费率权重上限
     * @param v3HighFeeWeightCap V3高费率权重上限
     * @param tightRangeBps 窄区间范围
     * @param mediumRangeBps 中区间范围
     * @param wideRangeBps 宽区间范围
     */
    struct StrategyParams {
        uint32 twapWindow;
        uint256 rebalanceThreshold;
        uint256 incentiveBps;
        uint256 maxSlippageBps;
        uint256 v2WeightCap;
        uint256 v3LowFeeWeightCap;
        uint256 v3HighFeeWeightCap;
        uint256 tightRangeBps;
        uint256 mediumRangeBps;
        uint256 wideRangeBps;
    }

    /**
     * @notice 获取所有治理参数
     * @return 治理参数结构体
     */
    function getParams() external view returns (StrategyParams memory);

    /**
     * @notice 设置TWAP窗口
     * @param window TWAP窗口秒数
     */
    function setTWAPWindow(uint32 window) external;

    /**
     * @notice 设置再平衡触发阈值
     * @param threshold 阈值 (bps)
     */
    function setRebalanceThreshold(uint256 threshold) external;

    /**
     * @notice 设置激励比例
     * @param bps 激励比例 (bps)
     */
    function setIncentiveBps(uint256 bps) external;

    /**
     * @notice 设置最大滑点
     * @param bps 最大滑点 (bps)
     */
    function setMaxSlippageBps(uint256 bps) external;

    /**
     * @notice 设置各场所权重上限
     * @param v2 V2权重上限
     * @param v3Low V3低费率权重上限
     * @param v3High V3高费率权重上限
     */
    function setWeightCaps(uint256 v2, uint256 v3Low, uint256 v3High) external;

    /**
     * @notice 设置V3区间范围
     * @param tight 窄区间范围
     * @param medium 中区间范围
     * @param wide 宽区间范围
     */
    function setRangeBps(uint256 tight, uint256 medium, uint256 wide) external;
}
