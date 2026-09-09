// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IUniswapV2Pair
 * @notice Uniswap V2 Pair 最小接口
 */
interface IUniswapV2Pair {
    /**
     * @notice 获取token0地址
     * @return token0地址
     */
    function token0() external view returns (address);

    /**
     * @notice 获取token1地址
     * @return token1地址
     */
    function token1() external view returns (address);

    /**
     * @notice 获取储备量
     * @return reserve0 token0储备量
     * @return reserve1 token1储备量
     * @return blockTimestampLast 最后更新时间戳
     */
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    /**
     * @notice 获取token0累计价格
     * @return token0累计价格
     */
    function price0CumulativeLast() external view returns (uint256);

    /**
     * @notice 获取token1累计价格
     * @return token1累计价格
     */
    function price1CumulativeLast() external view returns (uint256);

    /**
     * @notice 获取总供应量
     * @return 总供应量
     */
    function totalSupply() external view returns (uint256);

    /**
     * @notice 查询余额
     * @param owner 地址
     * @return 余额
     */
    function balanceOf(address owner) external view returns (uint256);

    /**
     * @notice Mint LP代币
     * @param to 接收地址
     * @return liquidity Mint的LP数量
     */
    function mint(address to) external returns (uint256 liquidity);

    /**
     * @notice Burn LP代币，赎回底层资产
     * @param to 接收地址
     * @return amount0 赎回的token0数量
     * @return amount1 赎回的token1数量
     */
    function burn(address to) external returns (uint256 amount0, uint256 amount1);

    /**
     * @notice 兑换
     * @param amount0Out 输出token0数量
     * @param amount1Out 输出token1数量
     * @param to 接收地址
     * @param data 回调数据
     */
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;

    /**
     * @notice 同步储备量
     */
    function sync() external;
}

/**
 * @title IUniswapV2Factory
 * @notice Uniswap V2 Factory 最小接口
 */
interface IUniswapV2Factory {
    /**
     * @notice 获取交易对地址
     * @param tokenA tokenA地址
     * @param tokenB tokenB地址
     * @return pair 交易对地址
     */
    function getPair(address tokenA, address tokenB) external view returns (address pair);

    /**
     * @notice 根据索引获取交易对
     * @param 索引
     * @return pair 交易对地址
     */
    function allPairs(uint256) external view returns (address pair);

    /**
     * @notice 获取交易对总数
     * @return 交易对总数
     */
    function allPairsLength() external view returns (uint256);

    /**
     * @notice 创建交易对
     * @param tokenA tokenA地址
     * @param tokenB tokenB地址
     * @return pair 交易对地址
     */
    function createPair(address tokenA, address tokenB) external returns (address pair);

    /**
     * @notice 获取手续费接收地址
     * @return 手续费接收地址
     */
    function feeTo() external view returns (address);
}

/**
 * @title IUniswapV2Router02
 * @notice Uniswap V2 Router 最小接口
 */
interface IUniswapV2Router02 {
    /**
     * @notice 获取Factory地址
     * @return Factory地址
     */
    function factory() external pure returns (address);

    /**
     * @notice 获取WETH地址
     * @return WETH地址
     */
    function WETH() external pure returns (address);

    /**
     * @notice 添加流动性
     * @param tokenA tokenA地址
     * @param tokenB tokenB地址
     * @param amountADesired 期望存入tokenA数量
     * @param amountBDesired 期望存入tokenB数量
     * @param amountAMin 最小tokenA数量
     * @param amountBMin 最小tokenB数量
     * @param to 接收LP地址
     * @param deadline 交易截止时间
     * @return amountA 实际存入tokenA数量
     * @return amountB 实际存入tokenB数量
     * @return liquidity Mint的LP数量
     */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    /**
     * @notice 移除流动性
     * @param tokenA tokenA地址
     * @param tokenB tokenB地址
     * @param liquidity 移除的LP数量
     * @param amountAMin 最小tokenA数量
     * @param amountBMin 最小tokenB数量
     * @param to 接收资产地址
     * @param deadline 交易截止时间
     * @return amountA 赎回的tokenA数量
     * @return amountB 赎回的tokenB数量
     */
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    /**
     * @notice 精确输入兑换
     * @param amountIn 输入数量
     * @param amountOutMin 最小输出数量
     * @param path 兑换路径
     * @param to 接收地址
     * @param deadline 交易截止时间
     * @return amounts 各环节输出数量
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /**
     * @notice 获取输出数量
     * @param amountIn 输入数量
     * @param path 兑换路径
     * @return amounts 各环节输出数量
     */
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    /**
     * @notice 报价
     * @param amountA 输入数量A
     * @param reserveA 储备量A
     * @param reserveB 储备量B
     * @return amountB 输出数量B
     */
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB)
        external
        pure
        returns (uint256 amountB);
}
