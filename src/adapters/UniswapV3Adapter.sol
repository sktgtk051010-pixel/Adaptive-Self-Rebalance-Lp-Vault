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

    /// @notice V3 Pool
    IUniswapV3Pool public immutable POOL;

    /// @notice 金库地址
    address public immutable VAULT;

    /// @notice token0
    address public immutable override TOKEN0;

    /// @notice token1
    address public immutable override TOKEN1;

    /// @notice 费率
    uint24 public immutable FEE;

    /// @notice 适配器类型
    AdapterType public override adapterType;

    /// @notice 仓位信息
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

    /// @notice positionId => Position
    mapping(bytes32 => Position) public positions;

    /// @notice 活跃仓位列表
    bytes32[] public activePositionList;

    /// @notice dust阈值
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

        // 验证池token匹配
        require(POOL.token0() == _token0 && POOL.token1() == _token1, "V3Adapter: token mismatch");
    }

    /// @notice 生成positionId
    function getPositionId(int24 tickLower, int24 tickUpper) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(tickLower, tickUpper));
    }

    function pool() external view returns (IUniswapV3Pool) {
        return POOL;
    }

    /// @inheritdoc ILPAdapter
    function addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        bytes calldata data
    ) external onlyVault nonReentrant returns (uint256 amount0, uint256 amount1, bytes32 liquidityId) {
        // 解析data: tickLower, tickUpper
        (int24 tickLower, int24 tickUpper) = abi.decode(data, (int24, int24));
        require(tickLower < tickUpper, "V3Adapter: invalid ticks");

        // 对齐tickSpacing
        int24 tickSpacing = POOL.tickSpacing();
        require(tickLower % tickSpacing == 0 && tickUpper % tickSpacing == 0,
            "V3Adapter: ticks not aligned");

        liquidityId = getPositionId(tickLower, tickUpper);

        // 先计算liquidity，为0则跳过（单币种且区间不在价格范围内）
        (uint160 sqrtPricex96, , , , , , ) = POOL.slot0();
        uint160 sqrtRatioAx96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBx96 = TickMath.getSqrtRatioAtTick(tickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPricex96,
            sqrtRatioAx96,
            sqrtRatioBx96,
            amount0Desired,
            amount1Desired
        );

        if (liquidity == 0) return (0, 0, liquidityId);

        // 从金库转入代币
        if (amount0Desired > 0) {
            IERC20(TOKEN0).safeTransferFrom(VAULT, address(this), amount0Desired);
        }
        if (amount1Desired > 0) {
            IERC20(TOKEN1).safeTransferFrom(VAULT, address(this), amount1Desired);
        }

        // Mint到V3池
        (amount0, amount1) = POOL.mint(
            address(this),
            tickLower,
            tickUpper,
            liquidity,
            abi.encode(msg.sender)
        );

        require(amount0 >= amount0Min && amount1 >= amount1Min, "V3Adapter: slippage");

        // 更新position记录
        Position storage pos = positions[liquidityId];
        if (!pos.active) {
            pos.tickLower = tickLower;
            pos.tickUpper = tickUpper;
            pos.active = true;
            activePositionList.push(liquidityId);
        }
        pos.liquidity += liquidity;

        uint256 bal0 = IERC20(TOKEN0).balanceOf(address(this));
        uint256 bal1 = IERC20(TOKEN1).balanceOf(address(this));
        if (bal0 > 0) IERC20(TOKEN0).safeTransfer(VAULT, bal0);
        if (bal1 > 0) IERC20(TOKEN1).safeTransfer(VAULT, bal1);

        emit V3LiquidityAdded(liquidityId, tickLower, tickUpper, liquidity, amount0, amount1);
    }

    /// @inheritdoc ILPAdapter
    function removeLiquidity(
        bytes32 liquidityId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) external onlyVault nonReentrant returns (uint256 amount0, uint256 amount1) {
        Position storage pos = positions[liquidityId];
        require(pos.active, "V3Adapter: position not found");
        require(liquidity > 0 && liquidity <= pos.liquidity, "V3Adapter: invalid liquidity");

        // Burn流动性
        (amount0, amount1) = POOL.burn(pos.tickLower, pos.tickUpper, liquidity);
        require(amount0 >= amount0Min && amount1 >= amount1Min, "V3Adapter: slippage");

        // Collect代币到vault
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

        // 如果流动性为0，标记为非活跃
        if (pos.liquidity == 0) {
            pos.active = false;
            _removeFromActiveList(liquidityId);
        }

        emit V3LiquidityRemoved(liquidityId, liquidity, amount0, amount1);
    }

    /// @inheritdoc ILPAdapter
    function collectFees(bytes32 liquidityId)
        external
        onlyVault
        nonReentrant
        returns (uint256 fees0, uint256 fees1)
    {
        Position storage pos = positions[liquidityId];
        require(pos.active, "V3Adapter: position not found");

        // 先burn 0流动性来更新手续费
        POOL.burn(pos.tickLower, pos.tickUpper, 0);

        // Collect所有待领手续费
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

        emit V3FeesCollected(liquidityId, fees0, fees1);
    }

    /// @notice V3 Mint回调，支付代币给池
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata /* data */
    ) external override {
        require(msg.sender == address(POOL), "V3Adapter: not pool");
        // data中编码了vault地址，但我们已经在addLiquidity中转入了代币
        // 直接从本合约余额支付
        if (amount0Owed > 0) {
            IERC20(TOKEN0).safeTransfer(address(POOL), amount0Owed);
        }
        if (amount1Owed > 0) {
            IERC20(TOKEN1).safeTransfer(address(POOL), amount1Owed);
        }
    }

    function getLpBalance() external view override returns (uint256) {
        uint256 totalLiquidity = 0;
        for (uint256 i = 0; i < activePositionList.length; i++) {
            bytes32 posId = activePositionList[i];
            Position memory pos = positions[posId];
            totalLiquidity += uint256(pos.liquidity);
        }
        return totalLiquidity;
    }

    /// @inheritdoc ILPAdapter
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

    /// @inheritdoc ILPAdapter
    function getPositionAssets(bytes32 liquidityId)
        external
        view
        override
        returns (AdapterAssets memory assets)
    {
        (assets.amount0, assets.amount1, assets.fees0, assets.fees1) = _calcSinglePosition(liquidityId);
    }

    /// @inheritdoc ILPAdapter
    function getActivePositions() external view override returns (bytes32[] memory) {
        return activePositionList;
    }

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

    // ============ 内部函数 ============

    function _getFeeGrowthInside(Position memory pos)
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        (, int24 tickCurrent, , , , , ) = POOL.slot0();
        (, , uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128, , , , ) =
            POOL.ticks(pos.tickLower);
        (, , uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128, , , , ) =
            POOL.ticks(pos.tickUpper);

        if (tickCurrent < pos.tickLower) {
            feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
            feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
        } else if (tickCurrent >= pos.tickUpper) {
            feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
            feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
        } else {
            feeGrowthInside0X128 = POOL.feeGrowthGlobal0X128() - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
            feeGrowthInside1X128 = POOL.feeGrowthGlobal1X128() - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
        }
    }


    /// @dev 计算单个position对应的资产与手续费，降低外层函数栈深度
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

    function _computeFeesEarned(
        uint128 liquidity,
        uint256 feeGrowthInside1X128,
        uint256 feeGrowthInside0LastX128
    ) internal pure returns (uint256) {
        return FullMath.mulDiv(uint256(liquidity), feeGrowthInside1X128 - feeGrowthInside0LastX128, 1 << 128);
    }

    function _removeFromActiveList(bytes32 id) internal {
        for (uint256 i = 0; i < activePositionList.length; i++) {
            if (activePositionList[i] == id) {
                activePositionList[i] = activePositionList[activePositionList.length - 1];
                activePositionList.pop();
                break;
            }
        }
    }

    /// @inheritdoc ILPAdapter
    function withdrawAll() external onlyVault nonReentrant {
        // 收集所有手续费
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

        // 转移剩余dust
        uint256 bal0 = IERC20(TOKEN0).balanceOf(address(this));
        uint256 bal1 = IERC20(TOKEN1).balanceOf(address(this));
        if (bal0 > 0) IERC20(TOKEN0).safeTransfer(VAULT, bal0);
        if (bal1 > 0) IERC20(TOKEN1).safeTransfer(VAULT, bal1);
    }
}
