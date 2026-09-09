// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRebalanceStrategy, IGovernance} from "../interfaces/ICoreInterfaces.sol";
import {TickMath} from "../libraries/UniswapMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FullMath} from "../libraries/UniswapMath.sol";

/**
 * @title AdaptiveRebalanceStrategy
 * @notice 自适应再平衡策略
 */
contract AdaptiveRebalanceStrategy is IRebalanceStrategy, Ownable {
    address public governance;

    uint256 public constant BPS_SCALE = 10000;
    int24 public constant TICK_SPACING_LOW = 10;   // 0.05%
    int24 public constant TICK_SPACING_HIGH = 60;  // 0.30%

    uint256 public constant LOW_VOL_THRESHOLD = 2000;   // 价格偏离 ≤20%：低波动
    uint256 public constant MID_VOL_THRESHOLD = 5000;   // 20% < 价格偏离 ≤50%：中波动

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

    /**
     * @notice 根据波动率计算资产分配权重和V3区间权重
     * @param volatility 当前波动率
     * @return allocations 具体占比
     * @return v3Ranges V3区间权重
     */

    function calculateAllocation(
        uint256 /* totalWETH */,
        uint256 /* totalUSDC */,
        uint256 volatility
    ) external pure override returns (AllocationWeights memory allocations, V3RangeWeights memory v3Ranges) {
        if (volatility <= LOW_VOL_THRESHOLD) {
            // 低波动
            allocations = AllocationWeights({
                v2Weight: 1000,       
                v3LowFeeWeight: 3000,  
                v3HighFeeWeight: 6000 
            });
            v3Ranges = V3RangeWeights({
                tightWeight: 6000,  
                mediumWeight: 3000, 
                wideWeight: 1000 
            });
        } else if (volatility <= MID_VOL_THRESHOLD) {
            // 中波动
            allocations = AllocationWeights({
                v2Weight: 2500,     
                v3LowFeeWeight: 3000, 
                v3HighFeeWeight: 4500 
            });
            v3Ranges = V3RangeWeights({
                tightWeight: 3000,
                mediumWeight: 5000,
                wideWeight: 2000
            });
        } else {
            // 高波动
            allocations = AllocationWeights({
                v2Weight: 5000,       
                v3LowFeeWeight: 2500,  
                v3HighFeeWeight: 2500  
            });
            v3Ranges = V3RangeWeights({
                tightWeight: 1000,
                mediumWeight: 3000,
                wideWeight: 6000
            });
        }
    }

    /**
     * @notice 根据当前tick计算V3区间的tick范围·
     * @param currentTick 当前tick
     * @return tightLower 紧区间下限
     * @return tightUpper 紧区间上限
     * @return mediumLower 中区间下限
     * @return mediumUpper 中区间上限
     * @return wideLower 宽区间下限 
     * @return wideUpper 宽区间上限
     */
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

        tightLower = _alignTick(currentTick - tightDelta, TICK_SPACING_HIGH);
        tightUpper = _alignTick(currentTick + tightDelta, TICK_SPACING_HIGH);
        mediumLower = _alignTick(currentTick - mediumDelta, TICK_SPACING_HIGH);
        mediumUpper = _alignTick(currentTick + mediumDelta, TICK_SPACING_HIGH);
        wideLower = _alignTick(currentTick - wideDelta, TICK_SPACING_HIGH);
        wideUpper = _alignTick(currentTick + wideDelta, TICK_SPACING_HIGH);

        tightLower = _clampTick(tightLower);
        tightUpper = _clampTick(tightUpper);
        mediumLower = _clampTick(mediumLower);
        mediumUpper = _clampTick(mediumUpper);
        wideLower = _clampTick(wideLower);
        wideUpper = _clampTick(wideUpper);
    }

    /// @inheritdoc IRebalanceStrategy

    /**
     * @notice 判断是否需要再平衡
     * @param currentDeviation 当前价格偏离度
     * @return bool 是否需要再平衡
     */
    function needsRebalance(uint256 currentDeviation) external view override returns (bool) {
        return currentDeviation >= rebalanceThresholdBps;
    }

    /**
     * @notice 设置再平衡阈值
     * @param _bps 再平衡阈值
     */
    function setRebalanceThreshold(uint256 _bps) external onlyGovernance {
        require(_bps >= 100 && _bps <= 5000, "Strategy: invalid threshold");
        emit ThresholdUpdated(rebalanceThresholdBps, _bps);
        rebalanceThresholdBps = _bps;
    }

    /**
     * @notice 更新治理地址
     * @param _gov 治理地址
     */
    function setGovernance(address _gov) external onlyOwner {
        emit GovernanceUpdated(governance, _gov);
        governance = _gov;
    }

    /**
     * @notice 计算当前价格偏离度
     * @param sqrtPriceX96Current 当前价格（sqrt(price) * 2^96）
     * @param sqrtPriceX96Target 上次再平衡价格（sqrt(price) * 2^96）
     * @return uint256 偏离度
     */
    function calculateDeviation(uint160 sqrtPriceX96Current, uint160 sqrtPriceX96Target)
        external
        pure
        returns (uint256)
    {
        return _computePriceDeviationBps(sqrtPriceX96Current, sqrtPriceX96Target);
    }

    /**
     * @notice 估算波动率
     * @param sqrtPriceX96Spot 即时价格 （sqrt(price) * 2^96）
     * @param sqrtPriceX96Twap TWAP价格 （sqrt(price) * 2^96）
     * @return uint256 波动率
     */
    function estimateVolatility(uint160 sqrtPriceX96Spot, uint160 sqrtPriceX96Twap)
        external
        pure
        returns (uint256)
    {
        return _computePriceDeviationBps(sqrtPriceX96Spot, sqrtPriceX96Twap);
    }

    // ============ 内部工具 ============

    /**
     * @notice 计算价格偏离度
     * @param sqrtCurrent 当前价格（sqrt(price)）
     * @param sqrtTarget 目标价格（sqrt(price)）
     * @return uint256 偏离度（BPS）
     */
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

    /**
     * @notice 对齐刻度
     * @param tick 刻度
     * @param spacing 刻度间隔
     * @return int24 对齐后的刻度
     */
    function _alignTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 remainder = tick % spacing;
        if (remainder < 0) remainder += spacing;
        return tick - remainder;
    }

    /**
     * @notice 限制刻度在有效范围内
     * @param tick 刻度
     * @return int24 限制后的刻度
     */
    function _clampTick(int24 tick) internal pure returns (int24) {
        if (tick < TickMath.MIN_TICK) return TickMath.MIN_TICK;
        if (tick > TickMath.MAX_TICK) return TickMath.MAX_TICK;
        return tick;
    }
}
