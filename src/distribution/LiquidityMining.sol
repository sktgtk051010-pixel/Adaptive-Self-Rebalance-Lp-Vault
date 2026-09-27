// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FullMath} from "../libraries/UniswapMath.sol";
import {AdaptiveGovernance} from "../governance/AdaptiveGovernance.sol";

/**
 * @title LiquidityMining
 * @notice 流动性挖矿：金库用户按份额比例获得 ALP 奖励
 */
contract LiquidityMining is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ============ 不可变状态 ============
    IERC20 public immutable REWARD_TOKEN;      // ALP 代币
    address public immutable VAULT;            // 金库地址
    AdaptiveGovernance public immutable GOVERNANCE;

    // ============ 可变状态 ============
    uint256 public rewardPerSecond;            // 每秒释放多少 ALP
    uint256 public lastUpdateTime;             // 上次更新时间
    uint256 public rewardPerShare;             // 每份额累积奖励（乘以 1e18）
    uint256 public totalShares;                 // 总份额

    mapping(address => uint256) public balanceOf;    // 用户份额
    mapping(address => uint256) public rewardDebt;   // 用户奖励记账

    // ============ 事件 ============
    event RewardDistributed(uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event BalanceUpdated(address indexed user, uint256 oldBalance, uint256 newBalance);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);

    // ============ modifier ============
    modifier onlyVault() {
        require(msg.sender == VAULT, "LiquidityMining: not vault");
        _;
    }

    constructor(
        address _rewardToken,
        address _vault,
        address _governance,
        uint256 _rewardPerSecond
    ) Ownable(msg.sender) {
        require(_rewardToken != address(0), "LiquidityMining: zero token");
        require(_vault != address(0), "LiquidityMining: zero vault");
        require(_governance != address(0), "LiquidityMining: zero governance");

        REWARD_TOKEN = IERC20(_rewardToken);
        VAULT = _vault;
        GOVERNANCE = AdaptiveGovernance(_governance);
        rewardPerSecond = _rewardPerSecond;
        lastUpdateTime = block.timestamp;
    }

    /**
     * @notice Vault 通知用户份额变化
     * @param user 用户地址
     * @param newBalance 新的份额
     */
    function updateBalance(address user, uint256 newBalance) external onlyVault {
        _distribute();

        // 结算用户之前累积的奖励
        uint256 pending = _settle(user);

        // 更新用户份额
        uint256 oldBalance = balanceOf[user];
        balanceOf[user] = newBalance;
        totalShares = totalShares - oldBalance + newBalance;

        // 用新份额重记账
        rewardDebt[user] = FullMath.mulDiv(newBalance, rewardPerShare, 1e18);

        // 如果 pending > 0，自动转给用户
        if (pending > 0) {
            REWARD_TOKEN.safeTransfer(user, pending);
            emit RewardClaimed(user, pending);
        }

        emit BalanceUpdated(user, oldBalance, newBalance);
    }

    /**
     * @notice 更新全局 rewardPerShare（任何人可调用）
     */
    function distribute() external {
        _distribute();
    }

    function _distribute() internal {
        if (block.timestamp == lastUpdateTime) return;

        uint256 newRPS = _currentRewardPerShare();
        if (newRPS > rewardPerShare && totalShares > 0) {
            uint256 delta = newRPS - rewardPerShare;
            uint256 reward = FullMath.mulDiv(delta, totalShares, 1e18);
            emit RewardDistributed(reward);
        }
        rewardPerShare = newRPS;
        lastUpdateTime = block.timestamp;
    }

    /**
     * @notice 用户领取奖励
     */
    function claimReward() external nonReentrant {
        _distribute();

        uint256 pending = _settle(msg.sender);
        require(pending > 0, "LiquidityMining: no rewards");

        REWARD_TOKEN.safeTransfer(msg.sender, pending);
        emit RewardClaimed(msg.sender, pending);
    }

    /**
     * @notice 查询待领取奖励
     * @param user 查询的用户地址
     * @return 待领取奖励数量
     */
    function pendingReward(address user) external view returns (uint256) {
        uint256 currentRPS = _currentRewardPerShare();
        return FullMath.mulDiv(balanceOf[user], currentRPS, 1e18) - rewardDebt[user];
    }

    // ============ 内部函数 ============

    /**
     * @notice 结算用户累积的奖励
     * @param user 用户地址
     * @return pending 待领取奖励数量
     */
    function _settle(address user) internal returns (uint256 pending) {
        pending = FullMath.mulDiv(balanceOf[user], rewardPerShare, 1e18) - rewardDebt[user];
        rewardDebt[user] = FullMath.mulDiv(balanceOf[user], rewardPerShare, 1e18);
    }

    /**
     * @notice 计算当前（含未结算）的 rewardPerShare
     */
    function _currentRewardPerShare() internal view returns (uint256) {
        if (totalShares == 0 || block.timestamp == lastUpdateTime) {
            return rewardPerShare;
        }
        uint256 timeDelta = block.timestamp - lastUpdateTime;
        uint256 reward = timeDelta * rewardPerSecond;
        return rewardPerShare + FullMath.mulDiv(reward, 1e18, totalShares);
    }

    // ============ 治理函数 ============

    function setRewardPerSecond(uint256 _rps) external onlyOwner {
        _distribute();
        emit RewardRateUpdated(rewardPerSecond, _rps);
        rewardPerSecond = _rps;
    }
}
