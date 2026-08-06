// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AdaptiveLPVault} from "../src/vault/AdaptiveLPVault.sol";
import {TWAPOracle} from "../src/oracles/TWAPOracle.sol";
import {AdaptiveRebalanceStrategy} from "../src/strategies/AdaptiveRebalanceStrategy.sol";
import {AdaptiveGovernance, GovernanceToken} from "../src/governance/AdaptiveGovernance.sol";
import {RebalanceIncentives} from "../src/incentives/RebalanceIncentives.sol";
import {UniswapV2Adapter} from "../src/adapters/UniswapV2Adapter.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";
import {ILPAdapter} from "../src/interfaces/ILPAdapter.sol";
import {IUniswapV3Factory} from "../src/interfaces/IUniswapV3.sol";

/**
 * @title DeployScript - 一键部署完整系统（V2 + V3双费率）
 * @notice 部署 Adaptive LP Vault 到 Sepolia，包含 V2/V3 全部三个适配器
 * @dev
 *   forge script script/Deploy.s.sol:DeployScript --rpc-url sepolia --broadcast --verify
 */
contract DeployScript is Script {
    // ============ Sepolia 地址 ============
    address constant WETH_SEPOLIA = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant UNISWAP_V3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    // Sepolia 上 Uniswap V2 Router（如有部署；无则传 address(0) 跳过 V2）
    address constant UNISWAP_V2_ROUTER = 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console2.log("Deploying from:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. 治理代币 + 治理
        GovernanceToken govToken = new GovernanceToken();
        AdaptiveGovernance governance = new AdaptiveGovernance(address(govToken));
        govToken.setMinter(address(governance));
        console2.log("GovernanceToken:", address(govToken));
        console2.log("AdaptiveGovernance:", address(governance));

        // 2. 策略
        AdaptiveRebalanceStrategy strategy = new AdaptiveRebalanceStrategy(address(governance));
        console2.log("AdaptiveRebalanceStrategy:", address(strategy));

        // 3. 获取V3池地址
        IUniswapV3Factory factory = IUniswapV3Factory(UNISWAP_V3_FACTORY);
        address v3Pool500 = factory.getPool(WETH_SEPOLIA, USDC_SEPOLIA, 500);
        address v3Pool3000 = factory.getPool(WETH_SEPOLIA, USDC_SEPOLIA, 3000);
        console2.log("V3 0.05% pool:", v3Pool500);
        console2.log("V3 0.30% pool:", v3Pool3000);

        address oraclePool = v3Pool3000 != address(0) ? v3Pool3000 : v3Pool500;
        require(oraclePool != address(0), "No V3 pool");

        // 4. TWAP预言机
        TWAPOracle oracle = new TWAPOracle(oraclePool, WETH_SEPOLIA, USDC_SEPOLIA, address(governance));
        console2.log("TWAPOracle:", address(oracle));

        // 5. 金库
        AdaptiveLPVault vault = new AdaptiveLPVault(
            USDC_SEPOLIA, WETH_SEPOLIA, address(oracle), address(strategy), address(governance),
            "Adaptive LP Vault", "ALP-VAULT"
        );
        console2.log("AdaptiveLPVault:", address(vault));

        // 6. token顺序
        (address token0, address token1) = WETH_SEPOLIA < USDC_SEPOLIA
            ? (WETH_SEPOLIA, USDC_SEPOLIA) : (USDC_SEPOLIA, WETH_SEPOLIA);

        // 7. V2 适配器
        address v2AdapterAddr = address(0);
        if (UNISWAP_V2_ROUTER != address(0)) {
            v2AdapterAddr = address(new UniswapV2Adapter(UNISWAP_V2_ROUTER, address(vault), USDC_SEPOLIA, WETH_SEPOLIA));
            console2.log("UniswapV2Adapter:", v2AdapterAddr);
        } else {
            console2.log("V2 Adapter: skipped (no V2 router on this network)");
        }

        // 8. V3 适配器
        address v3LowFeeAdapter = address(0);
        address v3HighFeeAdapter = address(0);
        if (v3Pool500 != address(0)) {
            v3LowFeeAdapter = address(new UniswapV3Adapter(
                v3Pool500, address(vault), token0, token1, ILPAdapter.AdapterType.UNISWAP_V3_LOW_FEE));
            console2.log("V3LowFeeAdapter:", v3LowFeeAdapter);
        }
        if (v3Pool3000 != address(0)) {
            v3HighFeeAdapter = address(new UniswapV3Adapter(
                v3Pool3000, address(vault), token0, token1, ILPAdapter.AdapterType.UNISWAP_V3_HIGH_FEE));
            console2.log("V3HighFeeAdapter:", v3HighFeeAdapter);
        }

        // 9. 设置适配器（V2+V3全部）
        vault.setAdapters(v2AdapterAddr, v3LowFeeAdapter, v3HighFeeAdapter);

        // 10. 激励
        RebalanceIncentives incentives = new RebalanceIncentives(address(vault), USDC_SEPOLIA);
        console2.log("RebalanceIncentives:", address(incentives));
        vault.setIncentives(address(incentives));
        vault.setGovernance(address(governance));
        governance.setVault(address(vault));

        console2.log("");
        console2.log("====== Deployment Complete ======");
        vm.stopBroadcast();
    }
}
