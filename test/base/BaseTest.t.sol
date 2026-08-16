// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {MockWETH, MockUSDC} from "../../src/tokens/MockTokens.sol";
import {TWAPOracle} from "../../src/oracles/TWAPOracle.sol";
import {AdaptiveRebalanceStrategy} from "../../src/strategies/AdaptiveRebalanceStrategy.sol";
import {UniswapV2Adapter} from "../../src/adapters/UniswapV2Adapter.sol";
import {UniswapV3Adapter} from "../../src/adapters/UniswapV3Adapter.sol";
import {AdaptiveLPVault} from "../../src/vault/AdaptiveLPVault.sol";
import {RebalanceIncentives} from "../../src/incentives/RebalanceIncentives.sol";
import {GovernanceToken, AdaptiveGovernance} from "../../src/governance/AdaptiveGovernance.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";

import {MockUniswapV2Factory, MockUniswapV2Router} from "../mocks/MockUniswapV2.sol";
import {MockUniswapV3Factory, MockUniswapV3Pool} from "../mocks/MockUniswapV3.sol";

/**
 * @title BaseTest
 * @notice 测试基类：部署所有合约，提供通用辅助函数
 * @dev 修复：适配器只部署一次（vault地址正确后），不重复部署
 */
contract BaseTest is Test {
    MockWETH public weth;
    MockUSDC public usdc;
    MockUniswapV2Factory public v2Factory;
    MockUniswapV2Router public v2Router;
    MockUniswapV3Factory public v3Factory;
    MockUniswapV3Pool public v3PoolLowFee;
    MockUniswapV3Pool public v3PoolHighFee;

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
    uint256 public constant INITIAL_USDC = 2_000_000e6;

    function setUp() public virtual {
        _deployTokens();
        _deployUniswapMocks();
        _deployGovernance();
        _deployVaultAndStrategy();
        _deployAdapters();
        _deployIncentives();
        _setupUsersAndSkip();
    }

    function _deployTokens() internal {
        weth = new MockWETH();
        usdc = new MockUSDC();
    }

    function _deployUniswapMocks() internal {
        v2Factory = new MockUniswapV2Factory();
        v2Router = new MockUniswapV2Router(address(v2Factory), address(weth));

        v3Factory = new MockUniswapV3Factory();
        v3PoolLowFee = MockUniswapV3Pool(v3Factory.createPool(address(weth), address(usdc), 500));
        v3PoolHighFee = MockUniswapV3Pool(v3Factory.createPool(address(weth), address(usdc), 3000));
    }

    function _deployGovernance() internal {
        govToken = new GovernanceToken();
        governance = new AdaptiveGovernance(address(govToken));
        govToken.setMinter(address(this));
    }

    function _deployVaultAndStrategy() internal {
        strategy = new AdaptiveRebalanceStrategy(address(governance));
        oracle = new TWAPOracle(address(v3PoolHighFee), address(weth), address(usdc), address(governance));

        vault = new AdaptiveLPVault(
            address(usdc),
            address(weth),
            address(oracle),
            address(strategy),
            address(governance),
            "Adaptive LP Vault",
            "ALP"
        );
    }

    function _deployAdapters() internal {
        v2Adapter =
            new UniswapV2Adapter(address(v2Router), address(vault), v3PoolHighFee.token0(), v3PoolHighFee.token1());

        v3LowAdapter = new UniswapV3Adapter(
            address(v3PoolLowFee),
            address(vault),
            v3PoolHighFee.token0(),
            v3PoolHighFee.token1(),
            ILPAdapter.AdapterType.UNISWAP_V3_LOW_FEE
        );

        v3HighAdapter = new UniswapV3Adapter(
            address(v3PoolHighFee),
            address(vault),
            v3PoolHighFee.token0(),
            v3PoolHighFee.token1(),
            ILPAdapter.AdapterType.UNISWAP_V3_HIGH_FEE
        );

        vault.setAdapters(address(v2Adapter), address(v3LowAdapter), address(v3HighAdapter));
    }

    function _deployIncentives() internal {
        incentives = new RebalanceIncentives(address(vault), address(usdc), address(governance));
        vault.setIncentives(address(incentives));
        governance.setVault(address(vault));
    }

    function _setupUsersAndSkip() internal {
        _mintTokens(alice, INITIAL_WETH, INITIAL_USDC);
        _mintTokens(bob, INITIAL_WETH, INITIAL_USDC);
        _mintTokens(charlie, INITIAL_WETH, INITIAL_USDC);
        _mintTokens(address(this), INITIAL_WETH * 10, INITIAL_USDC * 10);

        usdc.mint(address(incentives), 100_000e6);

        _approveAll(alice);
        _approveAll(bob);
        _approveAll(charlie);
        _approveAll(address(this));

        skip(1801);
    }

    // ============ 辅助函数 ============

    function _mintTokens(address to, uint256 wethAmt, uint256 usdcAmt) internal {
        weth.mint(to, wethAmt);
        usdc.mint(to, usdcAmt);
    }

    function _approveAll(address user) internal {
        vm.startPrank(user);
        weth.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice 以user身份双币存款
    function _deposit(address user, uint256 wethAmt, uint256 usdcAmt) internal returns (uint256 shares) {
        vm.startPrank(user);
        shares = vault.deposit(wethAmt, usdcAmt, 0);
        vm.stopPrank();
    }

    /// @notice 统一设置两个V3池价格
    function _setPrice(uint256 priceUsdcPerEth) internal {
        v3PoolHighFee.setPrice(priceUsdcPerEth);
        v3PoolLowFee.setPrice(priceUsdcPerEth);
    }

    /// @notice 快进时间并再平衡
    function _rebalance() internal {
        skip(700);
        vault.rebalance();
    }

    /// @notice 获取金库总WETH和USDC（避免8返回值占栈）
    function _getTotalUnderlying() internal view returns (uint256 totalWeth, uint256 totalUsdc) {
        (
            uint256 idleW,
            uint256 idleU,
            uint256 v2W,
            uint256 v2U,
            uint256 v3LW,
            uint256 v3LU,
            uint256 v3HW,
            uint256 v3HU
        ) = vault.getDistribution();
        totalWeth = idleW + v2W + v3LW + v3HW;
        totalUsdc = idleU + v2U + v3LU + v3HU;
    }

    /// @notice 获取各场所WETH分布（避免栈深）
    function _getWethDistribution() internal view returns (uint256 idle, uint256 v2, uint256 v3Low, uint256 v3High) {
        (uint256 idleW,, uint256 v2W,, uint256 v3LW,, uint256 v3HW,) = vault.getDistribution();
        return (idleW, v2W, v3LW, v3HW);
    }

    /// @notice 获取各场所USDC分布（避免栈深）
    function _getUsdcDistribution() internal view returns (uint256 idle, uint256 v2, uint256 v3Low, uint256 v3High) {
        (, uint256 idleU,, uint256 v2U,, uint256 v3LU,, uint256 v3HU) = vault.getDistribution();
        return (idleU, v2U, v3LU, v3HU);
    }

    function wethIsToken0() internal view returns (bool) {
        return v3PoolHighFee.token0() == address(weth);
    }

    // ============ 事件辅助函数（避免VmSafe.Log类型问题） ============

    /// @notice 检查指定签名的事件是否被emit
    function _eventEmitted(bytes32 eventSig) internal view returns (bool) {
        for (uint256 i = 0; i < vm.getRecordedLogs().length; i++) {
            if (vm.getRecordedLogs()[i].topics.length > 0 && vm.getRecordedLogs()[i].topics[0] == eventSig) {
                return true;
            }
        }
        return false;
    }

    /// @notice 获取指定签名事件的data（第一个匹配）
    function _getEventData(bytes32 eventSig) internal view returns (bytes memory) {
        for (uint256 i = 0; i < vm.getRecordedLogs().length; i++) {
            if (vm.getRecordedLogs()[i].topics.length > 0 && vm.getRecordedLogs()[i].topics[0] == eventSig) {
                return vm.getRecordedLogs()[i].data;
            }
        }
        return "";
    }

    /// @notice 统计指定签名事件的数量
    function _countEvents(bytes32 eventSig) internal view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < vm.getRecordedLogs().length; i++) {
            if (vm.getRecordedLogs()[i].topics.length > 0 && vm.getRecordedLogs()[i].topics[0] == eventSig) {
                count++;
            }
        }
        return count;
    }
}
