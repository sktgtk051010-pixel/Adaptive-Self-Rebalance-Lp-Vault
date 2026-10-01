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
import {LiquidityMining} from "../src/distribution/LiquidityMining.sol";
import {TeamVesting} from "../src/distribution/TeamVesting.sol";
import {Treasury} from "../src/distribution/Treasury.sol";
import {ILPAdapter} from "../src/interfaces/ILPAdapter.sol";
import {IUniswapV3Factory} from "../src/interfaces/IUniswapV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployScript - 一键部署完整系统到 Sepolia 测试网
 * @notice 部署 Adaptive LP Vault 完整系统，包含 V2/V3 全部三个适配器 + 代币分发体系
 * @dev
 *   前置准备：
 *   1. 确保 .env 文件中有 PRIVATE_KEY、SEPOLIA_RPC_URL、ETHERSCAN_API_KEY
 *   2. 确保部署钱包有足够的 Sepolia ETH（用于 gas 费）
 *   3. （可选）确保部署钱包有一些 Sepolia USDC，用于给激励合约充值
 *
 *   部署命令：
 *   forge script script/Deploy.s.sol:DeployScript --rpc-url sepolia --broadcast --verify
 *
 *   代币分配（总量 1000 万 ALP）：
 *   - 500 万 -> LiquidityMining（流动性挖矿，比特币式减半释放）
 *   - 100 万 -> RebalanceIncentives（再平衡执行者 ALP 奖励）
 *   - 200 万 -> TeamVesting（团队锁仓，1 年悬崖 + 3 年线性释放）
 *   - 200 万 -> Treasury（国库，治理提案才能支出）
 */
contract DeployScript is Script {
    // ============ Sepolia 真实合约地址 ============
    address constant WETH_SEPOLIA = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant UNISWAP_V3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    // Sepolia 上 Uniswap V2 Router（如果没有部署，传 address(0) 会跳过 V2 适配器）
    address constant UNISWAP_V2_ROUTER = 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3;

    uint256 constant INCENTIVE_INITIAL_FUND = 100_000e6; // 初始注入 10 万 USDC 作为再平衡奖励池；用完后可由 owner 再充值

    // ============ 代币分配常量 ============
    uint256 constant TOTAL_SUPPLY = 10_000_000e18;
    uint256 constant MINING_ALLOCATION = 5_000_000e18;    // 50% 流动性挖矿
    uint256 constant INCENTIVE_ALLOCATION = 1_000_000e18; // 10% 再平衡奖励
    uint256 constant TEAM_ALLOCATION = 2_000_000e18;      // 20% 团队锁仓
    uint256 constant TREASURY_ALLOCATION = 2_000_000e18;  // 20% 国库

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console2.log("========================================");
        console2.log("Deploying Adaptive LP Vault to Sepolia");
        console2.log("Deployer:", deployer);
        console2.log("========================================");

        vm.startBroadcast(deployerPrivateKey);

        // ============ 1. 治理代币 + 治理合约 ============
        GovernanceToken govToken = new GovernanceToken();
        AdaptiveGovernance governance = new AdaptiveGovernance(address(govToken));
        console2.log("");
        console2.log("[1/13] GovernanceToken:", address(govToken));
        console2.log("[1/13] AdaptiveGovernance:", address(governance));

        // ============ 2. 策略合约 ============
        AdaptiveRebalanceStrategy strategy = new AdaptiveRebalanceStrategy(address(governance));
        console2.log("[2/13] AdaptiveRebalanceStrategy:", address(strategy));

        // ============ 3. 获取 V3 池地址 ============
        IUniswapV3Factory factory = IUniswapV3Factory(UNISWAP_V3_FACTORY);
        address v3Pool500 = factory.getPool(WETH_SEPOLIA, USDC_SEPOLIA, 500);
        address v3Pool3000 = factory.getPool(WETH_SEPOLIA, USDC_SEPOLIA, 3000);
        console2.log("[3/13] V3 0.05% pool:", v3Pool500);
        console2.log("[3/13] V3 0.30% pool:", v3Pool3000);

        // 选择高费率池作为预言机源；如果高费率池不存在，用低费率池
        address oraclePool = v3Pool3000 != address(0) ? v3Pool3000 : v3Pool500;
        require(oraclePool != address(0), "No V3 pool found on Sepolia for WETH/USDC");

        // ============ 4. TWAP 预言机 ============
        TWAPOracle oracle = new TWAPOracle(oraclePool, WETH_SEPOLIA, USDC_SEPOLIA, address(governance));
        console2.log("[4/13] TWAPOracle:", address(oracle));

        // ============ 5. 金库 ============
        AdaptiveLPVault vault = new AdaptiveLPVault(
            USDC_SEPOLIA, WETH_SEPOLIA, address(oracle), address(strategy),
            "Adaptive LP Vault", "ALP-VAULT"
        );
        console2.log("[5/13] AdaptiveLPVault:", address(vault));

        // ============ 6. 确定 token 顺序 ============
        // V3 池的 token0 是地址较小的那个，token1 是地址较大的那个
        (address token0, address token1) = WETH_SEPOLIA < USDC_SEPOLIA
            ? (WETH_SEPOLIA, USDC_SEPOLIA) : (USDC_SEPOLIA, WETH_SEPOLIA);
        console2.log("[6/13] token0:", token0);
        console2.log("[6/13] token1:", token1);

        // ============ 7. V2 适配器 ============
        address v2AdapterAddr = address(0);
        if (UNISWAP_V2_ROUTER != address(0)) {
            v2AdapterAddr = address(new UniswapV2Adapter(
                UNISWAP_V2_ROUTER, address(vault), USDC_SEPOLIA, WETH_SEPOLIA));
            console2.log("[7/13] UniswapV2Adapter:", v2AdapterAddr);
        } else {
            console2.log("[7/13] V2 Adapter: skipped (no V2 router on Sepolia)");
        }

        // ============ 8. V3 适配器 ============
        address v3LowFeeAdapter = address(0);
        address v3HighFeeAdapter = address(0);

        if (v3Pool500 != address(0)) {
            v3LowFeeAdapter = address(new UniswapV3Adapter(
                v3Pool500, address(vault), token0, token1, ILPAdapter.AdapterType.UNISWAP_V3_LOW_FEE));
            console2.log("[8/13] V3LowFeeAdapter:", v3LowFeeAdapter);
        } else {
            console2.log("[8/13] V3LowFeeAdapter: skipped (no 0.05% pool)");
        }

        if (v3Pool3000 != address(0)) {
            v3HighFeeAdapter = address(new UniswapV3Adapter(
                v3Pool3000, address(vault), token0, token1, ILPAdapter.AdapterType.UNISWAP_V3_HIGH_FEE));
            console2.log("[8/13] V3HighFeeAdapter:", v3HighFeeAdapter);
        } else {
            console2.log("[8/13] V3HighFeeAdapter: skipped (no 0.30% pool)");
        }

        // ============ 9. 设置适配器到金库 ============
        vault.setAdapters(v2AdapterAddr, v3LowFeeAdapter, v3HighFeeAdapter);
        console2.log("[9/13] Adapters set to vault");

        // ============ 10. 激励合约 + 关联设置 ============
        RebalanceIncentives incentives = new RebalanceIncentives(
            address(vault), USDC_SEPOLIA, address(govToken));
        console2.log("[10/13] RebalanceIncentives:", address(incentives));

        // 金库关联设置
        vault.setIncentives(address(incentives));

        // 治理合约关联设置（用于治理提案执行时同步参数）
        governance.setVault(address(vault));
        governance.setStrategy(address(strategy));
        governance.setOracle(address(oracle));
        governance.setIncentives(address(incentives));

        // ============ 11. 代币分发合约 ============
        // 流动性挖矿（奖励 ALP，比特币式减半释放）
        LiquidityMining liquidityMining = new LiquidityMining(address(govToken), address(vault));
        console2.log("[11/13] LiquidityMining:", address(liquidityMining));

        // 团队锁仓（1 年悬崖 + 3 年线性释放）
        TeamVesting teamVesting = new TeamVesting(address(govToken), deployer);
        console2.log("[11/13] TeamVesting:", address(teamVesting));

        // 国库（治理提案才能支出）
        Treasury treasury = new Treasury();
        console2.log("[11/13] Treasury:", address(treasury));
        governance.setTreasury(address(treasury));

        // 金库关联挖矿合约
        vault.setLiquidityMining(address(liquidityMining));

        // 注：分发合约的 owner 都是治理合约，治理可通过 executeAsOwner 直接调用，无需存储地址

        // ============ 12. Mint 1000 万 ALP 并分配 ============
        console2.log("");
        console2.log("Minting 10,000,000 ALP and distributing...");
        govToken.mint(address(liquidityMining), MINING_ALLOCATION);
        govToken.mint(address(incentives), INCENTIVE_ALLOCATION);
        govToken.mint(address(teamVesting), TEAM_ALLOCATION);
        govToken.mint(address(treasury), TREASURY_ALLOCATION);
        console2.log("  -> LiquidityMining:", MINING_ALLOCATION / 1e18, "ALP");
        console2.log("  -> RebalanceIncentives:", INCENTIVE_ALLOCATION / 1e18, "ALP");
        console2.log("  -> TeamVesting:", TEAM_ALLOCATION / 1e18, "ALP");
        console2.log("  -> Treasury:", TREASURY_ALLOCATION / 1e18, "ALP");

        // 把 minter 转移给治理合约（之后只能通过治理提案 mint）
        govToken.setMinter(address(governance));
        console2.log("  -> Minter transferred to Governance");

        // 启动挖矿和锁仓计时
        liquidityMining.startMining();
        teamVesting.startVesting();
        console2.log("  -> Mining and vesting started");

        // ============ 13. 把各合约 owner 转移给治理合约 ============
        console2.log("");
        console2.log("Transferring ownership to Governance contract...");
        strategy.transferOwnership(address(governance));
        oracle.transferOwnership(address(governance));
        vault.transferOwnership(address(governance));
        incentives.transferOwnership(address(governance));
        liquidityMining.transferOwnership(address(governance));
        teamVesting.transferOwnership(address(governance));
        treasury.transferOwnership(address(governance));
        console2.log("Ownership transferred to Governance:", address(governance));

        // ============ （可选）给激励合约充值 USDC ============
        if (INCENTIVE_INITIAL_FUND > 0) {
            uint256 deployerUsdcBalance = IERC20(USDC_SEPOLIA).balanceOf(deployer);
            if (deployerUsdcBalance >= INCENTIVE_INITIAL_FUND) {
                IERC20(USDC_SEPOLIA).transfer(address(incentives), INCENTIVE_INITIAL_FUND);
                console2.log("");
                console2.log("Incentives funded with", INCENTIVE_INITIAL_FUND / 1e6, "USDC");
            } else {
                console2.log("");
                console2.log("WARNING: Not enough USDC to fund incentives.");
                console2.log("  Deployer balance:", deployerUsdcBalance / 1e6, "USDC");
                console2.log("  Required:", INCENTIVE_INITIAL_FUND / 1e6, "USDC");
                console2.log("  Please manually fund the incentives contract after deployment.");
            }
        }

        console2.log("");
        console2.log("========================================");
        console2.log("Deployment Complete!");
        console2.log("========================================");
        console2.log("");
        console2.log("Contract Addresses:");
        console2.log("  GovernanceToken:", address(govToken));
        console2.log("  AdaptiveGovernance:", address(governance));
        console2.log("  AdaptiveRebalanceStrategy:", address(strategy));
        console2.log("  TWAPOracle:", address(oracle));
        console2.log("  AdaptiveLPVault:", address(vault));
        console2.log("  UniswapV2Adapter:", v2AdapterAddr);
        console2.log("  V3LowFeeAdapter:", v3LowFeeAdapter);
        console2.log("  V3HighFeeAdapter:", v3HighFeeAdapter);
        console2.log("  RebalanceIncentives:", address(incentives));
        console2.log("  LiquidityMining:", address(liquidityMining));
        console2.log("  TeamVesting:", address(teamVesting));
        console2.log("  Treasury:", address(treasury));
        console2.log("");
        console2.log("Next steps:");
        console2.log("1. Save all contract addresses above");
        console2.log("2. (Optional) Fund incentives contract with USDC");
        console2.log("3. Test deposit/withdraw/rebalance functionality");
        console2.log("");

        vm.stopBroadcast();
    }
}

