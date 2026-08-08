// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FullMath} from "../libraries/UniswapMath.sol";
import {AdaptiveGovernance} from "../governance/AdaptiveGovernance.sol";

/**
 * @title RebalanceIncentives
 * @notice 再平衡执行者激励机制（Variation 1）
 * @dev 任意外部用户/机器人可触发再平衡，系统验证正向收益后发放奖励
 */
contract RebalanceIncentives is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /// @notice 金库地址
    address public immutable VAULT;

    /// @notice 奖励代币（USDC）
    IERC20 public immutable REWARD_TOKEN;

    AdaptiveGovernance public immutable GOVERNANCE;

    /// @notice 激励比例（basis points，从金库收益中扣除）
    uint256 public incentiveBps;

    /// @notice 最小再平衡收益阈值（USDC，6位），低于此值不发奖励
    uint256 public minProfitThreshold;

    /// @notice 再平衡冷却时间（秒）
    uint256 public cooldownPeriod;

    /// @notice 上次再平衡时间
    uint256 public lastRebalanceTime;

    /// @notice 累计发放奖励
    uint256 public totalRewardsPaid;

    /// @notice 每个调用者的奖励记录
    mapping(address => uint256) public rewardsEarned;

    /// @notice 默认参数
    uint256 public constant DEFAULT_INCENTIVE_BPS = 500;     // 5%的收益作为奖励
    uint256 public constant DEFAULT_MIN_PROFIT = 1e6;        // 1 USDC
    uint256 public constant DEFAULT_COOLDOWN = 300;          // 5分钟
    uint256 public constant MAX_INCENTIVE_BPS = 2000;        // 最高20%

    event RebalanceExecuted(
        address indexed executor,
        uint256 profitBefore,
        uint256 profitAfter,
        uint256 reward
    );
    event IncentiveParamsUpdated(uint256 oldBps, uint256 newBps);
    event CooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event RewardClaimed(address indexed user, uint256 amount);

    modifier onlyVault() {
        require(msg.sender == VAULT, "Incentives: not vault");
        _;
    }

    constructor(
        address _vault,
        address _rewardToken,
        address _governance
    ) Ownable(msg.sender) {
        require(_vault != address(0), "Incentives: zero vault");
        require(_rewardToken != address(0), "Incentives: zero token");
        require(_governance != address(0), "Incentives: zero governance");

        VAULT = _vault;
        REWARD_TOKEN = IERC20(_rewardToken);
        GOVERNANCE = AdaptiveGovernance(_governance);

        incentiveBps = DEFAULT_INCENTIVE_BPS;
        minProfitThreshold = DEFAULT_MIN_PROFIT;
        cooldownPeriod = DEFAULT_COOLDOWN;
    }

    /// @notice 记录再平衡执行并计算奖励（由金库在再平衡成功后调用）
    /// @param executor 执行者地址
    /// @param totalValueBefore 再平衡前金库总价值（USDC计价）
    /// @param totalValueAfter 再平衡后金库总价值（USDC计价）
    /// @return reward 发放给执行者的奖励金额
    function onRebalanceExecuted(
        address executor,
        uint256 totalValueBefore,
        uint256 totalValueAfter
    ) external onlyVault nonReentrant returns (uint256 reward) {
        // 第一次rebalance（lastRebalanceTime==0）跳过冷却检查
        if (lastRebalanceTime != 0) {
            require(
                block.timestamp >= lastRebalanceTime + cooldownPeriod,
                "Incentives: cooldown active"
            );
        }

        // 验证再平衡为正向收益
        require(totalValueAfter > totalValueBefore, "Incentives: not profitable");
        uint256 profit = totalValueAfter - totalValueBefore;
        require(profit >= minProfitThreshold, "Incentives: profit too small");

        // 计算奖励
        reward = FullMath.mulDiv(profit, incentiveBps, 10000);

        // 检查奖励池余额
        uint256 available = REWARD_TOKEN.balanceOf(address(this));
        if (reward > available) {
            reward = available;
        }

        if (reward > 0) {
            rewardsEarned[executor] += reward;
            totalRewardsPaid += reward;
        }

        lastRebalanceTime = block.timestamp;

        emit RebalanceExecuted(executor, totalValueBefore, totalValueAfter, reward);
    }

    /// @notice 执行者领取奖励
    function claimReward() external nonReentrant {
        uint256 amount = rewardsEarned[msg.sender];
        require(amount > 0, "Incentives: no rewards");

        rewardsEarned[msg.sender] = 0;
        REWARD_TOKEN.safeTransfer(msg.sender, amount);

        emit RewardClaimed(msg.sender, amount);
    }

    /// @notice 查询待领取奖励
    function pendingReward(address user) external view returns (uint256) {
        return rewardsEarned[user];
    }

    /// @notice 检查是否可以执行再平衡
    function canRebalance() external view returns (bool) {
        if (lastRebalanceTime == 0) return true;
        return block.timestamp >= lastRebalanceTime + cooldownPeriod;
    }

    /// @notice 注入奖励资金（由金库或治理调用）
    function fundRewards(uint256 amount) external {
        require(amount > 0, "Incentives: zero amount");
        require(msg.sender == address(GOVERNANCE) || msg.sender == VAULT, "Incentives: not authorized");
        REWARD_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
    }

    // ============ 治理函数 ============

    function setIncentiveBps(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_INCENTIVE_BPS, "Incentives: too high");
        emit IncentiveParamsUpdated(incentiveBps, _bps);
        incentiveBps = _bps;
    }

    function setCooldownPeriod(uint256 _period) external onlyOwner {
        require(_period >= 60 && _period <= 86400, "Incentives: invalid cooldown");
        emit CooldownUpdated(cooldownPeriod, _period);
        cooldownPeriod = _period;
    }

    function setMinProfitThreshold(uint256 _threshold) external onlyOwner {
        emit ThresholdUpdated(minProfitThreshold, _threshold);
        minProfitThreshold = _threshold;
    }
}
