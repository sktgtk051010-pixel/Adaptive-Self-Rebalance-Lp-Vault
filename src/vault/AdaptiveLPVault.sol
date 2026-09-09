// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {ITWAPOracle, IRebalanceStrategy, IGovernance} from "../interfaces/ICoreInterfaces.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3.sol";
import {IWETH} from "../interfaces/ILPAdapter.sol";
import {TickMath, FullMath, LiquidityAmounts} from "../libraries/UniswapMath.sol";
import {RebalanceIncentives} from "../incentives/RebalanceIncentives.sol";

interface IUniswapV2Adapter {
    function getLpBalance() external view returns(uint256);
    function PAIR() external view returns(address);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint256);
}

interface IUniswapV3Adapter {
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
        );
    
    function pool() external view returns (IUniswapV3Pool);
}


/**
 * @title AdaptiveLPVault
 * @notice 自适应再平衡流动性金库（ERC4626标准）
 */
contract AdaptiveLPVault is ERC4626, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ============ 常量 ============
    uint256 public constant BPS_SCALE = 10000;


    uint256 public constant WETH_DECIMALS = 18;
    uint256 public constant USDC_DECIMALS = 6;

    /// @notice WETH (18decimals) 最小操作门槛 0.000001 WETH
    uint256 public constant WETH_DUST_THRESHOLD = 1_000_000_000_000;
    /// @notice USDC (6decimals) 最小操作门槛 0.001 USDC
    uint256 public constant USDC_DUST_THRESHOLD = 1000; 

    uint256 public constant EMERGENCY_COOLDOWN = 1800;
    uint256 public constant REBALANCE_COOLDOWN = 600; 
    uint256 public constant PANIC_VOL_THRESHOLD = 5000; // 50% 波动率阈值，超过此值触发紧急模式

    uint256 public constant WAD = 1e18;

    // V3多区间投资比例
    uint256 internal constant TIGHT_RANGE_PCT = 4000;
    uint256 internal constant MEDIUM_RANGE_PCT = 3500;
    uint256 internal constant WIDE_RANGE_PCT = 2500;
    uint256 internal constant TOTAL_RANGE_PCT = 10000;

    // ============ 不可变状态 ============
    address public immutable WETH;
    ITWAPOracle public immutable ORACLE;
    IRebalanceStrategy public immutable STRATEGY;
    bool public immutable TOKEN0_IS_WETH;

    // ============ 适配器 ============
    ILPAdapter public v2Adapter;
    ILPAdapter public v3LowFeeAdapter;  // 0.05%
    ILPAdapter public v3HighFeeAdapter; // 0.30%

    // ============ 可变状态 ============
    IGovernance public governance;
    RebalanceIncentives public incentives;

    uint160 public lastRebalanceSqrtPriceX96;
    uint256 public lastRebalanceTimestamp;
    uint256 public cumulativeFeesUSDC;
    uint256 public rebalanceCount;

    uint256 public maxSlippageBps = 100; // 默认1%

    bool public paused;

    struct TargetWeights {
        uint256 v2;
        uint256 v3Low;
        uint256 v3High;
    }
    TargetWeights public currentWeights;

    // ============ 事件 ============
    event Deposited(
        address indexed user,
        uint256 wethAmount,
        uint256 usdcAmount,
        uint256 sharesMinted
    );
    event Withdrawn(
        address indexed user,
        uint256 sharesBurned,
        uint256 wethOut,
        uint256 usdcOut
    );
    event Rebalanced(
        address indexed executor,
        uint256 totalValueBefore,
        uint256 totalValueAfter,
        uint256 reward
    );
    event AdapterUpdated(address indexed adapter, uint8 adapterType);
    event WeightsUpdated(uint256 v2, uint256 v3Low, uint256 v3High);
    event PausedStateChanged(bool paused);
    event SlippageUpdated(uint256 oldBps, uint256 newBps);
    event FeesCollected(uint256 feesWETH, uint256 feesUSDC);

    // ============ 错误 ============
    error ZeroAmount();
    error InvalidAdapter();
    error PausedError();
    error SlippageExceeded();
    error NotProfitable();
    error CooldownActive();
    error InvalidWeights();

    modifier whenNotPaused() {
        if (paused) revert PausedError();
        _;
    }

    constructor(
        address _usdc,
        address _weth,
        address _oracle,
        address _strategy,
        address _governance,
        string memory name_,
        string memory symbol_
    )
        ERC4626(IERC20(_usdc))
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {
        require(_weth != address(0), "Vault: zero WETH");
        require(_usdc != address(0), "Vault: zero USDC");
        require(_oracle != address(0), "Vault: zero oracle");
        require(_strategy != address(0), "Vault: zero strategy");
        require(_governance != address(0), "Vault: zero governance");

        WETH = _weth;
        ORACLE = ITWAPOracle(_oracle);
        STRATEGY = IRebalanceStrategy(_strategy);
        governance = IGovernance(_governance);

        TOKEN0_IS_WETH = ORACLE.ORACLE_POOL().token0() == _weth;

        currentWeights = TargetWeights({v2: 2000, v3Low: 3000, v3High: 5000});
    }

    // ============ 管理函数 ============

    /**
     * @notice 设置适配器
     * @param _v2 V2适配器地址
     * @param _v3Low V3低费用适配器地址
     * @param _v3High V3高费用适配器地址
     */
    function setAdapters(
        address _v2,
        address _v3Low,
        address _v3High
    ) external onlyOwner {
        if (_v2 != address(0)) {
            v2Adapter = ILPAdapter(_v2);
            IERC20(WETH).forceApprove(_v2, type(uint256).max);
            IERC20(asset()).forceApprove(_v2, type(uint256).max);
            emit AdapterUpdated(_v2, 0);
        }
        if (_v3Low != address(0)) {
            v3LowFeeAdapter = ILPAdapter(_v3Low);
            IERC20(WETH).forceApprove(_v3Low, type(uint256).max);
            IERC20(asset()).forceApprove(_v3Low, type(uint256).max);
            emit AdapterUpdated(_v3Low, 1);
        }
        if (_v3High != address(0)) {
            v3HighFeeAdapter = ILPAdapter(_v3High);
            IERC20(WETH).forceApprove(_v3High, type(uint256).max);
            IERC20(asset()).forceApprove(_v3High, type(uint256).max);
            emit AdapterUpdated(_v3High, 2);
        }
    }

    /**
     * @notice 设置激励合约
     * @param _incentives 激励合约地址
     */
    function setIncentives(address _incentives) external onlyOwner {
        incentives = RebalanceIncentives(_incentives);
    }

    /**
     * @notice 设置治理合约
     * @param _governance 治理合约地址
     */
    function setGovernance(address _governance) external onlyOwner {
        governance = IGovernance(_governance);
    }

    /**
     * @notice 设置最大滑点保护（basis points）
     * @param _bps 最大滑点，单位bps，范围0-500（0%-5%）
     */
    function setMaxSlippage(uint256 _bps) external onlyOwner {
        require(_bps <= 500, "Vault: slippage too high"); // max 5%
        emit SlippageUpdated(maxSlippageBps, _bps);
        maxSlippageBps = _bps;
    }
    
    /**
     * @notice 暂停或恢复金库操作
     * @param _paused 是否暂停
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedStateChanged(_paused);
    }

    // ============ 存款 ============

    /**
     * @notice 双币存款：存入WETH和USDC铸造金库份额
     * @param wethAmount WETH数量
     * @param usdcAmount USDC数量
     * @param minShares 最小份额（滑点保护）
     * @return shares 铸造的份额
     */
    function deposit(
        uint256 wethAmount,
        uint256 usdcAmount,
        uint256 minShares
    ) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (wethAmount == 0 && usdcAmount == 0) revert ZeroAmount();

        uint256 totalValue = _calculateTotalValue(wethAmount, usdcAmount);
        uint256 totalAssetsBefore = totalAssets();
        uint256 totalSupply = totalSupply();

        if (totalSupply == 0) {
            shares = totalValue; 
        } else {
            shares = FullMath.mulDiv(totalValue, totalSupply, totalAssetsBefore);
        }

        if (shares < minShares) revert SlippageExceeded();

        if (wethAmount > 0) {
            IERC20(WETH).safeTransferFrom(msg.sender, address(this), wethAmount);
        }
        if (usdcAmount > 0) {
            IERC20(asset()).safeTransferFrom(msg.sender, address(this), usdcAmount);
        }

        _mint(msg.sender, shares);

        _investIdleFunds();

        emit Deposited(msg.sender, wethAmount, usdcAmount, shares);
    }

    /**
     * @notice ERC4626标准存款（仅USDC）
     * @param assets 要存入的资产数量
     * @param receiver 接收者地址
     */
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();

        shares = previewDeposit(assets);
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        _investIdleFunds();
        emit Deposited(receiver, 0, assets, shares);
    }

    /**
     * @notice ERC4626标准mint
     * @param shares 要铸造的份额
     * @param receiver 接收者地址
     */
    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        assets = previewMint(shares);
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        _investIdleFunds();
        emit Deposited(receiver, 0, assets, shares);
    }

    // ============ 取款 ============

    /**
     * @notice 赎回份额，返回WETH+USDC
     * @param shares 赎回份额
     * @param minWETH 最小WETH输出
     * @param minUSDC 最小USDC输出
     * @return wethOut WETH输出
     * @return usdcOut USDC输出
     */
    function withdrawDual(
        uint256 shares,
        uint256 minWETH,
        uint256 minUSDC
    ) external nonReentrant returns (uint256 wethOut, uint256 usdcOut) {
        if (shares == 0) revert ZeroAmount();
        require(shares <= balanceOf(msg.sender), "Vault: insufficient shares");

        uint256 totalSupply = totalSupply();
        uint256 sharePct = FullMath.mulDiv(shares, WAD, totalSupply);
        uint256 idleWethBefore = IERC20(WETH).balanceOf(address(this));
        uint256 idleUsdcBefore = IERC20(asset()).balanceOf(address(this));

        _burn(msg.sender, shares);

        _withdrawFromAdapters(sharePct);

        uint256 wethBalAfter = IERC20(WETH).balanceOf(address(this));
        uint256 usdcBalAfter = IERC20(asset()).balanceOf(address(this));

        wethOut = FullMath.mulDiv(idleWethBefore, sharePct, WAD) + (wethBalAfter - idleWethBefore);
        usdcOut = FullMath.mulDiv(idleUsdcBefore, sharePct, WAD) + (usdcBalAfter - idleUsdcBefore);

        if (wethOut < minWETH || usdcOut < minUSDC) revert SlippageExceeded();

        if (wethOut > 0) {
            IERC20(WETH).safeTransfer(msg.sender, wethOut);
        }
        if (usdcOut > 0) {
            IERC20(asset()).safeTransfer(msg.sender, usdcOut);
        }

        emit Withdrawn(msg.sender, shares, wethOut, usdcOut);
    }

    /**
     * @notice ERC4626标准取款（仅USDC）
     * @param assets 要取款的资产数量
     * @param receiver 接收者地址
     * @param owner 所有者地址
     * @return shares 赎回的份额
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 shares) {
        shares = previewWithdraw(assets);

        if(msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        uint256 sharePct = FullMath.mulDiv(shares, WAD, totalSupply());

        _burn(owner, shares);
        _withdrawFromAdapters(sharePct);

        IERC20(asset()).safeTransfer(receiver, assets);
    }

    /// @notice ERC4626标准redeem

    /**
     * @notice ERC4626标准redeem
     * @param shares 要赎回的份额
     * @param receiver 接收者地址
     * @param owner 所有者地址
     * @return assets 赎回的资产数量
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 assets) {
        assets = previewRedeem(shares);

        if(msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        uint256 sharePct = FullMath.mulDiv(shares, WAD, totalSupply());

        _burn(owner, shares);
        _withdrawFromAdapters(sharePct);

        IERC20(asset()).safeTransfer(receiver, assets);
    }

    // ============ 再平衡 ============

    /**
     * @notice 触发再平衡（任何人可调用，符合条件可获奖励）
     */
    function rebalance() external nonReentrant whenNotPaused {
        (uint160 sqrtPriceX96Twap, int24 currentTick) = ORACLE.getTWAPPrice();
        (uint160 sqrtPriceX96Spot, ) = _getSpotPrice();
        uint256 volatility = STRATEGY.estimateVolatility(sqrtPriceX96Spot, sqrtPriceX96Twap);

        if (lastRebalanceTimestamp != 0) {
            uint256 cooldownTime;
            if(volatility > PANIC_VOL_THRESHOLD) {
                cooldownTime = EMERGENCY_COOLDOWN; 
            } else {
                cooldownTime = REBALANCE_COOLDOWN;
            }
            if (block.timestamp < lastRebalanceTimestamp + cooldownTime) revert CooldownActive();
        }

        uint256 valueBefore = totalAssets();

        (IRebalanceStrategy.AllocationWeights memory alloc,
         IRebalanceStrategy.V3RangeWeights memory ranges) =
            STRATEGY.calculateAllocation(
                IERC20(WETH).balanceOf(address(this)),
                IERC20(asset()).balanceOf(address(this)),
                volatility
            );

        _collectAllFees();

        _withdrawAllFromAdapters();

        currentWeights = TargetWeights({
            v2: alloc.v2Weight,
            v3Low: alloc.v3LowFeeWeight,
            v3High: alloc.v3HighFeeWeight
        });
        emit WeightsUpdated(alloc.v2Weight, alloc.v3LowFeeWeight, alloc.v3HighFeeWeight);

        _reinvestWithRanges(currentTick, ranges);

        lastRebalanceSqrtPriceX96 = sqrtPriceX96Twap;
        lastRebalanceTimestamp = block.timestamp;
        rebalanceCount++;

        uint256 valueAfter = totalAssets();

        uint256 reward = 0;
        if (address(incentives) != address(0) && valueAfter > valueBefore) {
            try incentives.onRebalanceExecuted(msg.sender, valueBefore, valueAfter) returns (uint256 r) {
                reward = r;
            } catch {
                // 激励发放失败不影响rebalance
            }
        }

        emit Rebalanced(msg.sender, valueBefore, valueAfter, reward);
    }

    // ============ 视图函数 ============

    /// @notice ERC4626总资产（USDC计价）
    function totalAssets() public view override returns (uint256) {
        (uint256 totalWETH, uint256 totalUSDC) = getTotalUnderlying();

        // WETH按TWAP折算成USDC；oracle不可用时只返回USDC部分，避免整体revert
        try ORACLE.getTWAPPrice() returns (uint160 sqrtPriceX96Twap, int24) {
            if (sqrtPriceX96Twap == 0) return totalUSDC;
            uint256 wethValueUSDC = _wethToUSDC(totalWETH, sqrtPriceX96Twap);
            return totalUSDC + wethValueUSDC;
        } catch {
            return totalUSDC;
        }
    }

    /// @notice 获取底层WETH和USDC总量
    function getTotalUnderlying() public view returns (uint256 totalWETH, uint256 totalUSDC) {
        totalWETH = IERC20(WETH).balanceOf(address(this));
        totalUSDC = IERC20(asset()).balanceOf(address(this));

        // 各适配器资产（adapter返回amount0=token0, amount1=token1）
        if (address(v2Adapter) != address(0)) {
            ILPAdapter.AdapterAssets memory a = v2Adapter.getTotalAssets();
            (uint256 w, uint256 u) =  _decodeTokenAmounts(a.amount0 + a.fees0, a.amount1 + a.fees1);
            totalWETH += w; totalUSDC += u;
        }
        if (address(v3LowFeeAdapter) != address(0)) {
            ILPAdapter.AdapterAssets memory a = v3LowFeeAdapter.getTotalAssets();
            (uint256 w, uint256 u) =  _decodeTokenAmounts(a.amount0 + a.fees0, a.amount1 + a.fees1);
            totalWETH += w; totalUSDC += u;
        }
        if (address(v3HighFeeAdapter) != address(0)) {
            ILPAdapter.AdapterAssets memory a = v3HighFeeAdapter.getTotalAssets();
            (uint256 w, uint256 u) =  _decodeTokenAmounts(a.amount0 + a.fees0, a.amount1 + a.fees1);
            totalWETH += w; totalUSDC += u;
        }
    }

    /// @dev 将adapter的(amount0, amount1)按token0/token1顺序解析为(weth, usdc)
    function _decodeTokenAmounts(uint256 amount0, uint256 amount1) internal view returns (uint256 weth, uint256 usdc) {
        if (TOKEN0_IS_WETH) {
            return (amount0, amount1);
        } else {
            return (amount1, amount0);
        }
    }

    /// @dev 将(weth, usdc)按token0/token1顺序打包为(amount0, amount1)
    function _encodeTokenAmounts(uint256 wethAmt, uint256 usdcAmt) internal view returns (uint256 amount0, uint256 amount1) {
        if (TOKEN0_IS_WETH) {
            return (wethAmt, usdcAmt);
        } else {
            return (usdcAmt, wethAmt);
        }
    }

    /// @notice 获取各场所资金分布
    function getDistribution() external view returns (
        uint256 idleWETH, uint256 idleUSDC,
        uint256 v2WETH, uint256 v2USDC,
        uint256 v3LowWETH, uint256 v3LowUSDC,
        uint256 v3HighWETH, uint256 v3HighUSDC
    ) {
        idleWETH = IERC20(WETH).balanceOf(address(this));
        idleUSDC = IERC20(asset()).balanceOf(address(this));

        if (address(v2Adapter) != address(0)) {
            ILPAdapter.AdapterAssets memory a = v2Adapter.getTotalAssets();
            (v2WETH, v2USDC) = _decodeTokenAmounts(a.amount0, a.amount1);
        }
        if (address(v3LowFeeAdapter) != address(0)) {
            ILPAdapter.AdapterAssets memory a = v3LowFeeAdapter.getTotalAssets();
            (v3LowWETH, v3LowUSDC) = _decodeTokenAmounts(a.amount0, a.amount1);
        }
        if (address(v3HighFeeAdapter) != address(0)) {
            ILPAdapter.AdapterAssets memory a = v3HighFeeAdapter.getTotalAssets();
            (v3HighWETH, v3HighUSDC) = _decodeTokenAmounts(a.amount0, a.amount1);
        }
    }

    /**
     * @notice 转换为USDC价值
     * @param wethAmount WETH数量
     * @param usdcAmount USDC数量
     * @return totalValue 总价值（USDC计价）
     */
    function _calculateTotalValue(uint256 wethAmount, uint256 usdcAmount)
        internal
        view
        returns (uint256)
    {
        (uint160 sqrtPriceX96Twap, ) = ORACLE.getTWAPPrice();
        return usdcAmount + _wethToUSDC(wethAmount, sqrtPriceX96Twap);
    }

    /**
     * @notice 将WETH转换为USDC价值
     * @param wethAmount WETH数量
     * @param sqrtPriceX96 当前sqrtPriceX96
     * @return usdcValue USDC价值
     */
    function _wethToUSDC(uint256 wethAmount, uint160 sqrtPriceX96) internal view returns (uint256) {
        if (wethAmount == 0 || sqrtPriceX96 == 0) return 0;
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        if (TOKEN0_IS_WETH) {
            // token0=WETH, token1=USDC: price = USDC_raw/WETH_raw = sqrtPriceX96^2/2^192
            // USDC_raw = WETH_raw * price
            return FullMath.mulDiv(wethAmount, priceX96, 1 << 96);
        } else {
            // token0=USDC, token1=WETH: price = WETH_raw/USDC_raw = sqrtPriceX96^2/2^192
            // USDC_raw = WETH_raw / price = WETH_raw * 2^192 / sqrtPriceX96^2
            return FullMath.mulDiv(wethAmount, 1 << 96, priceX96);
        }
    }

    /**
     * @notice 将USDC转换为WETH数量
     * @param usdcAmount USDC数量
     * @param sqrtPriceX96 当前sqrtPriceX96
     * @return wethAmount WETH数量
     */
    function _usdcToWETH(uint256 usdcAmount, uint160 sqrtPriceX96) internal view returns (uint256) {
        if (usdcAmount == 0 || sqrtPriceX96 == 0) return 0;
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        if (TOKEN0_IS_WETH) {
            // WETH_raw = USDC_raw / price
            return FullMath.mulDiv(usdcAmount, 1 << 96, priceX96);
        } else {
            // WETH_raw = USDC_raw * price
            return FullMath.mulDiv(usdcAmount, priceX96, 1 << 96);
        }
    }

    /**
     * @notice 获取当前价格
     * @return sqrtPriceX96Spot 当前sqrtPriceX96
     * @return tick 当前tick
     */
    function _getSpotPrice() internal view returns (uint160 sqrtPriceX96Spot, int24 tick) {

        (sqrtPriceX96Spot, tick, , , , , ) = ORACLE.ORACLE_POOL().slot0();
    }

    // ============ 内部投资逻辑 ============

    /// @notice 将闲置资金投资到适配器
    function _investIdleFunds() internal {
        uint256 idleWETH = IERC20(WETH).balanceOf(address(this));
        uint256 idleUSDC = IERC20(asset()).balanceOf(address(this));
        if (idleWETH < WETH_DUST_THRESHOLD && idleUSDC < USDC_DUST_THRESHOLD) return;

        ( , int24 tick) = ORACLE.getTWAPPrice();

        _investToAdapters(idleWETH, idleUSDC, tick, currentWeights);
    }

    /**
     * @notice 投资到各适配器
     * @param totalWETH 闲置WETH数量
     * @param totalUSDC 闲置USDC数量
     * @param currentTick 当前tick
     * @param weights 目标权重
     */
    function _investToAdapters(
        uint256 totalWETH,
        uint256 totalUSDC,
        int24 currentTick,
        TargetWeights memory weights
    ) internal {
        uint256 totalWeight = weights.v2 + weights.v3Low + weights.v3High;
        if (totalWeight == 0) return;

        uint256 slippageMin = BPS_SCALE - maxSlippageBps;

        if (address(v2Adapter) != address(0) && weights.v2 > 0) {
            uint256 wethForV2 = FullMath.mulDiv(totalWETH, weights.v2, totalWeight);
            uint256 usdcForV2 = FullMath.mulDiv(totalUSDC, weights.v2, totalWeight);
            if (wethForV2 > WETH_DUST_THRESHOLD && usdcForV2 > USDC_DUST_THRESHOLD) {
                (uint256 a0, uint256 a1) = _encodeTokenAmounts(wethForV2, usdcForV2);
                // V2 实际存入量由储备比例决定，不设存入量滑点下限；滑点保护在取款侧
                v2Adapter.addLiquidity(a0, a1, 0, 0, "");
            }
        }

        if (address(v3LowFeeAdapter) != address(0) && weights.v3Low > 0) {
            uint256 wethForV3Low = FullMath.mulDiv(totalWETH, weights.v3Low, totalWeight);
            uint256 usdcForV3Low = FullMath.mulDiv(totalUSDC, weights.v3Low, totalWeight);
            _investV3MultiRange(v3LowFeeAdapter, wethForV3Low, usdcForV3Low, currentTick, slippageMin);
        }

        if (address(v3HighFeeAdapter) != address(0) && weights.v3High > 0) {
            uint256 wethForV3High = FullMath.mulDiv(totalWETH, weights.v3High, totalWeight);
            uint256 usdcForV3High = FullMath.mulDiv(totalUSDC, weights.v3High, totalWeight);
            _investV3MultiRange(v3HighFeeAdapter, wethForV3High, usdcForV3High, currentTick, slippageMin);
        }
    }

    /**
     * @notice V3多区间投资
     * @param adapter v3适配器
     * @param totalWETH 闲置WETH数量
     * @param totalUSDC 闲置USDC数量
     * @param currentTick 当前tick
     */
    function _investV3MultiRange(
        ILPAdapter adapter,
        uint256 totalWETH,
        uint256 totalUSDC,
        int24 currentTick,
        uint256 /* slippageMin */
    ) internal {
        (int24 tLower, int24 tUpper,
         int24 mLower, int24 mUpper,
         int24 wLower, int24 wUpper) = STRATEGY.getRangeTicks(currentTick);

        _investOneRange(adapter,
            FullMath.mulDiv(totalWETH, TIGHT_RANGE_PCT, TOTAL_RANGE_PCT),
            FullMath.mulDiv(totalUSDC, TIGHT_RANGE_PCT, TOTAL_RANGE_PCT),
            tLower, tUpper);
        _investOneRange(adapter,
            FullMath.mulDiv(totalWETH, MEDIUM_RANGE_PCT, TOTAL_RANGE_PCT),
            FullMath.mulDiv(totalUSDC, MEDIUM_RANGE_PCT, TOTAL_RANGE_PCT),
            mLower, mUpper);
        _investOneRange(adapter,
            FullMath.mulDiv(totalWETH, WIDE_RANGE_PCT, TOTAL_RANGE_PCT),
            FullMath.mulDiv(totalUSDC, WIDE_RANGE_PCT, TOTAL_RANGE_PCT),
            wLower, wUpper);
    }

    /**
     * @notice 带动态权重的再投资
     * @param currentTick 当前tick
     * @param ranges 目标区间权重
     */
    function _reinvestWithRanges(
        int24 currentTick,
        IRebalanceStrategy.V3RangeWeights memory ranges
    ) internal {
        uint256 idleWETH = IERC20(WETH).balanceOf(address(this));
        uint256 idleUSDC = IERC20(asset()).balanceOf(address(this));

        uint256 totalWeight = currentWeights.v2 + currentWeights.v3Low + currentWeights.v3High;
        if (totalWeight == 0) return;

        if (address(v2Adapter) != address(0) && currentWeights.v2 > 0) {
            uint256 w = FullMath.mulDiv(idleWETH, currentWeights.v2, totalWeight);
            uint256 u = FullMath.mulDiv(idleUSDC, currentWeights.v2, totalWeight);
            if (w > WETH_DUST_THRESHOLD && u > USDC_DUST_THRESHOLD) {
                (uint256 a0, uint256 a1) = _encodeTokenAmounts(w, u);
                v2Adapter.addLiquidity(a0, a1, 0, 0, "");
            }
        }

        if (address(v3LowFeeAdapter) != address(0) && currentWeights.v3Low > 0) {
            uint256 w = FullMath.mulDiv(idleWETH, currentWeights.v3Low, totalWeight);
            uint256 u = FullMath.mulDiv(idleUSDC, currentWeights.v3Low, totalWeight);
            _investV3WithRanges(v3LowFeeAdapter, w, u, currentTick, ranges);
        }

        if (address(v3HighFeeAdapter) != address(0) && currentWeights.v3High > 0) {
            uint256 w = FullMath.mulDiv(idleWETH, currentWeights.v3High, totalWeight);
            uint256 u = FullMath.mulDiv(idleUSDC, currentWeights.v3High, totalWeight);
            _investV3WithRanges(v3HighFeeAdapter, w, u, currentTick, ranges);
        }
    }

    /**
     * @notice V3多区间投资
     * @param adapter v3适配器
     * @param totalWETH 闲置WETH数量
     * @param totalUSDC 闲置USDC数量
     * @param currentTick 当前tick
     * @param ranges 目标区间权重
     */
    function _investV3WithRanges(
        ILPAdapter adapter,
        uint256 totalWETH,
        uint256 totalUSDC,
        int24 currentTick,
        IRebalanceStrategy.V3RangeWeights memory ranges
    ) internal {
        (int24 tLower, int24 tUpper,
         int24 mLower, int24 mUpper,
         int24 wLower, int24 wUpper) = STRATEGY.getRangeTicks(currentTick);

        uint256 totalRange = ranges.tightWeight + ranges.mediumWeight + ranges.wideWeight;
        if (totalRange == 0) return;

        _investOneRange(adapter,
            FullMath.mulDiv(totalWETH, ranges.tightWeight, totalRange),
            FullMath.mulDiv(totalUSDC, ranges.tightWeight, totalRange),
            tLower, tUpper);
        _investOneRange(adapter,
            FullMath.mulDiv(totalWETH, ranges.mediumWeight, totalRange),
            FullMath.mulDiv(totalUSDC, ranges.mediumWeight, totalRange),
            mLower, mUpper);
        _investOneRange(adapter,
            FullMath.mulDiv(totalWETH, ranges.wideWeight, totalRange),
            FullMath.mulDiv(totalUSDC, ranges.wideWeight, totalRange),
            wLower, wUpper);
    }

    /**
     * @notice 投资到单个V3区间
     * @param adapter v3适配器
     * @param wethAmt WETH数量
     * @param usdcAmt USDC数量
     * @param tickL 下界tick
     * @param tickU 上界tick
     */
    function _investOneRange(
        ILPAdapter adapter,
        uint256 wethAmt,
        uint256 usdcAmt,
        int24 tickL,
        int24 tickU
    ) internal {
        if (wethAmt > WETH_DUST_THRESHOLD || usdcAmt > USDC_DUST_THRESHOLD) {
            (uint256 a0, uint256 a1) = _encodeTokenAmounts(wethAmt, usdcAmt);
            adapter.addLiquidity(a0, a1, 0, 0, abi.encode(tickL, tickU));
        }
    }

    /**
     * @notice 从所有适配器撤出全部流动性
     */
    function _withdrawAllFromAdapters() internal {
        if (address(v2Adapter) != address(0)) {
            v2Adapter.withdrawAll();
        }
        if (address(v3LowFeeAdapter) != address(0)) {
            v3LowFeeAdapter.withdrawAll();
        }
        if (address(v3HighFeeAdapter) != address(0)) {
            v3HighFeeAdapter.withdrawAll();
        }
    }

    /**
     * @notice 按比例从V2适配器撤出
     * @param sharePct 撤出比例
     */
    function _withdrawFromAdapters(uint256 sharePct) internal {
        // V2
        if (address(v2Adapter) != address(0)) {
            uint256 slippageMin = BPS_SCALE - maxSlippageBps;
            uint256 lpBalance = IUniswapV2Adapter(address(v2Adapter)).getLpBalance();
            uint256 lpToWithdraw = FullMath.mulDiv(lpBalance, sharePct, WAD);
            if (lpToWithdraw > 0) {
                address pair = IUniswapV2Adapter(address(v2Adapter)).PAIR();
                IUniswapV2Pair pairContract = IUniswapV2Pair(pair);
                (uint112 reserve0, uint112 reserve1, ) = pairContract.getReserves();
                uint256 totalSupply = pairContract.totalSupply();
                uint256 amount0Est = FullMath.mulDiv(reserve0, lpToWithdraw, totalSupply);
                uint256 amount1Est = FullMath.mulDiv(reserve1, lpToWithdraw, totalSupply);
                uint256 amount0Min = FullMath.mulDiv(amount0Est, slippageMin, BPS_SCALE);
                uint256 amount1Min = FullMath.mulDiv(amount1Est, slippageMin, BPS_SCALE);

                v2Adapter.removeLiquidity (bytes32(0), uint128 (lpToWithdraw), amount0Min, amount1Min);
            }
        }
        // V3
        if (address(v3LowFeeAdapter) != address(0)) {
            _withdrawPctFromV3(v3LowFeeAdapter, sharePct);
        }
        if (address(v3HighFeeAdapter) != address(0)) {
            _withdrawPctFromV3(v3HighFeeAdapter, sharePct);
        }
    }

    /**
     * @notice 按比例从V3适配器撤出
     * @param adapter v3适配器
     * @param sharePct 撤出比例
     */
    function _withdrawPctFromV3(ILPAdapter adapter, uint256 sharePct) internal {
        bytes32[] memory positions = adapter.getActivePositions();
        uint256 slippageMin = BPS_SCALE - maxSlippageBps;
        IUniswapV3Adapter adapterV3 = IUniswapV3Adapter(address(adapter));
        
        for(uint256 i = 0; i < positions.length; i++) {
            _withdrawFromV3Position(adapter, adapterV3, positions[i], sharePct, slippageMin);
        }
    }

    /**
     * @notice 从V3单个仓位按比例撤出
     * @param adapter v3适配器
     * @param adapterV3 v3适配器接口
     * @param key 仓位键
     * @param sharePct 撤出比例
     * @param slippageMin 滑点下限
     */
    function _withdrawFromV3Position(
        ILPAdapter adapter,
        IUniswapV3Adapter adapterV3,
        bytes32 key,
        uint256 sharePct,
        uint256 slippageMin
    ) internal {
        (int24 tickLower, int24 tickUpper, uint128 liquidity, , , , , bool active) = adapterV3.getPositionInfo(key);

        if(!active || liquidity == 0) {
            return;
        }

        uint256 lpToWithdraw = FullMath.mulDiv(liquidity, sharePct, WAD);
        if (lpToWithdraw == 0) return;

        (uint160 sqrtPricex96, , , , , , ) = adapterV3.pool().slot0();
        (uint256 amount0Est, uint256 amount1Est) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPricex96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            uint128(lpToWithdraw)
        );
        
        adapter.removeLiquidity(
            key, 
            uint128(lpToWithdraw), 
            FullMath.mulDiv(amount0Est, slippageMin, BPS_SCALE), 
            FullMath.mulDiv(amount1Est, slippageMin, BPS_SCALE)
        );
    }

    /**
     * @notice 收集所有适配器手续费
     */
    function _collectAllFees() internal {
        uint256 totalFeesWeth;
        uint256 totalFeesUsdc;

        if (address(v3LowFeeAdapter) != address(0)) {
            bytes32[] memory positions = v3LowFeeAdapter.getActivePositions();
            for (uint256 i = 0; i < positions.length; i++) {
                (uint256 f0, uint256 f1) = v3LowFeeAdapter.collectFees(positions[i]);
                (uint256 w, uint256 u) = _decodeTokenAmounts(f0, f1);
                totalFeesWeth += w; totalFeesUsdc += u;
            }
        }

        if (address(v3HighFeeAdapter) != address(0)) {
            bytes32[] memory positions = v3HighFeeAdapter.getActivePositions();
            for (uint256 i = 0; i < positions.length; i++) {
                (uint256 f0, uint256 f1) = v3HighFeeAdapter.collectFees(positions[i]);
                (uint256 w, uint256 u) = _decodeTokenAmounts(f0, f1);
                totalFeesWeth += w; totalFeesUsdc += u;
            }
        }

        if (totalFeesWeth > 0 || totalFeesUsdc > 0) {
            (uint160 sqrtPriceX96Twap, ) = ORACLE.getTWAPPrice();
            cumulativeFeesUSDC += totalFeesUsdc + _wethToUSDC(totalFeesWeth, sqrtPriceX96Twap);
            emit FeesCollected(totalFeesWeth, totalFeesUsdc);
        }
    }

    // ============ ERC4626覆盖 ============

    /**
     * @notice 将资产数量转换为份额数量
     * @param assets 资产数量
     * @param rounding 四舍五入方式
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding)
        internal
        view
        override
        returns (uint256)
    {
        uint256 supply = totalSupply();
        uint256 totalAssetsValue = totalAssets();
        if (supply == 0 || totalAssetsValue == 0) return assets;
        return assets.mulDiv(supply, totalAssetsValue, rounding);
    }

    /**
     * @notice 将份额数量转换为资产数量
     * @param shares 份额数量
     * @param rounding 四舍五入方式
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding)
        internal
        view
        override
        returns (uint256)
    {
        uint256 supply = totalSupply();
        uint256 totalAssetsValue = totalAssets();
        if (supply == 0 || totalAssetsValue == 0) return shares;
        return shares.mulDiv(totalAssetsValue, supply, rounding);
    }
}
