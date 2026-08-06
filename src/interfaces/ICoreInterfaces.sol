// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniswapV3Pool} from "./IUniswapV3.sol";

/**
 * @title ITWAPOracle
 * @notice TWAP价格预言机接口
 */
interface ITWAPOracle {
    /// @notice 获取预言机池
    function ORACLE_POOL() external view returns (IUniswapV3Pool);

    /// @notice 获取WETH/USDC的TWAP价格
    /// @return sqrtPriceX96Twap 时间加权均价 (sqrt(price) * 2^96)
    /// @return tick 当前V3 tick
    function getTWAPPrice() external view returns (uint160 sqrtPriceX96Twap, int24 tick);

    /// @notice 获取TWAP采样窗口（秒）
    function twapWindow() external view returns (uint32);

    /// @notice 获取WETH地址
    function WETH() external view returns (address);

    /// @notice 获取USDC地址
    function USDC() external view returns (address);

    /// @notice 将token数量按TWAP价格换算
    /// @param amount 输入数量
    /// @param isWETHToUSDC true: WETH->USDC, false: USDC->WETH
    function quote(uint256 amount, bool isWETHToUSDC) external view returns (uint256);
}

/**
 * @title IRebalanceStrategy
 * @notice 再平衡策略接口，决定资金分配
 */
interface IRebalanceStrategy {
    /// @notice 资金分配权重
    struct AllocationWeights {
        uint256 v2Weight;          // V2权重 (basis points, 0-10000)
        uint256 v3LowFeeWeight;    // V3 0.05%权重
        uint256 v3HighFeeWeight;   // V3 0.30%权重
    }

    /// @notice V3多区间分配
    struct V3RangeWeights {
        uint256 tightWeight;   // 窄区间 ±2%
        uint256 mediumWeight;  // 中区间 ±10%
        uint256 wideWeight;    // 宽区间 ±30%
    }

    /// @notice 计算目标资金分配
    /// @param totalWETH 总WETH数量
    /// @param totalUSDC 总USDC数量
    /// @param volatility 当前波动率指标 (0-10000)
    /// @return allocations 各场所分配权重
    /// @return v3Ranges V3多区间权重
    function calculateAllocation(
        uint256 totalWETH,
        uint256 totalUSDC,
        uint256 volatility
    ) external view returns (AllocationWeights memory allocations, V3RangeWeights memory v3Ranges);

    /// @notice 获取V3三层区间的tick范围
    /// @param currentTick 当前tick
    /// @return tightLower 窄区间下限
    /// @return tightUpper 窄区间上限
    /// @return mediumLower 中区间下限
    /// @return mediumUpper 中区间上限
    /// @return wideLower 宽区间下限
    /// @return wideUpper 宽区间上限
    function getRangeTicks(int24 currentTick)
        external
        view
        returns (
            int24 tightLower, int24 tightUpper,
            int24 mediumLower, int24 mediumUpper,
            int24 wideLower, int24 wideUpper
        );

    /// @notice 判断是否需要再平衡
    /// @param currentDeviation 当前偏离度 (basis points)
    function needsRebalance(uint256 currentDeviation) external view returns (bool);

    /// @notice 估算波动率
    function estimateVolatility(uint160 sqrtPriceX96Spot, uint160 sqrtPriceX96Twap) external pure returns (uint256);

    /// @notice 计算价格偏离度
    function calculateDeviation(uint160 sqrtPriceX96Current, uint160 sqrtPriceX96Target) external pure returns (uint256);
}

/**
 * @title IGovernance
 * @notice 治理参数接口
 */
interface IGovernance {
    /// @notice 可治理参数
    struct StrategyParams {
        uint32 twapWindow;           // TWAP窗口秒数
        uint256 rebalanceThreshold;  // 再平衡触发阈值 (bps)
        uint256 incentiveBps;        // 激励比例 (bps)
        uint256 maxSlippageBps;      // 最大滑点 (bps)
        uint256 v2WeightCap;         // V2权重上限
        uint256 v3LowFeeWeightCap;   // V3低费率权重上限
        uint256 v3HighFeeWeightCap;  // V3高费率权重上限
        uint256 tightRangeBps;       // 窄区间范围
        uint256 mediumRangeBps;      // 中区间范围
        uint256 wideRangeBps;        // 宽区间范围
    }

    function getParams() external view returns (StrategyParams memory);
    function setTWAPWindow(uint32 window) external;
    function setRebalanceThreshold(uint256 threshold) external;
    function setIncentiveBps(uint256 bps) external;
    function setMaxSlippageBps(uint256 bps) external;
    function setWeightCaps(uint256 v2, uint256 v3Low, uint256 v3High) external;
    function setRangeBps(uint256 tight, uint256 medium, uint256 wide) external;
}
