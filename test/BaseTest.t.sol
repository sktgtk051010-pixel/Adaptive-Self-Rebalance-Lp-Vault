// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {MockWETH, MockUSDC} from "../src/tokens/MockTokens.sol";
import {TWAPOracle} from "../src/oracles/TWAPOracle.sol";
import {AdaptiveRebalanceStrategy} from "../src/strategies/AdaptiveRebalanceStrategy.sol";
import {UniswapV2Adapter} from "../src/adapters/UniswapV2Adapter.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";
import {AdaptiveLPVault} from "../src/vault/AdaptiveLPVault.sol";
import {RebalanceIncentives} from "../src/incentives/RebalanceIncentives.sol";
import {GovernanceToken, AdaptiveGovernance} from "../src/governance/AdaptiveGovernance.sol";
import {ILPAdapter} from "../src/interfaces/ILPAdapter.sol";

import {MockUniswapV2Factory, MockUniswapV2Router} from "./mocks/MockUniswapV2.sol";
import {MockUniswapV3Factory, MockUniswapV3Pool} from "./mocks/MockUniswapV3.sol";

/**
 * @title BaseTest
 * @notice 测试基类，部署所有合约并设置初始状态
 */
contract BaseTest is Test {
    MockWETH public weth;
    MockUSDC public usdc;
    MockUniswapV2Factory public v2Factory;
    MockUniswapV2Router public v2Router;
    MockUniswapV3Factory public v3Factory;
    MockUniswapV3Pool public v3PoolLowFee;   // 0.05%
    MockUniswapV3Pool public v3PoolHighFee;  // 0.30%

    TWAPOracle public oracle;
    AdaptiveRebalanceStrategy public strategy;
    UniswapV2Adapter public v2Adapter;
    UniswapV3Adapter public v3LowAdapter;
    UniswapV3Adapter public v3HighAdapter;
    AdaptiveLPVault public vault;
    RebalanceIncentives public incentives;
    GovernanceToken public govToken;
    AdaptiveGovernance public governance;

    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    uint256 public constant INITIAL_WETH = 1000 ether;
    uint256 public constant INITIAL_USDC = 2_000_000e6; // 2M USDC

    function setUp() public virtual {
        // 部署代币
        weth = new MockWETH();
        usdc = new MockUSDC();

        // 部署V2
        v2Factory = new MockUniswapV2Factory();
        v2Router = new MockUniswapV2Router(address(v2Factory), address(weth));

        // 部署V3
        v3Factory = new MockUniswapV3Factory();
        address poolLow = v3Factory.createPool(address(weth), address(usdc), 500);
        address poolHigh = v3Factory.createPool(address(weth), address(usdc), 3000);
        v3PoolLowFee = MockUniswapV3Pool(poolLow);
        v3PoolHighFee = MockUniswapV3Pool(poolHigh);

        // 确保token0/token1顺序一致
        address token0 = v3PoolHighFee.token0();
        address token1 = v3PoolHighFee.token1();

        // 部署策略和治理
        govToken = new GovernanceToken();
        governance = new AdaptiveGovernance(address(govToken));
        govToken.setMinter(address(governance));

        strategy = new AdaptiveRebalanceStrategy(address(governance));
        oracle = new TWAPOracle(address(v3PoolHighFee), address(weth), address(usdc), address(governance));

        // 部署适配器
        v2Adapter = new UniswapV2Adapter(address(v2Router), address(this), token0, token1);
        v3LowAdapter = new UniswapV3Adapter(poolLow, address(this), token0, token1, ILPAdapter.AdapterType.UNISWAP_V3_LOW_FEE);
        v3HighAdapter = new UniswapV3Adapter(poolHigh, address(this), token0, token1, ILPAdapter.AdapterType.UNISWAP_V3_HIGH_FEE);

        // 部署金库
        vault = new AdaptiveLPVault(
            address(usdc), address(weth), address(oracle), address(strategy),
            address(governance), "Adaptive LP Vault", "ALP-VAULT"
        );

        // 设置适配器的vault地址（重新部署适配器，vault地址正确）
        v2Adapter = new UniswapV2Adapter(address(v2Router), address(vault), token0, token1);
        v3LowAdapter = new UniswapV3Adapter(poolLow, address(vault), token0, token1, ILPAdapter.AdapterType.UNISWAP_V3_LOW_FEE);
        v3HighAdapter = new UniswapV3Adapter(poolHigh, address(vault), token0, token1, ILPAdapter.AdapterType.UNISWAP_V3_HIGH_FEE);

        vault.setAdapters(address(v2Adapter), address(v3LowAdapter), address(v3HighAdapter));

        // 部署激励
        incentives = new RebalanceIncentives(address(vault), address(usdc));
        vault.setIncentives(address(incentives));
        governance.setVault(address(vault));

        // 给用户mint代币
        _mintTokens(alice, INITIAL_WETH, INITIAL_USDC);
        _mintTokens(bob, INITIAL_WETH, INITIAL_USDC);
        _mintTokens(charlie, INITIAL_WETH, INITIAL_USDC);
        _mintTokens(address(this), INITIAL_WETH * 10, INITIAL_USDC * 10);

        // 给激励合约充值
        usdc.mint(address(incentives), 100_000e6);

        // 授权
        _approveAll(alice);
        _approveAll(bob);
        _approveAll(charlie);
        _approveAll(address(this));
    }

    function _mintTokens(address to, uint256 wethAmt, uint256 usdcAmt) internal {
        weth.mint(to, wethAmt);
        usdc.mint(to, usdcAmt);
    }

    function _approveAll(address user) internal {
        vm.startPrank(user);
        weth.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        weth.approve(address(v2Adapter), type(uint256).max);
        usdc.approve(address(v2Adapter), type(uint256).max);
        vm.stopPrank();
    }

    // 辅助：以alice存款
    function _deposit(address user, uint256 wethAmt, uint256 usdcAmt) internal returns (uint256 shares) {
        vm.startPrank(user);
        shares = vault.deposit(wethAmt, usdcAmt, 0);
        vm.stopPrank();
    }

    // 辅助：获取价格
    function _getCurrentPrice() internal view returns (uint160) {
        (uint160 p, ) = oracle.getTWAPPrice();
        return p;
    }

    // 辅助：WETH/USDC顺序
    function wethIsToken0() internal view returns (bool) {
        return v3PoolHighFee.token0() == address(weth);
    }
}
