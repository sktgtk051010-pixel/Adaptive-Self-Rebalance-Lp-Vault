// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AdaptiveLPVault} from "../../src/vault/AdaptiveLPVault.sol";
import {TWAPOracle} from "../../src/oracles/TWAPOracle.sol";
import {AdaptiveRebalanceStrategy} from "../../src/strategies/AdaptiveRebalanceStrategy.sol";
import {AdaptiveGovernance, GovernanceToken} from "../../src/governance/AdaptiveGovernance.sol";
import {RebalanceIncentives} from "../../src/incentives/RebalanceIncentives.sol";
import {UniswapV2Adapter} from "../../src/adapters/UniswapV2Adapter.sol";
import {UniswapV3Adapter} from "../../src/adapters/UniswapV3Adapter.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {IUniswapV3Pool} from "../../src/interfaces/IUniswapV3.sol";

interface IUniswapV2RouterSimple {
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
}

interface IUniswapV3SwapRouterSimple {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

contract ForkTest is Test {
    using SafeERC20 for IERC20;

    address constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant MAINNET_V3_POOL_3000 = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
    address constant MAINNET_V3_POOL_500 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address constant MAINNET_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant MAINNET_V3_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address constant USDC_WHALE = 0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503;
    address constant WETH_WHALE = 0xF04a5cC80B1E94C69B48f5ee68a08CD2F09A7c3E;

    address constant ALICE = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant BOB = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant CHARLIE = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    GovernanceToken public govToken;
    AdaptiveGovernance public governance;
    AdaptiveRebalanceStrategy public strategy;
    TWAPOracle public oracle;
    AdaptiveLPVault public vault;
    UniswapV2Adapter public v2Adapter;
    UniswapV3Adapter public v3LowAdapter;
    UniswapV3Adapter public v3HighAdapter;
    RebalanceIncentives public incentives;

    IERC20 public weth = IERC20(MAINNET_WETH);
    IERC20 public usdc = IERC20(MAINNET_USDC);

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");

        govToken = new GovernanceToken();
        governance = new AdaptiveGovernance(address(govToken));
        govToken.setMinter(address(governance));

        strategy = new AdaptiveRebalanceStrategy(address(governance));
        oracle = new TWAPOracle(MAINNET_V3_POOL_3000, MAINNET_WETH, MAINNET_USDC, address(governance));

        vault = new AdaptiveLPVault(
            MAINNET_USDC, MAINNET_WETH, address(oracle), address(strategy), address(governance),
            "Adaptive LP Vault", "ALP-VAULT"
        );

        v2Adapter = new UniswapV2Adapter(MAINNET_V2_ROUTER, address(vault), MAINNET_USDC, MAINNET_WETH);

        address p500t0 = IUniswapV3Pool(MAINNET_V3_POOL_500).token0();
        address p500t1 = IUniswapV3Pool(MAINNET_V3_POOL_500).token1();
        v3LowAdapter = new UniswapV3Adapter(
            MAINNET_V3_POOL_500, address(vault), p500t0, p500t1, ILPAdapter.AdapterType.UNISWAP_V3_LOW_FEE
        );

        address p3000t0 = IUniswapV3Pool(MAINNET_V3_POOL_3000).token0();
        address p3000t1 = IUniswapV3Pool(MAINNET_V3_POOL_3000).token1();
        v3HighAdapter = new UniswapV3Adapter(
            MAINNET_V3_POOL_3000, address(vault), p3000t0, p3000t1, ILPAdapter.AdapterType.UNISWAP_V3_HIGH_FEE
        );

        vault.setAdapters(address(v2Adapter), address(v3LowAdapter), address(v3HighAdapter));

        vault.setMaxSlippage(500);

        incentives = new RebalanceIncentives(address(vault), MAINNET_USDC, address(governance));
        vault.setIncentives(address(incentives));
        vault.setGovernance(address(governance));
        governance.setVault(address(vault));

        _fundUser(ALICE, 50 ether, 100_000e6);
        _fundUser(BOB, 50 ether, 100_000e6);
        _fundUser(CHARLIE, 50 ether, 100_000e6);

        _fundUser(address(this), 100 ether, 200_000e6);

        usdc.transfer(address(incentives), 10_000e6);
    }

    function _fundUser(address user, uint256 wethAmount, uint256 usdcAmount) internal {
        vm.deal(user, 1000 ether);

        vm.startPrank(user);

        (bool success, ) = MAINNET_WETH.call{value: wethAmount}("");
        require(success, "WETH deposit failed");

        address[] memory path = new address[](2);
        path[0] = MAINNET_WETH;
        path[1] = MAINNET_USDC;
        uint256 ethForUSDC = 1000 ether - wethAmount;
        IUniswapV2RouterSimple(MAINNET_V2_ROUTER).swapExactETHForTokens{value: ethForUSDC}(
            0,
            path,
            user,
            block.timestamp + 300
        );

        require(IERC20(MAINNET_USDC).balanceOf(user) >= usdcAmount, "not enough USDC");

        vm.stopPrank();
    }

    function _deposit(address user, uint256 wethAmount, uint256 usdcAmount) internal returns (uint256 shares) {
        vm.startPrank(user);
        weth.approve(address(vault), wethAmount);
        usdc.approve(address(vault), usdcAmount);
        shares = vault.deposit(wethAmount, usdcAmount, 0);
        vm.stopPrank();
    }

    function _getV3Tick() internal view returns (int24 tickLower, int24 tickUpper) {
        (, int24 currentTick, , , , , ) = IUniswapV3Pool(MAINNET_V3_POOL_3000).slot0();
        int24 tickSpacing = IUniswapV3Pool(MAINNET_V3_POOL_3000).tickSpacing();
        int24 aligned = currentTick - (currentTick % tickSpacing);
        tickLower = aligned - tickSpacing * 10;
        tickUpper = aligned + tickSpacing * 10;
    }

    // 测试主网分叉环境下所有合约正确部署和初始化
    function test_Fork_Deployment_ContractsInitialized() public view {
        assertTrue(address(vault) != address(0), "vault not deployed");
        assertTrue(address(oracle) != address(0), "oracle not deployed");
        assertTrue(address(strategy) != address(0), "strategy not deployed");
        assertTrue(address(governance) != address(0), "governance not deployed");
        assertTrue(address(v2Adapter) != address(0), "v2Adapter not deployed");
        assertTrue(address(v3LowAdapter) != address(0), "v3LowAdapter not deployed");
        assertTrue(address(v3HighAdapter) != address(0), "v3HighAdapter not deployed");
        assertTrue(address(incentives) != address(0), "incentives not deployed");

        assertEq(vault.asset(), MAINNET_USDC, "vault asset should be USDC");
        assertEq(address(vault.ORACLE()), address(oracle), "vault oracle mismatch");
    }

    // 测试主网V3 0.3%池的当前价格可以正常读取
    function test_Fork_Mainnet_V3Pool_PriceReadable() public view {
        (uint160 sqrtPriceX96, int24 tick, , , , , ) = IUniswapV3Pool(MAINNET_V3_POOL_3000).slot0();
        assertGt(sqrtPriceX96, 0, "sqrtPriceX96 should be > 0");
        assertGt(tick, 0, "tick should be positive (token0=USDC, token1=WETH)");
        console2.log("V3 0.3% pool current tick:", tick);
    }

    // 测试主网环境下预言机可以读取TWAP价格
    function test_Fork_Oracle_GetTWAPPrice() public {
        oracle.ensureObservationCardinality(10);

        (uint160 sqrtPriceX96Twap, int24 tick) = oracle.getTWAPPrice();
        assertGt(sqrtPriceX96Twap, 0, "TWAP sqrtPrice should be > 0");
        assertGt(tick, 0);
        console2.log("TWAP tick:", tick);
    }

    // 测试主网环境下完整流程：存款→再平衡→全额赎回
    function test_Fork_Deposit_Rebalance_withdraw() public {
        uint256 shares = _deposit(ALICE, 1 ether, 2000e6);
        assertGt(shares, 0, "shares should be > 0");
        assertEq(vault.balanceOf(ALICE), shares, "alice should have shares");

        uint256 assetsAfterDeposit = vault.totalAssets();
        assertGt(assetsAfterDeposit, 0, "totalAssets should be > 0");

        vault.rebalance();
        assertEq(vault.rebalanceCount(), 1, "rebalanceCount should be 1");

        (uint256 v2Weight, uint256 v3LowWeight, uint256 v3HighWeight) = vault.currentWeights();
        assertGt(v2Weight + v3LowWeight + v3HighWeight, 0, "weights should be set");

        assertGt(vault.totalAssets(), 0, "totalAssets should > 0 after rebalance");

        uint256 wethBefore = weth.balanceOf(ALICE);
        uint256 usdcBefore = usdc.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(shares, 0, 0);

        assertGt(wethOut, 0);
        assertGt(usdcOut, 0);
        assertEq(weth.balanceOf(ALICE), wethBefore + wethOut, "weth balance should increase");
        assertEq(usdc.balanceOf(ALICE), usdcBefore + usdcOut, "usdc balance should increase");
    }

    // 测试主网环境下多用户存款无稀释，Alice赎回不影响Bob的资产价值
    function test_Fork_MultipleUsers_NoUnaffected() public {
        uint256 sharesA = _deposit(ALICE, 10 ether, 20_000e6);
        uint256 assetsPerShareA = vault.totalAssets() * 1e18 / sharesA;

        uint256 sharesB = _deposit(BOB, 10 ether, 20_000e6);
        uint256 assetsPerShareB = vault.totalAssets() * 1e18 / vault.totalSupply();

        assertApproxEqRel(sharesB, sharesA, 0.01e18, "same deposit = same shares");
        assertApproxEqRel(assetsPerShareB, assetsPerShareA, 0.01e18, "no dilution");

        vault.rebalance();

        uint256 bobAssetsBefore = vault.convertToAssets(sharesB);
        uint256 bobSharesBefore = vault.balanceOf(BOB);

        vm.prank(ALICE);
        vault.withdrawDual(sharesA, 0, 0);

        uint256 bobAssetsAfter = vault.convertToAssets(sharesB);
        assertApproxEqRel(bobAssetsAfter, bobAssetsBefore, 0.05e18, "Bob assets should not change");
        assertEq(vault.balanceOf(BOB), bobSharesBefore, "Bob shares should not change");
    }

    // 测试主网环境下V2适配器完整生命周期：添加流动性→部分撤出→全部撤出
    function test_Fork_V2Adapter_FullLifecycle() public {
        weth.transfer(address(vault), 5 ether);
        usdc.transfer(address(vault), 10_000e6);

        vm.prank(address(vault));
        (uint256 amount0, uint256 amount1, bytes32 lpId) = v2Adapter.addLiquidity(
            10_000e6, 5 ether, 0, 0, ""
        );

        assertGt(amount0, 0, "v2 amount0 should be > 0");
        assertGt(amount1, 0, "v2 amount1 should be > 0");
        uint256 lpBalanceAfterAdd = v2Adapter.getLpBalance();
        assertGt(lpBalanceAfterAdd, 0, "v2 LP balance should be > 0");

        uint256 lpToRemove = lpBalanceAfterAdd / 2;
        if (lpToRemove == 0) lpToRemove = 1;

        uint256 vaultUsdcBeforeRemove = usdc.balanceOf(address(vault));
        uint256 vaultWethBeforeRemove = weth.balanceOf(address(vault));

        vm.prank(address(vault));
        (uint256 removed0, uint256 removed1) = v2Adapter.removeLiquidity(
            lpId, uint128(lpToRemove), 0, 0
        );

        assertGt(removed0, 0);
        assertGt(removed1, 0);
        assertEq(usdc.balanceOf(address(vault)), vaultUsdcBeforeRemove + removed0, "vault USDC should increase after removeLiquidity");
        assertEq(weth.balanceOf(address(vault)), vaultWethBeforeRemove + removed1, "vault WETH should increase after removeLiquidity");

        uint256 lpBalanceAfterRemove = v2Adapter.getLpBalance();
        assertEq(lpBalanceAfterRemove, lpBalanceAfterAdd - lpToRemove, "LP balance should decrease by removed amount");

        vm.prank(address(vault));
        v2Adapter.withdrawAll();

        assertEq(v2Adapter.getLpBalance(), 0, "LP balance should be 0 after withdrawAll");
    }

    // 测试主网环境下V3适配器完整生命周期：添加→真实swap产生手续费→收取手续费→部分撤出→全部撤出
    function test_Fork_V3Adapter_FullLifecycle() public {
        (int24 tickLower, int24 tickUpper) = _getV3Tick();

        weth.transfer(address(vault), 5 ether);
        usdc.transfer(address(vault), 10_000e6);

        vm.prank(address(vault));
        (uint256 amount0, uint256 amount1, bytes32 lpId) = v3HighAdapter.addLiquidity(
            10_000e6, 5 ether, 0, 0, abi.encode(tickLower, tickUpper)
        );

        assertGt(amount0 + amount1, 0, "v3 total amount should be > 0");
        assertGt(v3HighAdapter.getLpBalance(), 0, "v3 LP balance should be > 0");

        bytes32[] memory positions = v3HighAdapter.getActivePositions();
        assertEq(positions.length, 1, "should have 1 active position after addLiquidity");

        (, , uint128 liquidityAfterAdd, , , , , bool activeAfterAdd) = v3HighAdapter.getPositionInfo(lpId);
        assertTrue(activeAfterAdd, "position should be active after addLiquidity");
        assertGt(uint256(liquidityAfterAdd), 0, "liquidity should be > 0 after addLiquidity");

        weth.approve(MAINNET_V3_SWAP_ROUTER, 1 ether);

        IUniswapV3SwapRouterSimple.ExactInputSingleParams memory swapParams = IUniswapV3SwapRouterSimple.ExactInputSingleParams({
            tokenIn: MAINNET_WETH,
            tokenOut: MAINNET_USDC,
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp + 600,
            amountIn: 1 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        uint256 usdcOut = IUniswapV3SwapRouterSimple(MAINNET_V3_SWAP_ROUTER).exactInputSingle(swapParams);
        assertGt(usdcOut, 0, "swap should receive USDC");

        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));
        uint256 vaultWethBefore = weth.balanceOf(address(vault));

        vm.prank(address(vault));
        (uint256 fees0, uint256 fees1) = v3HighAdapter.collectFees(lpId);

        assertGt(fees0 + fees1, 0, "should collect fees after swap");
        assertGt(usdc.balanceOf(address(vault)) + weth.balanceOf(address(vault)),
            vaultUsdcBefore + vaultWethBefore, "vault balance should increase after collectFees");

        bytes32[] memory positionsAfterCollect = v3HighAdapter.getActivePositions();
        assertEq(positionsAfterCollect.length, 1, "should still have 1 active position after collectFees");

        uint128 liquidityToRemove = uint128(uint256(liquidityAfterAdd) / 2);
        if (liquidityToRemove == 0) liquidityToRemove = 1;

        uint256 vaultUsdcBeforeRemove = usdc.balanceOf(address(vault));
        uint256 vaultWethBeforeRemove = weth.balanceOf(address(vault));

        vm.prank(address(vault));
        (uint256 removed0, uint256 removed1) = v3HighAdapter.removeLiquidity(
            lpId, liquidityToRemove, 0, 0
        );

        assertGt(removed0 + removed1, 0, "should receive tokens after removeLiquidity");
        assertGt(usdc.balanceOf(address(vault)), vaultUsdcBeforeRemove, "vault USDC should increase after removeLiquidity");
        assertGt(weth.balanceOf(address(vault)), vaultWethBeforeRemove, "vault WETH should increase after removeLiquidity");

        (, , uint128 liquidityAfterRemove, , , , , bool activeAfterRemove) = v3HighAdapter.getPositionInfo(lpId);
        assertEq(uint256(liquidityAfterRemove), uint256(liquidityAfterAdd) - uint256(liquidityToRemove), "liquidity should decrease by removed amount");
        assertTrue(activeAfterRemove, "position should still be active after partial remove");

        assertEq(v3HighAdapter.getLpBalance(), uint256(liquidityAfterRemove), "getLpBalance should match remaining liquidity");

        vm.prank(address(vault));
        v3HighAdapter.withdrawAll();

        bytes32[] memory positionsAfterWithdraw = v3HighAdapter.getActivePositions();
        assertEq(positionsAfterWithdraw.length, 0, "should have 0 active positions after withdrawAll");

        assertEq(v3HighAdapter.getLpBalance(), 0, "LP balance should be 0 after withdrawAll");

        (, , , , , , , bool activeAfterWithdraw) = v3HighAdapter.getPositionInfo(lpId);
        assertFalse(activeAfterWithdraw, "position should not be active after withdrawAll");
    }

    // 测试主网环境下治理提案完整流程：发起→投票→通过→时间锁→执行
    function test_Fork_Governance_Proposal_Execute() public {
        vm.prank(address(governance));
        govToken.mint(ALICE, 2000e18);
        vm.prank(address(governance));
        govToken.mint(BOB, 20000e18);

        vm.prank(BOB);
        govToken.delegate(BOB);

        vm.roll(block.number + 1);

        vm.prank(ALICE);
        uint256 id = governance.propose(
            AdaptiveGovernance.ProposalType.SET_TWAP_WINDOW,
            600, 0, 0, "test proposal"
        );

        vm.roll(block.number + governance.votingDelay() + 1);
        vm.prank(BOB);
        governance.castVote(id, true);

        vm.roll(block.number + governance.votingPeriod() + 1);
        assertEq(
            uint256(governance.getProposalState(id)),
            uint256(AdaptiveGovernance.ProposalState.Succeeded)
        );

        governance.executeProposal(id);

        skip(governance.timelockDelay() + 1);
        governance.executeTimelock(id);

        assertEq(governance.getParams().twapWindow, 600, "twapWindow should be 600");
    }

    // 测试主网环境下激励合约完整流程：再平衡盈利→获得奖励→冷却期→领取奖励→各种revert场景
    function test_Fork_Incentives_RebalanceReward() public {
        _deposit(ALICE, 20 ether, 40_000e6);

        vault.rebalance();

        uint256 rewardBefore = incentives.pendingReward(address(this));
        uint256 rewardPoolBefore = usdc.balanceOf(address(incentives));
        uint256 totalRewardsPaidBefore = incentives.totalRewardsPaid();
        uint256 lastRebalanceTimeBefore = incentives.lastRebalanceTime();

        uint256 totalValueBefore = 100_000e6;
        uint256 totalValueAfter = 101_000e6;
        uint256 expectedProfit = totalValueAfter - totalValueBefore;
        uint256 expectedReward = expectedProfit * incentives.incentiveBps() / 10000;

        assertGt(expectedProfit, incentives.minProfitThreshold(), "profit should exceed min threshold");

        if (lastRebalanceTimeBefore > 0) {
            skip(incentives.cooldownPeriod() + 1);
        }

        vm.prank(address(vault));
        uint256 actualReward = incentives.onRebalanceExecuted(address(this), totalValueBefore, totalValueAfter);

        assertEq(actualReward, expectedReward, "reward should be 5% of profit");

        uint256 rewardAfter = incentives.pendingReward(address(this));
        assertEq(rewardAfter - rewardBefore, expectedReward, "pending reward should increase by expected reward");

        assertEq(incentives.totalRewardsPaid(), totalRewardsPaidBefore + expectedReward, "totalRewardsPaid should increase");

        assertGt(incentives.lastRebalanceTime(), lastRebalanceTimeBefore, "lastRebalanceTime should be updated");

        assertFalse(incentives.canRebalance(), "should be in cooldown after rebalance");

        vm.prank(address(vault));
        vm.expectRevert("Incentives: cooldown active");
        incentives.onRebalanceExecuted(address(this), totalValueBefore, totalValueAfter);

        skip(incentives.cooldownPeriod() + 1);
        uint256 usdcBeforeClaim = usdc.balanceOf(address(this));
        incentives.claimReward();
        uint256 usdcAfterClaim = usdc.balanceOf(address(this));

        assertGt(usdcAfterClaim, usdcBeforeClaim, "should receive reward after claim");
        assertEq(usdcAfterClaim - usdcBeforeClaim, expectedReward, "received amount should match earned reward");

        assertEq(incentives.pendingReward(address(this)), 0, "pending reward should be 0 after claim");

        uint256 rewardPoolAfter = usdc.balanceOf(address(incentives));
        assertEq(rewardPoolBefore - rewardPoolAfter, expectedReward, "reward pool should decrease by claimed amount");

        vm.expectRevert("Incentives: no rewards");
        incentives.claimReward();

        uint256 smallProfitValueAfter = totalValueBefore + incentives.minProfitThreshold() / 2;

        vm.prank(address(vault));
        vm.expectRevert("Incentives: profit too small");
        incentives.onRebalanceExecuted(address(this), totalValueBefore, smallProfitValueAfter);

        uint256 lossValueAfter = totalValueBefore - 1;

        vm.prank(address(vault));
        vm.expectRevert("Incentives: not profitable");
        incentives.onRebalanceExecuted(address(this), totalValueBefore, lossValueAfter);
    }
}
