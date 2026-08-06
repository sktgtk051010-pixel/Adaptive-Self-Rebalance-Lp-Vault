// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ILPAdapter
 * @notice 流动性场所适配器统一接口，金库通过此接口与V2/V3交互
 */
interface ILPAdapter {
    /// @notice 适配器类型
    enum AdapterType {
        UNISWAP_V2,
        UNISWAP_V3_LOW_FEE,   // 0.05%
        UNISWAP_V3_HIGH_FEE   // 0.30%
    }

    /// @notice 适配器总资产信息
    struct AdapterAssets {
        uint256 amount0;     // token0 (WETH) 数量
        uint256 amount1;     // token1 (USDC) 数量
        uint256 fees0;       // 待领取手续费 token0
        uint256 fees1;       // 待领取手续费 token1
    }

    /// @notice 返回适配器类型
    function adapterType() external view returns (AdapterType);

    /// @notice 返回token0地址
    function TOKEN0() external view returns (address);

    /// @notice 返回token1地址
    function TOKEN1() external view returns (address);

    /// @notice 添加流动性
    /// @param amount0Desired 期望的token0数量
    /// @param amount1Desired 期望的token1数量
    /// @param amount0Min 最小token0数量（滑点保护）
    /// @param amount1Min 最小token1数量（滑点保护）
    /// @param data 额外参数（V3需要tickLower/tickUpper等）
    /// @return amount0 实际使用的token0
    /// @return amount1 实际使用的token1
    /// @return liquidityId 流动性标识（V2为0，V3为tokenId或position key hash）
    function addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1, bytes32 liquidityId);

    /// @notice 移除流动性
    /// @param liquidityId 流动性标识
    /// @param liquidity 移除的流动性数量（V2为LP数量，V3为liquidity）
    /// @param amount0Min 最小token0数量
    /// @param amount1Min 最小token1数量
    /// @return amount0 取回的token0
    /// @return amount1 取回的token1
    function removeLiquidity(
        bytes32 liquidityId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice 领取手续费
    /// @param liquidityId 流动性标识
    /// @return fees0 领取的token0手续费
    /// @return fees1 领取的token1手续费
    function collectFees(bytes32 liquidityId) external returns (uint256 fees0, uint256 fees1);

    function getLpBalance() external view returns (uint256);

    /// @notice 查询适配器总资产（含未领取手续费）
    function getTotalAssets() external view returns (AdapterAssets memory assets);

    /// @notice 查询某个仓位的资产
    function getPositionAssets(bytes32 liquidityId)
        external
        view
        returns (AdapterAssets memory assets);

    /// @notice 返回所有活跃仓位ID
    function getActivePositions() external view returns (bytes32[] memory);

    /// @notice 撤出所有流动性并转给vault
    function withdrawAll() external;
}

/**
 * @title IWETH
 * @notice Wrapped ETH 接口
 */
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function approve(address guy, uint256 wad) external returns (bool);
    function transfer(address dst, uint256 wad) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}
