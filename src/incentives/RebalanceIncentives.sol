// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FullMath} from "../libraries/UniswapMath.sol";

/**
 * @title RebalanceIncentives
 * @notice 再平衡执行者激励机制：USDC + ALP 双奖励
 */
contract RebalanceIncentives is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ============ 不可变状态 ============
    address public immutable VAULT;
    IERC20 public immutable REWARD_TOKEN;   // USDC
    IERC20 public immutable ALP_TOKEN;      // ALP 治理币

    // ============ 可变状态 ============
    uint256 public incentiveBps;            // USDC 奖励比例（利润的百分比）
    uint256 public minProfitThreshold;      // 最小利润门槛
    uint256 public cooldownPeriod;          // 冷却期
    uint256 public alpRewardPerRebalance;   // 每次再平衡的 ALP 奖励
    uint256 public lastRebalanceTime;
    uint256 public totalRewardsPaid;

    mapping(address => uint256) public rewardsEarned;       // USDC 待领
    mapping(address => uint256) public alpRewardsEarned;    // ALP 待领

    // ============ 常量 ============
    uint256 public constant DEFAULT_INCENTIVE_BPS = 500;     // 默认 5%
    uint256 public constant DEFAULT_MIN_PROFIT = 1e6;        // 1 USDC
    uint256 public constant DEFAULT_COOLDOWN = 300;          // 5分钟
    uint256 public constant DEFAULT_ALP_REWARD = 10e18;      // 每次 10 ALP
    uint256 public constant MAX_INCENTIVE_BPS = 2000;        // 最大 20%
    uint256 public constant MAX_ALP_REWARD = 1000e18;       // 最大每次 1000 ALP

    // ============ 事件 ============
    event RebalanceExecuted(
        address indexed executor,
        uint256 profitBefore,
        uint256 profitAfter,
        uint256 usdcReward,
        uint256 alpReward
    );
    event IncentiveParamsUpdated(uint256 oldBps, uint256 newBps);
    event CooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event AlpRewardUpdated(uint256 oldReward, uint256 newReward);
    event RewardClaimed(address indexed user, uint256 usdcAmount, uint256 alpAmount);

    // ============ modifier ============
    modifier onlyVault() {
        require(msg.sender == VAULT, "Incentives: not vault");
        _;
    }

    constructor(
        address _vault,
        address _rewardToken,
        address _alpToken
    ) Ownable(msg.sender) {
        require(_vault != address(0), "Incentives: zero vault");
        require(_rewardToken != address(0), "Incentives: zero token");
        require(_alpToken != address(0), "Incentives: zero alp token");

        VAULT = _vault;
        REWARD_TOKEN = IERC20(_rewardToken);
        ALP_TOKEN = IERC20(_alpToken);

        incentiveBps = DEFAULT_INCENTIVE_BPS;
        minProfitThreshold = DEFAULT_MIN_PROFIT;
        cooldownPeriod = DEFAULT_COOLDOWN;
        alpRewardPerRebalance = DEFAULT_ALP_REWARD;
    }

    /**
     * @notice 记录再平衡执行并计算奖励（USDC + ALP）
     * @param executor 执行者地址
     * @param totalValueBefore 再平衡前金库总价值（USDC计价）
     * @param totalValueAfter 再平衡后金库总价值（USDC计价）
     */
    function onRebalanceExecuted(
        address executor,
        uint256 totalValueBefore,
        uint256 totalValueAfter
    ) external onlyVault nonReentrant returns (uint256 reward) {
        if (lastRebalanceTime != 0) {
            require(
                block.timestamp >= lastRebalanceTime + cooldownPeriod,
                "Incentives: cooldown active"
            );
        }

        require(totalValueAfter > totalValueBefore, "Incentives: not profitable");
        uint256 profit = totalValueAfter - totalValueBefore;
        require(profit >= minProfitThreshold, "Incentives: profit too small");

        // USDC 奖励：利润的 incentiveBps%
        uint256 usdcReward = FullMath.mulDiv(profit, incentiveBps, 10000);
        uint256 availableUsdc = REWARD_TOKEN.balanceOf(address(this));
        if (usdcReward > availableUsdc) {
            usdcReward = availableUsdc;
        }
        if (usdcReward > 0) {
            rewardsEarned[executor] += usdcReward;
            totalRewardsPaid += usdcReward;
        }

        // ALP 奖励：每次固定数量
        uint256 alpReward = alpRewardPerRebalance;
        uint256 availableAlp = ALP_TOKEN.balanceOf(address(this));
        if (alpReward > availableAlp) {
            alpReward = availableAlp;
        }
        if (alpReward > 0) {
            alpRewardsEarned[executor] += alpReward;
        }

        lastRebalanceTime = block.timestamp;

        emit RebalanceExecuted(executor, totalValueBefore, totalValueAfter, usdcReward, alpReward);

        return usdcReward;
    }

    /// @notice 执行者领取奖励（USDC + ALP 一起领）
    function claimReward() external nonReentrant {
        uint256 usdcAmount = rewardsEarned[msg.sender];
        uint256 alpAmount = alpRewardsEarned[msg.sender];
        require(usdcAmount > 0 || alpAmount > 0, "Incentives: no rewards");

        rewardsEarned[msg.sender] = 0;
        alpRewardsEarned[msg.sender] = 0;

        if (usdcAmount > 0) {
            REWARD_TOKEN.safeTransfer(msg.sender, usdcAmount);
        }
        if (alpAmount > 0) {
            ALP_TOKEN.safeTransfer(msg.sender, alpAmount);
        }

        emit RewardClaimed(msg.sender, usdcAmount, alpAmount);
    }

    /**
     * @notice 查询待领取 USDC 奖励
     */
    function pendingReward(address user) external view returns (uint256) {
        return rewardsEarned[user];
    }

    /**
     * @notice 查询待领取 ALP 奖励
     */
    function pendingAlpReward(address user) external view returns (uint256) {
        return alpRewardsEarned[user];
    }

    /// @notice 检查是否可以执行再平衡
    function canRebalance() external view returns (bool) {
        if (lastRebalanceTime == 0) return true;
        return block.timestamp >= lastRebalanceTime + cooldownPeriod;
    }

    /**
     * @notice 注入 USDC 奖励资金
     */
    function fundRewards(uint256 amount) external {
        require(amount > 0, "Incentives: zero amount");
        REWARD_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice 注入 ALP 奖励资金
     */
    function fundAlpRewards(uint256 amount) external {
        require(amount > 0, "Incentives: zero amount");
        ALP_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
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

    function setAlpRewardPerRebalance(uint256 _reward) external onlyOwner {
        require(_reward <= MAX_ALP_REWARD, "Incentives: alp reward too high");
        emit AlpRewardUpdated(alpRewardPerRebalance, _reward);
        alpRewardPerRebalance = _reward;
    }
}
