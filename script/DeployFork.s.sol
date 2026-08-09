// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AdaptiveLPVault} from "../src/vault/AdaptiveLPVault.sol";
import {TWAPOracle} from "../src/oracles/TWAPOracle.sol";
import {AdaptiveRebalanceStrategy} from "../src/strategies/AdaptiveRebalanceStrategy.sol";
import {AdaptiveGovernance, GovernanceToken} from "../src/governance/AdaptiveGovernance.sol";
import {RebalanceIncentives} from "../src/incentives/RebalanceIncentives.sol";
import {UniswapV2Adapter} from "../src/adapters/UniswapV2Adapter.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";
import {ILPAdapter} from "../src/interfaces/ILPAdapter.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";

/**
 * @title DeployForkScript - Anvil主网Fork部署脚本
 * @notice 在 anvil --fork-url <MAINNET_RPC> 环境下部署合约系统
 * @dev
 *   1. 启动anvil: anvil --fork-url <MAINNET_RPC_URL> --chain-id 31337
 *   2. 部署: forge script script/DeployFork.s.sol:DeployForkScript --rpc-url http://localhost:8545 --broadcast
 *   3. 前端连接 http://localhost:8545, chainId 31337
 *
 *   注意：此脚本连接主网真实的WETH/USDC/Uniswap V2/V3合约，
 *   仅部署本项目的业务合约(vault/oracle/strategy/governance/adapters/incentives)。
 *   部署后会给前3个anvil测试账户mint WETH/USDC（通过deal等价方式：
 *   在fork环境中，anvil账户初始有10000 ETH，但没有WETH/USDC，
 *   需要从主网鲸鱼地址转账或用anvil的deal cheatcode）。
 */
contract DeployForkScript is Script {
    // 主网真实地址
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant V3_POOL_3000 = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
    address constant V3_POOL_500 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address constant V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    function run() external {
        uint256 deployerKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployer = vm.addr(deployerKey);
        console2.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        // 1. 治理
        GovernanceToken govToken = new GovernanceToken();
        AdaptiveGovernance governance = new AdaptiveGovernance(address(govToken));
        govToken.setMinter(address(governance));
        console2.log("GovToken:", address(govToken));
        console2.log("Governance:", address(governance));

        // 2. 策略和预言机（使用主网V3高费率池作为TWAP源）
        AdaptiveRebalanceStrategy strategy = new AdaptiveRebalanceStrategy(address(governance));
        TWAPOracle oracle = new TWAPOracle(V3_POOL_3000, WETH, USDC, address(governance));
        console2.log("Strategy:", address(strategy));
        console2.log("Oracle:", address(oracle));

        // 3. 金库
        AdaptiveLPVault vault = new AdaptiveLPVault(
            USDC, WETH, address(oracle), address(strategy), address(governance),
            "Adaptive LP Vault", "ALP-VAULT"
        );
        console2.log("Vault:", address(vault));

        // 4. 适配器 - 连接主网真实Uniswap合约
        UniswapV2Adapter v2Adapter = new UniswapV2Adapter(V2_ROUTER, address(vault), USDC, WETH);

        address p500t0 = IUniswapV3Pool(V3_POOL_500).token0();
        address p500t1 = IUniswapV3Pool(V3_POOL_500).token1();
        UniswapV3Adapter v3LowAdapter = new UniswapV3Adapter(
            V3_POOL_500, address(vault), p500t0, p500t1, ILPAdapter.AdapterType.UNISWAP_V3_LOW_FEE
        );

        address p3000t0 = IUniswapV3Pool(V3_POOL_3000).token0();
        address p3000t1 = IUniswapV3Pool(V3_POOL_3000).token1();
        UniswapV3Adapter v3HighAdapter = new UniswapV3Adapter(
            V3_POOL_3000, address(vault), p3000t0, p3000t1, ILPAdapter.AdapterType.UNISWAP_V3_HIGH_FEE
        );

        console2.log("V2Adapter:", address(v2Adapter));
        console2.log("V3LowAdapter:", address(v3LowAdapter));
        console2.log("V3HighAdapter:", address(v3HighAdapter));

        vault.setAdapters(address(v2Adapter), address(v3LowAdapter), address(v3HighAdapter));

        // 5. 激励
        RebalanceIncentives incentives = new RebalanceIncentives(address(vault), USDC, address(governance));
        vault.setIncentives(address(incentives));
        vault.setGovernance(address(governance));
        governance.setVault(address(vault));
        console2.log("Incentives:", address(incentives));

        // 6. 给激励合约充值10000 USDC
        //    注意：deployer在fork上初始没有USDC，需要从鲸鱼地址转账
        //    这里用vm.deal给deployer mint ETH，然后swap成USDC太复杂
        //    实际使用时可以手动给incentives合约转USDC，或用anvil的impersonate
        //    在脚本中用vm.prank模拟鲸鱼转账
        address usdcWhale = 0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503; // Circle/已知鲸鱼
        vm.stopBroadcast();

        // 用impersonate从鲸鱼地址转USDC给incentives和测试用户
        vm.startPrank(usdcWhale);
        IERC20(USDC).transfer(address(incentives), 10_000e6);
        IERC20(USDC).transfer(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, 100_000e6);
        IERC20(USDC).transfer(0x70997970C51812dc3A010C7d01b50e0d17dc79C8, 100_000e6);
        IERC20(USDC).transfer(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC, 100_000e6);
        vm.stopPrank();

        // WETH鲸鱼
        address wethWhale = 0xF04a5cC80B1E94C69B48f5ee68a08CD2F09A7c3E;
        vm.startPrank(wethWhale);
        IERC20(WETH).transfer(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, 100 ether);
        IERC20(WETH).transfer(0x70997970C51812dc3A010C7d01b50e0d17dc79C8, 100 ether);
        IERC20(WETH).transfer(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC, 100 ether);
        vm.stopPrank();

        console2.log("");
        console2.log("====== Fork Deployment Complete ======");
        console2.log("Test users funded with 100 WETH + 100,000 USDC each");
        console2.log("Incentives funded with 10,000 USDC");
        console2.log("Frontend: connect to http://localhost:8545, chainId 31337");
    }
}
