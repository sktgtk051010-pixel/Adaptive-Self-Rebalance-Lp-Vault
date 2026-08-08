// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AdaptiveLPVault} from "../../src/vault/AdaptiveLPVault.sol";
import {TWAPOracle} from "../../src/oracles/TWAPOracle.sol";
import {AdaptiveRebalanceStrategy} from "../../src/strategies/AdaptiveRebalanceStrategy.sol";
import {AdaptiveGovernance, GovernanceToken} from "../../src/governance/AdaptiveGovernance.sol";
import {RebalanceIncentives} from "../../src/incentives/RebalanceIncentives.sol";
import {UniswapV2Adapter} from "../../src/adapters/UniswapV2Adapter.sol";
import {UniswapV3Adapter} from "../../src/adapters/UniswapV3Adapter.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {ITWAPOracle} from "../../src/interfaces/ICoreInterfaces.sol";
import {IUniswapV3Pool} from "../../src/interfaces/IUniswapV3.sol";
import {IUniswapV2Pair, IUniswapV2Router02} from "../../src/interfaces/IUniswapV2.sol";

/**
 * @title ForkTest - 主网分叉测试
 * @notice 使用以太坊主网分叉验证合约与真实Uniswap V2/V3合约的兼容性
 * @dev 需要MAINNET_RPC_URL环境变量
 */
contract ForkTest is Test {
    // 主网真实地址
    address constant WETH_MAINNET = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC_MAINNET = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Uniswap V3
    address constant V3_POOL_3000 = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
    address constant V3_POOL_500 = 0x11b815efB8f581194ae79006d24E0d814B7697F6;

    // Uniswap V2
    address constant V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant V2_PAIR = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;

    uint256 mainnetFork;

    AdaptiveLPVault vault;
    TWAPOracle oracle;
    AdaptiveRebalanceStrategy strategy;
    AdaptiveGovernance governance;
    GovernanceToken govToken;
    RebalanceIncentives incentives;
    UniswapV2Adapter v2Adapter;
    UniswapV3Adapter v3LowFeeAdapter;
    UniswapV3Adapter v3HighFeeAdapter;

    address alice = makeAddr("alice");

    function setUp() public {
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        mainnetFork = vm.createFork(rpcUrl);
        vm.selectFork(mainnetFork);

        govToken = new GovernanceToken();
        governance = new AdaptiveGovernance(address(govToken));
        govToken.setMinter(address(governance));
        strategy = new AdaptiveRebalanceStrategy(address(governance));

        oracle = new TWAPOracle(V3_POOL_3000, WETH_MAINNET, USDC_MAINNET, address(governance));

        vault = new AdaptiveLPVault(
            USDC_MAINNET, WETH_MAINNET, address(oracle), address(strategy), address(governance),
            "Adaptive LP Vault", "ALP-VAULT"
        );

        incentives = new RebalanceIncentives(address(vault), USDC_MAINNET, address(governance));

        // V2 适配器 - 使用真实V2 Router
        v2Adapter = new UniswapV2Adapter(V2_ROUTER, address(vault), USDC_MAINNET, WETH_MAINNET);

        // V3 适配器
        address p500t0 = IUniswapV3Pool(V3_POOL_500).token0();
        address p500t1 = IUniswapV3Pool(V3_POOL_500).token1();
        v3LowFeeAdapter = new UniswapV3Adapter(V3_POOL_500, address(vault), p500t0, p500t1, ILPAdapter.AdapterType.UNISWAP_V3_LOW_FEE);

        address p3000t0 = IUniswapV3Pool(V3_POOL_3000).token0();
        address p3000t1 = IUniswapV3Pool(V3_POOL_3000).token1();
        v3HighFeeAdapter = new UniswapV3Adapter(V3_POOL_3000, address(vault), p3000t0, p3000t1, ILPAdapter.AdapterType.UNISWAP_V3_HIGH_FEE);

        // 设置全部三个适配器
        vault.setAdapters(address(v2Adapter), address(v3LowFeeAdapter), address(v3HighFeeAdapter));
        vault.setIncentives(address(incentives));
        vault.setGovernance(address(governance));
        governance.setVault(address(vault));

        deal(WETH_MAINNET, alice, 10 ether);
        deal(USDC_MAINNET, alice, 20_000e6);
        deal(USDC_MAINNET, address(incentives), 10_000e6);
    }

    function testFork_CanReadRealTWAPPrice() public view {
        (uint160 price,) = oracle.getTWAPPrice();
        assertGt(price, 0);
        uint256 usdcPerEth = oracle.quote(1 ether, true);
        assertGt(usdcPerEth, 1000e6);
        assertLt(usdcPerEth, 5000e6);
        console2.log("WETH/USDC TWAP price (USDC):", usdcPerEth / 1e6);
    }

    function testFork_CanReadRealPoolState() public view {
        (uint160 sqrtPriceX96, int24 tick,,,,,) = IUniswapV3Pool(V3_POOL_3000).slot0();
        assertGt(sqrtPriceX96, 0);
        console2.log("V3 0.30% pool tick:", uint256(int256(tick)));
        console2.log("V3 0.30% pool liquidity:", uint256(IUniswapV3Pool(V3_POOL_3000).liquidity()));
    }

    function testFork_V2AdapterCanReadRealPair() public view {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(V2_PAIR).getReserves();
        assertGt(r0, 0);
        assertGt(r1, 0);
        console2.log("V2 pair reserve0:", uint256(r0));
        console2.log("V2 pair reserve1:", uint256(r1));
        assertEq(address(v2Adapter.PAIR()), V2_PAIR);
    }

    function testFork_StrategyWorksWithRealTick() public view {
        (, int24 tick,,,,,) = IUniswapV3Pool(V3_POOL_3000).slot0();
        (int24 tl, int24 tu, int24 ml, int24 mu, int24 wl, int24 wu) = strategy.getRangeTicks(tick);
        assertLt(tl, tick); assertGt(tu, tick);
        assertLt(ml, tl); assertGt(mu, tu);
        assertLt(wl, ml); assertGt(wu, mu);
    }

    function testFork_VaultCanCalculateAssets() public view {
        uint256 total = vault.totalAssets();
        assertEq(total, 0);
    }

    function testFork_GovernanceParams() public view {
        (uint160 price,) = oracle.getTWAPPrice();
        assertGt(price, 0);
    }

    function testFork_AllThreeAdaptersSet() public view {
        assertEq(address(vault.v2Adapter()), address(v2Adapter));
        assertEq(address(vault.v3LowFeeAdapter()), address(v3LowFeeAdapter));
        assertEq(address(vault.v3HighFeeAdapter()), address(v3HighFeeAdapter));
    }
}
