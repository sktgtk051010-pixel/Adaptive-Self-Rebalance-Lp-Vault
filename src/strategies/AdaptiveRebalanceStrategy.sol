// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRebalanceStrategy, IGovernance} from "../interfaces/ICoreInterfaces.sol";
import {TickMath} from "../libraries/UniswapMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FullMath} from "../libraries/UniswapMath.sol";

/**
 * @title AdaptiveRebalanceStrategy
 * @notice 自适应再平衡策略，对标Gamma Strategies核心算法
 * @dev 根据市场波动率动态调整V2/V3资金分配和V3多区间权重
 */
contract AdaptiveRebalanceStrategy is IRebalanceStrategy, Ownable {
    /// @notice 治理合约
    address public governance;

    uint256 public constant BPS_SCALE = 10000;

    /// @notice WETH/USDC的tick spacing (V3 0.30%池=60, 0.05%池=10)
    int24 public constant TICK_SPACING_LOW = 10;   // 0.05%
    int24 public constant TICK_SPACING_HIGH = 60;  // 0.30%

    /// @notice 波动率阈值
    uint256 public constant LOW_VOL_THRESHOLD = 2000;   // 价格偏离 ≤20%：低波动
    uint256 public constant MID_VOL_THRESHOLD = 5000;   // 20% < 价格偏离 ≤50%：中波动
    // >50% 高波动

    /// @notice 再平衡偏离阈值（basis points），默认5%
    uint256 public rebalanceThresholdBps = 500;

    event GovernanceUpdated(address oldGov, address newGov);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    modifier onlyGovernance() {
        require(msg.sender == governance || msg.sender == owner(), "Strategy: not authorized");
        _;
    }

    constructor(address _governance) Ownable(msg.sender) {
        governance = _governance;
    }

    /// @inheritdoc IRebalanceStrategy
    /// @dev 根据波动率动态分配：
    /// - 低波动(<20%)：更多资金在V3高费率窄区间赚手续费
    /// - 中波动(20-50%)：均衡分配
    /// - 高波动(>50%)：更多资金在V2全区间抗无常损失
    function calculateAllocation(
        uint256 /* totalWETH */,
        uint256 /* totalUSDC */,
        uint256 volatility
    ) external pure override returns (AllocationWeights memory allocations, V3RangeWeights memory v3Ranges) {
        if (volatility <= LOW_VOL_THRESHOLD) {
            // 低波动：V3为主，窄区间重仓
            allocations = AllocationWeights({
                v2Weight: 1000,        // 10%
                v3LowFeeWeight: 3000,  // 30% (0.05%池，深度好)
                v3HighFeeWeight: 6000  // 60% (0.30%池，手续费高)
            });
            v3Ranges = V3RangeWeights({
                tightWeight: 6000,   // 60%窄区间
                mediumWeight: 3000,  // 30%中区间
                wideWeight: 1000     // 10%宽区间
            });
        } else if (volatility <= MID_VOL_THRESHOLD) {
            // 中波动：均衡配置
            allocations = AllocationWeights({
                v2Weight: 2500,        // 25%
                v3LowFeeWeight: 3000,  // 30%
                v3HighFeeWeight: 4500  // 45%
            });
            v3Ranges = V3RangeWeights({
                tightWeight: 3000,
                mediumWeight: 5000,
                wideWeight: 2000
            });
        } else {
            // 高波动：V2为主，宽区间防守
            allocations = AllocationWeights({
                v2Weight: 5000,        // 50%
                v3LowFeeWeight: 2500,  // 25%
                v3HighFeeWeight: 2500  // 25%
            });
            v3Ranges = V3RangeWeights({
                tightWeight: 1000,
                mediumWeight: 3000,
                wideWeight: 6000
            });
        }
    }

    /// @inheritdoc IRebalanceStrategy
    function getRangeTicks(int24 currentTick)
        external
        pure
        override
        returns (
            int24 tightLower, int24 tightUpper,
            int24 mediumLower, int24 mediumUpper,
            int24 wideLower, int24 wideUpper
        )
    {
        // ±2% 窄区间
        // tick ≈ log(1.0001, price)
        // 2% ≈ log(1.02)/log(1.0001) ≈ 198 ticks
        // 10% ≈ log(1.10)/log(1.0001) ≈ 953 ticks
        // 30% ≈ log(1.30)/log(1.0001) ≈ 2624 ticks

        int24 tightDelta = 198;
        int24 mediumDelta = 953;
        int24 wideDelta = 2624;

        // 使用0.30%池的tick spacing=60对齐
        tightLower = _alignTick(currentTick - tightDelta, TICK_SPACING_HIGH);
        tightUpper = _alignTick(currentTick + tightDelta, TICK_SPACING_HIGH);
        mediumLower = _alignTick(currentTick - mediumDelta, TICK_SPACING_HIGH);
        mediumUpper = _alignTick(currentTick + mediumDelta, TICK_SPACING_HIGH);
        wideLower = _alignTick(currentTick - wideDelta, TICK_SPACING_HIGH);
        wideUpper = _alignTick(currentTick + wideDelta, TICK_SPACING_HIGH);

        // 边界检查
        tightLower = _clampTick(tightLower);
        tightUpper = _clampTick(tightUpper);
        mediumLower = _clampTick(mediumLower);
        mediumUpper = _clampTick(mediumUpper);
        wideLower = _clampTick(wideLower);
        wideUpper = _clampTick(wideUpper);
    }

    /// @inheritdoc IRebalanceStrategy
    function needsRebalance(uint256 currentDeviation) external view override returns (bool) {
        return currentDeviation >= rebalanceThresholdBps;
    }

    /// @notice 设置再平衡阈值
    function setRebalanceThreshold(uint256 _bps) external onlyGovernance {
        require(_bps >= 100 && _bps <= 5000, "Strategy: invalid threshold");
        emit ThresholdUpdated(rebalanceThresholdBps, _bps);
        rebalanceThresholdBps = _bps;
    }

    /// @notice 更新治理地址
    function setGovernance(address _gov) external onlyOwner {
        emit GovernanceUpdated(governance, _gov);
        governance = _gov;
    }

    /// @notice 计算当前价格偏离度（basis points）
    /// @param sqrtPriceX96Current 当前价格 (sqrt(price) * 2^96)
    /// @param sqrtPriceX96Target 目标价格（上次再平衡价格）
    function calculateDeviation(uint160 sqrtPriceX96Current, uint160 sqrtPriceX96Target)
        external
        pure
        returns (uint256)
    {
        return _computePriceDeviationBps(sqrtPriceX96Current, sqrtPriceX96Target);
    }

    /// @notice 估算波动率（基于TWAP与即时价格差异）
    /// @param sqrtPriceX96Spot 即时价格 (sqrt(price) * 2^96)
    /// @param sqrtPriceX96Twap TWAP价格 (sqrt(price) * 2^96)
    function estimateVolatility(uint160 sqrtPriceX96Spot, uint160 sqrtPriceX96Twap)
        external
        pure
        returns (uint256)
    {
        return _computePriceDeviationBps(sqrtPriceX96Spot, sqrtPriceX96Twap);
    }

    // ============ 内部工具 ============

    function _computePriceDeviationBps(uint160 sqrtCurrent, uint160 sqrtTarget) 
        internal 
        pure 
        returns (uint256) 
    {
        if (sqrtTarget == 0) return 0;
        uint256 diff = sqrtCurrent > sqrtTarget
            ? uint256(sqrtCurrent) - uint256(sqrtTarget)
            : uint256(sqrtTarget) - uint256(sqrtCurrent);
        
        uint256 sum = uint256(sqrtCurrent) + uint256(sqrtTarget);

        uint256 temp = FullMath.mulDiv(diff, sum, sqrtTarget);
        return FullMath.mulDiv(temp, BPS_SCALE, sqrtTarget);
    }

    function _alignTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 remainder = tick % spacing;
        if (remainder < 0) remainder += spacing;
        return tick - remainder;
    }

    function _clampTick(int24 tick) internal pure returns (int24) {
        if (tick < TickMath.MIN_TICK) return TickMath.MIN_TICK;
        if (tick > TickMath.MAX_TICK) return TickMath.MAX_TICK;
        return tick;
    }
}
