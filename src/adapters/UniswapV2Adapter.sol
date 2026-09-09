// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUniswapV2Router02, IUniswapV2Pair, IUniswapV2Factory} from "../interfaces/IUniswapV2.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {FullMath} from "../libraries/UniswapMath.sol";

/**
 * @title UniswapV2Adapter
 * @notice Uniswap V2流动性适配器
 * @dev 通过V2 Router管理LP，金库持有LP token
 */
contract UniswapV2Adapter is ILPAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_SCALE = 10000;
    uint256 public maxSlippageBps = 100;

    IUniswapV2Router02 public immutable ROUTER;
    IUniswapV2Pair public immutable PAIR;
    IUniswapV2Factory public immutable FACTORY;

    address public immutable VAULT;
    address public immutable override TOKEN0;
    address public immutable override TOKEN1;

    AdapterType public constant override adapterType = AdapterType.UNISWAP_V2;

    bytes32 public constant POSITION_ID = keccak256("UniswapV2Adapter.POSITION");

    uint256 public constant DUST_THRESHOLD = 1000;

    event LiquidityAdded(uint256 amount0, uint256 amount1, uint256 liquidity);
    event LiquidityRemoved(uint256 amount0, uint256 amount1, uint256 liquidity);
    event FeesCollected(uint256 fees0, uint256 fees1);

    modifier onlyVault() {
        require(msg.sender == VAULT, "V2Adapter: not vault");
        _;
    }

    /**
     * @notice 构造函数
     * @param _router Uniswap V2 Router地址
     * @param _vault 金库地址
     * @param _token0 token0地址
     * @param _token1 token1地址
     */
    constructor(
        address _router,
        address _vault,
        address _token0,
        address _token1
    ) {
        require(_router != address(0), "V2Adapter: zero router");
        require(_vault != address(0), "V2Adapter: zero vault");
        require(_token0 != address(0) && _token1 != address(0), "V2Adapter: zero tokens");

        ROUTER = IUniswapV2Router02(_router);
        VAULT = _vault;
        FACTORY = IUniswapV2Factory(ROUTER.factory());
        TOKEN0 = _token0;
        TOKEN1 = _token1;

        address pairAddress = FACTORY.getPair(_token0, _token1);
        if (pairAddress == address(0)) {
            pairAddress = FACTORY.createPair(_token0, _token1);
        }
        PAIR = IUniswapV2Pair(pairAddress);

        IERC20(_token0).forceApprove(_router, type(uint256).max);
        IERC20(_token1).forceApprove(_router, type(uint256).max);
        IERC20(pairAddress).forceApprove(_router, type(uint256).max);
    }

    /**
     * @notice 添加流动性
     * @param amount0Desired 期望存入的token0数量
     * @param amount1Desired 期望存入的token1数量
     * @return amount0 实际存入的token0数量
     * @return amount1 实际存入的token1数量
     * @return liquidityId 流动性位置ID，V2固定为POSITION_ID
     */
    function addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256,
        uint256,
        bytes calldata /* data */
    ) external onlyVault nonReentrant returns (uint256 amount0, uint256 amount1, bytes32 liquidityId) {
        require(amount0Desired > 0 || amount1Desired > 0, "V2Adapter: zero amounts");

        if (amount0Desired > 0) {
            IERC20(TOKEN0).safeTransferFrom(VAULT, address(this), amount0Desired);
        }
        if (amount1Desired > 0) {
            IERC20(TOKEN1).safeTransferFrom(VAULT, address(this), amount1Desired);
        }

        (uint112 reserve0, uint112 reserve1, ) = PAIR.getReserves();
        uint256 slippageMin = BPS_SCALE - maxSlippageBps;
        uint256 amount0Min;
        uint256 amount1Min;

        if (reserve0 == 0 && reserve1 == 0) {
            amount0Min = FullMath.mulDiv(amount0Desired, slippageMin, BPS_SCALE);
            amount1Min = FullMath.mulDiv(amount1Desired, slippageMin, BPS_SCALE);
        } else {
            uint256 amount1Optimal = FullMath.mulDiv(amount0Desired, uint256(reserve1), uint256(reserve0));
            if (amount1Optimal <= amount1Desired) {
                amount0Min = FullMath.mulDiv(amount0Desired, slippageMin, BPS_SCALE);
                amount1Min = FullMath.mulDiv(amount1Optimal, slippageMin, BPS_SCALE);
            } else {
                uint256 amount0Optimal = FullMath.mulDiv(amount1Desired, uint256(reserve0), uint256(reserve1));
                amount0Min = FullMath.mulDiv(amount0Optimal, slippageMin, BPS_SCALE);
                amount1Min = FullMath.mulDiv(amount1Desired, slippageMin, BPS_SCALE);
            }
        }

        (amount0, amount1, ) = ROUTER.addLiquidity(
            TOKEN0,
            TOKEN1,
            amount0Desired,
            amount1Desired,
            amount0Min,
            amount1Min,
            address(this),
            block.timestamp + 600
        );

        uint256 bal0 = IERC20(TOKEN0).balanceOf(address(this));
        uint256 bal1 = IERC20(TOKEN1).balanceOf(address(this));
        if (bal0 > 0) IERC20(TOKEN0).safeTransfer(VAULT, bal0);
        if (bal1 > 0) IERC20(TOKEN1).safeTransfer(VAULT, bal1);

        liquidityId = POSITION_ID;
        emit LiquidityAdded(amount0, amount1, PAIR.balanceOf(address(this)));
    }

    /**
     * @notice 移除流动性
     * @param liquidity 需要移除的LP数量
     * @param amount0Min token0的最小接收量
     * @param amount1Min token1的最小接收量
     * @return amount0 实际收到的token0数量
     * @return amount1 实际收到的token1数量
     */
    function removeLiquidity(
        bytes32 /* liquidityId */,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) external onlyVault nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(liquidity > 0, "V2Adapter: zero liquidity");
        require(liquidity <= PAIR.balanceOf(address(this)), "V2Adapter: insufficient LP");

        (amount0, amount1) = ROUTER.removeLiquidity(
            TOKEN0,
            TOKEN1,
            liquidity,
            amount0Min,
            amount1Min,
            VAULT,
            block.timestamp + 600
        );

        emit LiquidityRemoved(amount0, amount1, liquidity);
    }

    /**
     * @notice 领取手续费
     * @return fees0 领取的token0手续费（固定为0）
     * @return fees1 领取的token1手续费（固定为0）
     */
    function collectFees(bytes32 /* liquidityId */)
        external
        onlyVault
        nonReentrant
        returns (uint256 fees0, uint256 fees1)
    {
        fees0 = 0;
        fees1 = 0;
        emit FeesCollected(0, 0);
    }

    /**
     * @notice 查询适配器总资产（含未领取手续费）
     * @return assets 适配器总资产信息
     */
    function getTotalAssets() external view override returns (AdapterAssets memory assets) {
        return _getTotalAssets();
    }

    /**
     * @notice 查询某个仓位的资产
     * @return assets 仓位资产信息
     */
    function getPositionAssets(bytes32 /* liquidityId */)
        external
        view
        override
        returns (AdapterAssets memory assets)
    {
        return _getTotalAssets();
    }

    /**
     * @notice 返回所有活跃仓位ID
     * @return positions 活跃仓位ID列表
     */
    function getActivePositions() external pure override returns (bytes32[] memory positions) {
        positions = new bytes32[](1);
        positions[0] = POSITION_ID;
    }

    /**
     * @notice 获取当前LP余额
     * @return LP代币数量
     */
    function getLpBalance() external view override returns (uint256) {
        return PAIR.balanceOf(address(this));
    }

    /**
     * @notice 撤出所有流动性并转给vault
     */
    function withdrawAll() external onlyVault nonReentrant {
        uint256 lpBalance = PAIR.balanceOf(address(this));

        if (lpBalance > 0) {
            (uint112 reserve0, uint112 reserve1, ) = PAIR.getReserves();
            uint256 totalSupply = PAIR.totalSupply();
            uint256 slippageMin = BPS_SCALE - maxSlippageBps;
            uint256 expected0 = FullMath.mulDiv(uint256(reserve0), lpBalance, totalSupply);
            uint256 expected1 = FullMath.mulDiv(uint256(reserve1), lpBalance, totalSupply);
            uint256 amount0Min = FullMath.mulDiv(expected0, slippageMin, BPS_SCALE);
            uint256 amount1Min = FullMath.mulDiv(expected1, slippageMin, BPS_SCALE);
            ROUTER.removeLiquidity(
                TOKEN0,
                TOKEN1,
                lpBalance,
                amount0Min,
                amount1Min,
                VAULT,
                block.timestamp + 600
            );
        }
        uint256 bal0 = IERC20(TOKEN0).balanceOf(address(this));
        uint256 bal1 = IERC20(TOKEN1).balanceOf(address(this));
        if (bal0 > 0) IERC20(TOKEN0).safeTransfer(VAULT, bal0);
        if (bal1 > 0) IERC20(TOKEN1).safeTransfer(VAULT, bal1);
    }

    /**
     * @notice 内部函数：计算适配器总资产
     * @return assets 适配器总资产信息
     */
    function _getTotalAssets() internal view returns (AdapterAssets memory assets) {
        uint256 lpBalance = PAIR.balanceOf(address(this));
        if (lpBalance == 0) {
            assets.amount0 = IERC20(TOKEN0).balanceOf(address(this));
            assets.amount1 = IERC20(TOKEN1).balanceOf(address(this));
            return assets;
        }

        (uint112 reserve0, uint112 reserve1, ) = PAIR.getReserves();
        uint256 totalSupply = PAIR.totalSupply();

        assets.amount0 = FullMath.mulDiv(lpBalance, uint256(reserve0), totalSupply);
        assets.amount1 = FullMath.mulDiv(lpBalance, uint256(reserve1), totalSupply);

        assets.amount0 += IERC20(TOKEN0).balanceOf(address(this));
        assets.amount1 += IERC20(TOKEN1).balanceOf(address(this));

        assets.fees0 = 0;
        assets.fees1 = 0;
    }
}
