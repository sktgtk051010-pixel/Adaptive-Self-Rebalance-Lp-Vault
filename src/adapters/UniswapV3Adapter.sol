// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUniswapV3Pool, IUniswapV3MintCallback} from "../interfaces/IUniswapV3.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {FullMath, TickMath, LiquidityAmounts} from "../libraries/UniswapMath.sol";

/**
 * @title UniswapV3Adapter
 * @notice Uniswap V3流动性适配器，直接管理V3 Pool positions
 * @dev 支持多费率池（0.05%和0.30%），多区间做市
 */
contract UniswapV3Adapter is ILPAdapter, ReentrancyGuard, IUniswapV3MintCallback {
    using SafeERC20 for IERC20;

    IUniswapV3Pool public immutable POOL;
    address public immutable VAULT;
    address public immutable override TOKEN0;
    address public immutable override TOKEN1;
    uint24 public immutable FEE;
    AdapterType public override adapterType;

    /**
     * @notice 仓位信息
     * @param tickLower 区间下限tick
     * @param tickUpper 区间上限tick
     * @param liquidity 流动性数量
     * @param feeGrowthInside0LastX128 上次记录的token0手续费增长率
     * @param feeGrowthInside1LastX128 上次记录的token1手续费增长率
     * @param tokensOwed0 待领取的token0数量
     * @param tokensOwed1 待领取的token1数量
     * @param active 仓位是否活跃
     */
    struct Position {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        bool active;
    }

    mapping(bytes32 => Position) public positions;
    bytes32[] public activePositionList;
    uint256 public constant DUST_THRESHOLD = 1000;

    event V3LiquidityAdded(
        bytes32 indexed positionId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    event V3LiquidityRemoved(
        bytes32 indexed positionId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    event V3FeesCollected(bytes32 indexed positionId, uint256 fees0, uint256 fees1);

    modifier onlyVault() {
        require(msg.sender == VAULT, "V3Adapter: not vault");
        _;
    }

    /**
     * @notice 构造函数
     * @param _pool Uniswap V3 Pool地址
     * @param _vault 金库地址
     * @param _token0 token0地址
     * @param _token1 token1地址
     * @param _type 适配器类型（V3低费率或V3高费率）
     */
    constructor(
        address _pool,
        address _vault,
        address _token0,
        address _token1,
        AdapterType _type
    ) {
        require(_pool != address(0), "V3Adapter: zero pool");
        require(_vault != address(0), "V3Adapter: zero vault");
        require(_type == AdapterType.UNISWAP_V3_LOW_FEE || _type == AdapterType.UNISWAP_V3_HIGH_FEE,
            "V3Adapter: invalid type");

        POOL = IUniswapV3Pool(_pool);
        VAULT = _vault;
        TOKEN0 = _token0;
        TOKEN1 = _token1;
        FEE = IUniswapV3Pool(_pool).fee();
        adapterType = _type;

        require(POOL.token0() == _token0 && POOL.token1() == _token1, "V3Adapter: token mismatch");
    }

    /**
     * @notice 生成positionId
     * @param tickLower 区间下限tick
     * @param tickUpper 区间上限tick
     * @return positionId 仓位ID
     */
    function getPositionId(int24 tickLower, int24 tickUpper) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(tickLower, tickUpper));
    }

    /**
     * @notice 获取V3 Pool地址
     * @return V3 Pool地址
     */
    function pool() external view returns (IUniswapV3Pool) {
        return POOL;
    }

    /**
     * @notice 添加流动性
     * @param amount0Desired 期望存入的token0数量
     * @param amount1Desired 期望存入的token1数量
     * @param amount0Min 最小token0数量（滑点保护）
     * @param amount1Min 最小token1数量（滑点保护）
     * @param data 额外参数，编码为(tickLower, tickUpper)
     * @return amount0 实际存入的token0数量
     * @return amount1 实际存入的token1数量
     * @return liquidityId 流动性位置ID
     */
    function addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        bytes calldata data
    ) external onlyVault nonReentrant returns (uint256 amount0, uint256 amount1, bytes32 liquidityId) {
        (int24 tickLower, int24 tickUpper) = abi.decode(data, (int24, int24));
        _validateTicks(tickLower, tickUpper);

        liquidityId = getPositionId(tickLower, tickUpper);

        uint128 liquidity = _calculateLiquidity(tickLower, tickUpper, amount0Desired, amount1Desired);
        if (liquidity == 0) return (0, 0, liquidityId);

        _transferFromVault(amount0Desired, amount1Desired);

        (amount0, amount1) = POOL.mint(
            address(this),
            tickLower,
            tickUpper,
            liquidity,
            abi.encode(msg.sender)
        );

        require(amount0 >= amount0Min && amount1 >= amount1Min, "V3Adapter: slippage");

        _updatePosition(liquidityId, tickLower, tickUpper, liquidity);

        _returnDust();

        emit V3LiquidityAdded(liquidityId, tickLower, tickUpper, liquidity, amount0, amount1);
    }

    /**
     * @notice 内部函数：验证tick范围有效性
     * @param tickLower 区间下限tick
     * @param tickUpper 区间上限tick
     */
    function _validateTicks(int24 tickLower, int24 tickUpper) internal view {
        require(tickLower < tickUpper, "V3Adapter: invalid ticks");
        int24 tickSpacing = POOL.tickSpacing();
        require(tickLower % tickSpacing == 0 && tickUpper % tickSpacing == 0,
            "V3Adapter: ticks not aligned");
    }

    /**
     * @notice 内部函数：计算可添加的流动性数量
     * @param tickLower 区间下限tick
     * @param tickUpper 区间上限tick
     * @param amount0Desired 期望存入的token0数量
     * @param amount1Desired 期望存入的token1数量
     * @return 流动性数量
     */
    function _calculateLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal view returns (uint128) {
        (uint160 sqrtPricex96, , , , , , ) = POOL.slot0();
        uint160 sqrtRatioAx96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBx96 = TickMath.getSqrtRatioAtTick(tickUpper);
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPricex96,
            sqrtRatioAx96,
            sqrtRatioBx96,
            amount0Desired,
            amount1Desired
        );
    }

    /**
     * @notice 内部函数：从金库转入代币
     * @param amount0Desired token0数量
     * @param amount1Desired token1数量
     */
    function _transferFromVault(uint256 amount0Desired, uint256 amount1Desired) internal {
        if (amount0Desired > 0) {
            IERC20(TOKEN0).safeTransferFrom(VAULT, address(this), amount0Desired);
        }
        if (amount1Desired > 0) {
            IERC20(TOKEN1).safeTransferFrom(VAULT, address(this), amount1Desired);
        }
    }

    /**
     * @notice 内部函数：更新仓位记录
     * @param liquidityId 流动性位置ID
     * @param tickLower 区间下限tick
     * @param tickUpper 区间上限tick
     * @param liquidity 新增流动性数量
     */
    function _updatePosition(
        bytes32 liquidityId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal {
        Position storage pos = positions[liquidityId];
        if (!pos.active) {
            pos.tickLower = tickLower;
            pos.tickUpper = tickUpper;
            pos.active = true;

            (uint256 currFee0, uint256 currFee1) = _getFeeGrowthInside(pos);
            pos.feeGrowthInside0LastX128 = currFee0;
            pos.feeGrowthInside1LastX128 = currFee1;
            activePositionList.push(liquidityId);
        }
        pos.liquidity += liquidity;
    }

    /**
     * @notice 内部函数：将剩余dust转回金库
     */
    function _returnDust() internal {
        uint256 bal0 = IERC20(TOKEN0).balanceOf(address(this));
        uint256 bal1 = IERC20(TOKEN1).balanceOf(address(this));
        if (bal0 > 0) IERC20(TOKEN0).safeTransfer(VAULT, bal0);
        if (bal1 > 0) IERC20(TOKEN1).safeTransfer(VAULT, bal1);
    }

    /**
     * @notice 移除流动性
     * @param liquidityId 流动性位置ID
     * @param liquidity 需要移除的流动性数量
     * @param amount0Min token0的最小接收量
     * @param amount1Min token1的最小接收量
     * @return amount0 实际收到的token0数量
     * @return amount1 实际收到的token1数量
     */
    function removeLiquidity(
        bytes32 liquidityId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) external onlyVault nonReentrant returns (uint256 amount0, uint256 amount1) {
        Position storage pos = positions[liquidityId];
        require(pos.active, "V3Adapter: position not found");
        require(liquidity > 0 && liquidity <= pos.liquidity, "V3Adapter: invalid liquidity");

        (amount0, amount1) = POOL.burn(pos.tickLower, pos.tickUpper, liquidity);
        require(amount0 >= amount0Min && amount1 >= amount1Min, "V3Adapter: slippage");

        (uint128 collected0, uint128 collected1) = POOL.collect(
            VAULT,
            pos.tickLower,
            pos.tickUpper,
            uint128(amount0) + pos.tokensOwed0,
            uint128(amount1) + pos.tokensOwed1
        );
        require(collected0 >= amount0Min
            && collected1 >= amount1Min, "V3Adapter: collect slippage");

        pos.liquidity -= liquidity;
        pos.tokensOwed0 = 0;
        pos.tokensOwed1 = 0;

        (uint256 currFee0, uint256 currFee1) = _getFeeGrowthInside(pos);
        pos.feeGrowthInside0LastX128 = currFee0;
        pos.feeGrowthInside1LastX128 = currFee1;

        if (pos.liquidity == 0) {
            pos.active = false;
            _removeFromActiveList(liquidityId);
        }

        emit V3LiquidityRemoved(liquidityId, liquidity, amount0, amount1);
    }

    /**
     * @notice 领取手续费
     * @param liquidityId 流动性位置ID
     * @return fees0 领取的token0手续费
     * @return fees1 领取的token1手续费
     */
    function collectFees(bytes32 liquidityId)
        external
        onlyVault
        nonReentrant
        returns (uint256 fees0, uint256 fees1)
    {
        Position storage pos = positions[liquidityId];
        require(pos.active, "V3Adapter: position not found");

        POOL.burn(pos.tickLower, pos.tickUpper, 0);

        (uint128 collected0, uint128 collected1) = POOL.collect(
            VAULT,
            pos.tickLower,
            pos.tickUpper,
            type(uint128).max,
            type(uint128).max
        );

        fees0 = uint256(collected0);
        fees1 = uint256(collected1);

        pos.tokensOwed0 = 0;
        pos.tokensOwed1 = 0;
        (uint256 currFee0, uint256 currFee1) = _getFeeGrowthInside(pos);
        pos.feeGrowthInside0LastX128 = currFee0;
        pos.feeGrowthInside1LastX128 = currFee1;

        emit V3FeesCollected(liquidityId, fees0, fees1);
    }

    /**
     * @notice V3 Mint回调，支付代币给池
     * @param amount0Owed 应付token0数量
     * @param amount1Owed 应付token1数量
     */
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata /* data */
    ) external override {
        require(msg.sender == address(POOL), "V3Adapter: not pool");
        if (amount0Owed > 0) {
            IERC20(TOKEN0).safeTransfer(address(POOL), amount0Owed);
        }
        if (amount1Owed > 0) {
            IERC20(TOKEN1).safeTransfer(address(POOL), amount1Owed);
        }
    }

    /**
     * @notice 获取当前总流动性
     * @return 所有活跃仓位的流动性总和
     */
    function getLpBalance() external view override returns (uint256) {
        uint256 totalLiquidity = 0;
        for (uint256 i = 0; i < activePositionList.length; i++) {
            bytes32 posId = activePositionList[i];
            Position memory pos = positions[posId];
            totalLiquidity += uint256(pos.liquidity);
        }
        return totalLiquidity;
    }

    /**
     * @notice 查询适配器总资产（含未领取手续费）
     * @return assets 适配器总资产信息
     */
    function getTotalAssets() external view override returns (AdapterAssets memory assets) {
        for (uint256 i = 0; i < activePositionList.length; i++) {
            bytes32 posId = activePositionList[i];
            (uint256 a0, uint256 a1, uint256 f0, uint256 f1) = _calcSinglePosition(posId);
            assets.amount0 += a0;
            assets.amount1 += a1;
            assets.fees0 += f0;
            assets.fees1 += f1;
        }

        assets.amount0 += IERC20(TOKEN0).balanceOf(address(this));
        assets.amount1 += IERC20(TOKEN1).balanceOf(address(this));
    }

    /**
     * @notice 查询某个仓位的资产
     * @param liquidityId 流动性位置ID
     * @return assets 仓位资产信息
     */
    function getPositionAssets(bytes32 liquidityId)
        external
        view
        override
        returns (AdapterAssets memory assets)
    {
        (assets.amount0, assets.amount1, assets.fees0, assets.fees1) = _calcSinglePosition(liquidityId);
    }

    /**
     * @notice 返回所有活跃仓位ID
     * @return 活跃仓位ID列表
     */
    function getActivePositions() external view override returns (bytes32[] memory) {
        return activePositionList;
    }

    /**
     * @notice 获取仓位详细信息
     * @param liquidityId 流动性位置ID
     * @return tickLower 区间下限tick
     * @return tickUpper 区间上限tick
     * @return liquidity 流动性数量
     * @return tokensOwed0 待领取token0数量
     * @return tokensOwed1 待领取token1数量
     * @return feeGrowthInside0LastX128 上次记录的token0手续费增长率
     * @return feeGrowthInside1LastX128 上次记录的token1手续费增长率
     * @return active 仓位是否活跃
     */
    function getPositionInfo(bytes32 liquidityId)
        external
        view
        returns (
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 tokensOwed0,
            uint256 tokensOwed1,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            bool active
        ) {
            Position memory pos = positions[liquidityId];

            return (
                pos.tickLower,
                pos.tickUpper,
                pos.liquidity,
                pos.tokensOwed0,
                pos.tokensOwed1,
                pos.feeGrowthInside0LastX128,
                pos.feeGrowthInside1LastX128,
                pos.active
            );
    }

    /**
     * @notice 内部函数：获取仓位区间内的手续费增长率
     * @param pos 仓位信息
     * @return feeGrowthInside0X128 token0手续费增长率
     * @return feeGrowthInside1X128 token1手续费增长率
     */
    function _getFeeGrowthInside(Position memory pos)
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        (, int24 tickCurrent, , , , , ) = POOL.slot0();
        uint256 feeGrowthGlobal0 = POOL.feeGrowthGlobal0X128();
        uint256 feeGrowthGlobal1 = POOL.feeGrowthGlobal1X128();

        (, , uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128, , , , ) =
            POOL.ticks(pos.tickLower);
        (, , uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128, , , , ) =
            POOL.ticks(pos.tickUpper);

        unchecked {
            if (tickCurrent < pos.tickLower) {
                feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            } else if (tickCurrent >= pos.tickUpper) {
                feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
                feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 = feeGrowthGlobal0 - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = feeGrowthGlobal1 - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            }
        }
    }

    /**
     * @notice 内部函数：计算单个仓位对应的资产与手续费
     * @param posId 仓位ID
     * @return amount0 仓位对应的token0数量
     * @return amount1 仓位对应的token1数量
     * @return fee0 仓位待领取的token0手续费
     * @return fee1 仓位待领取的token1手续费
     */
    function _calcSinglePosition(bytes32 posId)
        internal
        view
        returns (uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1)
    {
       Position memory pos = positions[posId];
        if (pos.liquidity == 0) {
            return (0, 0, 0, 0);
        }

        (uint160 sqrtPricex96, , , , , , ) = POOL.slot0();
        uint160 sqrtRatioAx96 = TickMath.getSqrtRatioAtTick(pos.tickLower);
        uint160 sqrtRatioBx96 = TickMath.getSqrtRatioAtTick(pos.tickUpper);

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPricex96, sqrtRatioAx96, sqrtRatioBx96, pos.liquidity
        );

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = _getFeeGrowthInside(pos);

        fee0 = _computeFeesEarned(pos.liquidity, feeGrowthInside0X128, pos.feeGrowthInside0LastX128)
            + pos.tokensOwed0;

        fee1 = _computeFeesEarned(pos.liquidity, feeGrowthInside1X128, pos.feeGrowthInside1LastX128)
            + pos.tokensOwed1;
        }

    /**
     * @notice 内部函数：计算已赚取的手续费
     * @param liquidity 流动性数量
     * @param feeGrowthInsideX128 当前手续费增长率
     * @param feeGrowthInsideLastX128 上次记录的手续费增长率
     * @return 手续费数量
     */
    function _computeFeesEarned(
        uint128 liquidity,
        uint256 feeGrowthInsideX128,
        uint256 feeGrowthInsideLastX128
    ) internal pure returns (uint256) {
        unchecked {
            return FullMath.mulDiv(
                uint256(liquidity),
                feeGrowthInsideX128 - feeGrowthInsideLastX128,
                1 << 128
            );
        }
    }

    /**
     * @notice 内部函数：从活跃仓位列表中移除仓位
     * @param id 仓位ID
     */
    function _removeFromActiveList(bytes32 id) internal {
        for (uint256 i = 0; i < activePositionList.length; i++) {
            if (activePositionList[i] == id) {
                activePositionList[i] = activePositionList[activePositionList.length - 1];
                activePositionList.pop();
                break;
            }
        }
    }

    /**
     * @notice 撤出所有流动性并转给vault
     */
    function withdrawAll() external onlyVault nonReentrant {
        for (uint256 i = 0; i < activePositionList.length; i++) {
            bytes32 id = activePositionList[i];
            Position storage pos = positions[id];
            if (pos.liquidity > 0) {
                POOL.burn(pos.tickLower, pos.tickUpper, pos.liquidity);
                POOL.collect(VAULT, pos.tickLower, pos.tickUpper, type(uint128).max, type(uint128).max);
                pos.liquidity = 0;
                pos.active = false;
            }
        }
        delete activePositionList;

        uint256 bal0 = IERC20(TOKEN0).balanceOf(address(this));
        uint256 bal1 = IERC20(TOKEN1).balanceOf(address(this));
        if (bal0 > 0) IERC20(TOKEN0).safeTransfer(VAULT, bal0);
        if (bal1 > 0) IERC20(TOKEN1).safeTransfer(VAULT, bal1);
    }
}
