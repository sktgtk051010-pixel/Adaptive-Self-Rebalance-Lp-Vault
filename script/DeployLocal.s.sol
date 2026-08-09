// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MockWETH, MockUSDC} from "../src/tokens/MockTokens.sol";
import {TWAPOracle} from "../src/oracles/TWAPOracle.sol";
import {AdaptiveRebalanceStrategy} from "../src/strategies/AdaptiveRebalanceStrategy.sol";
import {UniswapV2Adapter} from "../src/adapters/UniswapV2Adapter.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";
import {AdaptiveLPVault} from "../src/vault/AdaptiveLPVault.sol";
import {RebalanceIncentives} from "../src/incentives/RebalanceIncentives.sol";
import {GovernanceToken, AdaptiveGovernance} from "../src/governance/AdaptiveGovernance.sol";
import {ILPAdapter} from "../src/interfaces/ILPAdapter.sol";
import {MockUniswapV2Factory, MockUniswapV2Router} from "../test/mocks/MockUniswapV2.sol";
import {MockUniswapV3Factory, MockUniswapV3Pool} from "../test/mocks/MockUniswapV3.sol";

/**
 * @title DeployLocalScript - Anvil本地部署脚本
 * @notice 使用Mock合约部署完整系统，用于前端本地测试
 * @dev
 *   启动anvil: anvil
 *   部署: forge script script/DeployLocal.s.sol:DeployLocalScript --rpc-url http://localhost:8545 --broadcast
 */
contract DeployLocalScript is Script {
    // 状态变量（避免run函数内局部变量太多导致stack too deep）
    MockWETH weth;
    MockUSDC usdc;
    MockUniswapV2Router v2Router;
    address poolLow;
    address poolHigh;
    address token0;
    address token1;
    GovernanceToken govToken;
    AdaptiveGovernance governance;
    AdaptiveRebalanceStrategy strategy;
    TWAPOracle oracle;
    AdaptiveLPVault vault;
    UniswapV2Adapter v2Adapter;
    UniswapV3Adapter v3LowAdapter;
    UniswapV3Adapter v3HighAdapter;
    RebalanceIncentives incentives;

    function run() external {
        // 使用anvil默认账户
        uint256 deployerKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployer = vm.addr(deployerKey);
        console2.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        // 1. 部署代币
        weth = new MockWETH();
        usdc = new MockUSDC();
        console2.log("WETH:", address(weth));
        console2.log("USDC:", address(usdc));

        // 2. 部署Mock Uniswap V2
        MockUniswapV2Factory v2Factory = new MockUniswapV2Factory();
        v2Router = new MockUniswapV2Router(address(v2Factory), address(weth));
        console2.log("V2Factory:", address(v2Factory));
        console2.log("V2Router:", address(v2Router));

        // 3. 部署Mock Uniswap V3
        MockUniswapV3Factory v3Factory = new MockUniswapV3Factory();
        poolLow = v3Factory.createPool(address(weth), address(usdc), 500);
        poolHigh = v3Factory.createPool(address(weth), address(usdc), 3000);
        MockUniswapV3Pool(poolLow).setPrice(2000);
        MockUniswapV3Pool(poolHigh).setPrice(2000);
        console2.log("V3Pool 0.05%:", poolLow);
        console2.log("V3Pool 0.30%:", poolHigh);

        // 4. token顺序（Mock不排序，token0=weth, token1=usdc）
        token0 = MockUniswapV3Pool(poolHigh).token0();
        token1 = MockUniswapV3Pool(poolHigh).token1();
        console2.log("token0:", token0, "(WETH)");
        console2.log("token1:", token1, "(USDC)");

        // 5. 治理
        govToken = new GovernanceToken();
        governance = new AdaptiveGovernance(address(govToken));
        govToken.setMinter(address(governance));
        console2.log("GovToken:", address(govToken));
        console2.log("Governance:", address(governance));

        // 6. 策略和预言机
        strategy = new AdaptiveRebalanceStrategy(address(governance));
        oracle = new TWAPOracle(poolHigh, address(weth), address(usdc), address(governance));
        console2.log("Strategy:", address(strategy));
        console2.log("Oracle:", address(oracle));

        // 7. 金库
        vault = new AdaptiveLPVault(
            address(usdc), address(weth), address(oracle), address(strategy),
            address(governance), "Adaptive LP Vault", "ALP-VAULT"
        );
        console2.log("Vault:", address(vault));

        // 8. 适配器
        v2Adapter = new UniswapV2Adapter(address(v2Router), address(vault), token0, token1);
        v3LowAdapter = new UniswapV3Adapter(poolLow, address(vault), token0, token1, ILPAdapter.AdapterType.UNISWAP_V3_LOW_FEE);
        v3HighAdapter = new UniswapV3Adapter(poolHigh, address(vault), token0, token1, ILPAdapter.AdapterType.UNISWAP_V3_HIGH_FEE);
        console2.log("V2Adapter:", address(v2Adapter));
        console2.log("V3LowAdapter:", address(v3LowAdapter));
        console2.log("V3HighAdapter:", address(v3HighAdapter));

        vault.setAdapters(address(v2Adapter), address(v3LowAdapter), address(v3HighAdapter));

        // 9. 激励
        incentives = new RebalanceIncentives(address(vault), address(usdc), address(governance));
        vault.setIncentives(address(incentives));
        vault.setGovernance(address(governance));
        governance.setVault(address(vault));
        console2.log("Incentives:", address(incentives));

        // 10. 给测试地址mint代币（anvil默认账户）
        address[3] memory testUsers = [
            address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266),
            address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8),
            address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC)
        ];

        for (uint i = 0; i < testUsers.length; i++) {
            weth.mint(testUsers[i], 100 ether);
            usdc.mint(testUsers[i], 200_000e6);
        }

        // 给激励合约充值
        usdc.mint(address(incentives), 100_000e6);

        console2.log("");
        console2.log("====== Local Deployment Complete ======");
        console2.log("Test users funded with 100 WETH + 200,000 USDC each");
        console2.log("Initial price: 2000 USDC per ETH");

        vm.stopBroadcast();
    }
}
