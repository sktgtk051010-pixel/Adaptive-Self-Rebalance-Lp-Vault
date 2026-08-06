// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniswapV3Pool} from "../interfaces/IUniswapV3.sol";
import {ITWAPOracle} from "../interfaces/ICoreInterfaces.sol";
import {TickMath, FullMath} from "../libraries/UniswapMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TWAPOracle
 * @notice 基于Uniswap V3的时间加权平均价格预言机
 * @dev 读取V3池的observe()获取TWAP，防止瞬时价格操纵
 */
contract TWAPOracle is ITWAPOracle, Ownable {
    /// @notice V3预言机池（使用0.30%费率池，流动性最深）
    IUniswapV3Pool public immutable ORACLE_POOL;

    /// @notice WETH地址
    address public immutable override WETH;

    /// @notice USDC地址
    address public immutable override USDC;

    /// @notice 治理合约地址（可更新TWAP窗口）
    address public governance;

    /// @notice TWAP采样窗口（秒）
    uint32 public override twapWindow;

    /// @notice 默认TWAP窗口：30分钟
    uint32 public constant DEFAULT_TWAP_WINDOW = 1800;

    /// @notice 最小TWAP窗口：5分钟
    uint32 public constant MIN_TWAP_WINDOW = 300;

    /// @notice 最大TWAP窗口：24小时
    uint32 public constant MAX_TWAP_WINDOW = 86400;

    event TWAPWindowUpdated(uint32 oldWindow, uint32 newWindow);
    event GovernanceUpdated(address oldGovernance, address newGovernance);

    modifier onlyGovernance() {
        require(msg.sender == governance || msg.sender == owner(), "TWAPOracle: not authorized");
        _;
    }

    constructor(
        address _oraclePool,
        address _weth,
        address _usdc,
        address _governance
    ) Ownable(msg.sender) {
        require(_oraclePool != address(0), "TWAPOracle: zero pool");
        require(_weth != address(0), "TWAPOracle: zero WETH");
        require(_usdc != address(0), "TWAPOracle: zero USDC");

        ORACLE_POOL = IUniswapV3Pool(_oraclePool);
        WETH = _weth;
        USDC = _usdc;
        governance = _governance;
        twapWindow = DEFAULT_TWAP_WINDOW;

        // 验证池的token匹配
        address token0 = IUniswapV3Pool(_oraclePool).token0();
        address token1 = IUniswapV3Pool(_oraclePool).token1();
        require(
            (token0 == _weth && token1 == _usdc) || (token0 == _usdc && token1 == _weth),
            "TWAPOracle: pool tokens mismatch"
        );
    }

    /// @notice 获取TWAP价格和当前tick
    /// @return sqrtPriceX96Twap 时间加权均价 (sqrt(price) * 2^96)
    /// @return tick 算术平均tick
    function getTWAPPrice() public view override returns (uint160 sqrtPriceX96Twap, int24 tick) {
        uint32 window = twapWindow;
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;

        // observe返回tickCumulatives
        (int56[] memory tickCumulatives, ) = ORACLE_POOL.observe(secondsAgos);

        // 计算时间加权平均tick
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 arithmeticMeanTick = int24(tickCumulativesDelta / int56(uint56(window)));

        // 向下取整处理负数
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(uint56(window)) != 0)) {
            arithmeticMeanTick--;
        }

        tick = arithmeticMeanTick;
        sqrtPriceX96Twap = TickMath.getSqrtRatioAtTick(arithmeticMeanTick);
    }

    /// @notice 获取当前即时价格（非TWAP，仅用于参考）
    function getCurrentPrice() external view returns (uint160 sqrtPriceX96Spot, int24 tick) {
        (sqrtPriceX96Spot, tick, , , , , ) = ORACLE_POOL.slot0();
    }

    /// @notice 按TWAP价格换算代币数量
    /// @param amount 输入数量
    /// @param isWETHToUSDC true=WETH->USDC, false=USDC->WETH
    function quote(uint256 amount, bool isWETHToUSDC)
        external
        view
        override
        returns (uint256)
    {
        (uint160 sqrtPriceX96Twap, ) = getTWAPPrice();

        // 确定token0/token1顺序
        bool wethIsToken0 = ORACLE_POOL.token0() == WETH;

        // sqrtPriceX96 = sqrt(price) * 2^96
        // price = (sqrtPriceX96 / 2^96)^2 = sqrtPriceX96^2 / 2^192
        // price 表示 token1/token0 的比率（以最小单位计）
        // 注意：price已经包含了精度差，不需要额外乘除1e12

        uint256 priceSquared = uint256(sqrtPriceX96Twap) * uint256(sqrtPriceX96Twap);

        if (isWETHToUSDC) {
            if (wethIsToken0) {
                // token0=WETH, token1=USDC
                // price = USDC_raw / WETH_raw
                // USDC_raw = WETH_raw * price
                return FullMath.mulDiv(amount, priceSquared, 2 ** 192);
            } else {
                // token0=USDC, token1=WETH
                // price = WETH_raw / USDC_raw
                // USDC_raw = WETH_raw / price
                return FullMath.mulDiv(amount, 2 ** 192, priceSquared);
            }
        } else {
            if (wethIsToken0) {
                // token0=WETH, token1=USDC
                // WETH_raw = USDC_raw / price
                return FullMath.mulDiv(amount, 2 ** 192, priceSquared);
            } else {
                // token0=USDC, token1=WETH
                // WETH_raw = USDC_raw * price
                return FullMath.mulDiv(amount, priceSquared, 2 ** 192);
            }
        }
    }

    /// @notice 更新TWAP窗口（仅治理）
    function setTWAPWindow(uint32 _window) external onlyGovernance {
        require(_window >= MIN_TWAP_WINDOW && _window <= MAX_TWAP_WINDOW, "TWAPOracle: invalid window");
        emit TWAPWindowUpdated(twapWindow, _window);
        twapWindow = _window;
    }

    /// @notice 更新治理合约地址
    function setGovernance(address _governance) external onlyOwner {
        emit GovernanceUpdated(governance, _governance);
        governance = _governance;
    }

    /// @notice 确保V3池有足够的观察基数
    function ensureObservationCardinality(uint16 cardinalityNext) external {
        ORACLE_POOL.increaseObservationCardinalityNext(cardinalityNext);
    }
}
