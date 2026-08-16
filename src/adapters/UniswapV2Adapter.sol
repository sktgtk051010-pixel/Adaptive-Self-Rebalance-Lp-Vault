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
    uint256 public maxSlippageBps = 100; // 默认1%

    /// @notice V2 Router
    IUniswapV2Router02 public immutable ROUTER;

    /// @notice V2 Pair
    IUniswapV2Pair public immutable PAIR;

    /// @notice V2 Factory
    IUniswapV2Factory public immutable FACTORY;

    /// @notice 金库地址（唯一有权调用者）
    address public immutable VAULT;

    /// @notice token0
    address public immutable override TOKEN0;

    /// @notice token1
    address public immutable override TOKEN1;

    /// @notice 适配器类型
    AdapterType public constant override adapterType = AdapterType.UNISWAP_V2;

    /// @notice 唯一仓位ID（V2只有一个全区间仓位）
    bytes32 public constant POSITION_ID = keccak256("UniswapV2Adapter.POSITION");

    /// @notice dust阈值，低于此值的剩余代币视为灰尘
    uint256 public constant DUST_THRESHOLD = 1000;

    event LiquidityAdded(uint256 amount0, uint256 amount1, uint256 liquidity);
    event LiquidityRemoved(uint256 amount0, uint256 amount1, uint256 liquidity);
    event FeesCollected(uint256 fees0, uint256 fees1);

    modifier onlyVault() {
        require(msg.sender == VAULT, "V2Adapter: not vault");
        _;
    }

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

        // 获取或创建pair
        address pairAddress = FACTORY.getPair(_token0, _token1);
        if (pairAddress == address(0)) {
            pairAddress = FACTORY.createPair(_token0, _token1);
        }
        PAIR = IUniswapV2Pair(pairAddress);

        // 授权Router无限额度
        IERC20(_token0).forceApprove(_router, type(uint256).max);
        IERC20(_token1).forceApprove(_router, type(uint256).max);
        IERC20(pairAddress).forceApprove(_router, type(uint256).max);
    }

    /// @inheritdoc ILPAdapter
    function addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        bytes calldata /* data */
    ) external onlyVault nonReentrant returns (uint256 amount0, uint256 amount1, bytes32 liquidityId) {
        require(amount0Desired > 0 || amount1Desired > 0, "V2Adapter: zero amounts");

        // 从金库转入代币
        if (amount0Desired > 0) {
            IERC20(TOKEN0).safeTransferFrom(VAULT, address(this), amount0Desired);
        }
        if (amount1Desired > 0) {
            IERC20(TOKEN1).safeTransferFrom(VAULT, address(this), amount1Desired);
        }

        // 添加流动性
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

    /// @inheritdoc ILPAdapter
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
            VAULT,  // 直接转给金库
            block.timestamp + 600
        );

        emit LiquidityRemoved(amount0, amount1, liquidity);
    }

    /// @inheritdoc ILPAdapter
    /// @dev UniswapV2协议限制：手续费内嵌在LP代币价值内部，
    /// 无法在不销毁流动性的前提下单独提取手续费。
    /// 手续费将在removeLiquidity赎回流动性时随同本金一起返回Vault。
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

    /// @inheritdoc ILPAdapter
    function getTotalAssets() external view override returns (AdapterAssets memory assets) {
        return _getTotalAssets();
    }

    /// @inheritdoc ILPAdapter
    function getPositionAssets(bytes32 /* liquidityId */)
        external
        view
        override
        returns (AdapterAssets memory assets)
    {
        return _getTotalAssets();
    }

    /// @inheritdoc ILPAdapter
    function getActivePositions() external pure override returns (bytes32[] memory positions) {
        positions = new bytes32[](1);
        positions[0] = POSITION_ID;
    }

    /// @notice 获取当前LP余额
    function getLpBalance() external view override returns (uint256) {
        return PAIR.balanceOf(address(this));
    }

    /// @inheritdoc ILPAdapter
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
        // 转移剩余dust
        uint256 bal0 = IERC20(TOKEN0).balanceOf(address(this));
        uint256 bal1 = IERC20(TOKEN1).balanceOf(address(this));
        if (bal0 > 0) IERC20(TOKEN0).safeTransfer(VAULT, bal0);
        if (bal1 > 0) IERC20(TOKEN1).safeTransfer(VAULT, bal1);
    }

    function _getTotalAssets() internal view returns (AdapterAssets memory assets) {
        uint256 lpBalance = PAIR.balanceOf(address(this));
        if (lpBalance == 0) {
            assets.amount0 = IERC20(TOKEN0).balanceOf(address(this));
            assets.amount1 = IERC20(TOKEN1).balanceOf(address(this));
            return assets;
        }

        (uint112 reserve0, uint112 reserve1, ) = PAIR.getReserves();
        uint256 totalSupply = PAIR.totalSupply();

        // LP对应的资产
        assets.amount0 = FullMath.mulDiv(lpBalance, uint256(reserve0), totalSupply);
        assets.amount1 = FullMath.mulDiv(lpBalance, uint256(reserve1), totalSupply);

        // 加上合约上未投资的代币
        assets.amount0 += IERC20(TOKEN0).balanceOf(address(this));
        assets.amount1 += IERC20(TOKEN1).balanceOf(address(this));

        // V2手续费已包含在LP价值中，fees0/fees1设为0
        assets.fees0 = 0;
        assets.fees1 = 0;
    }
}
