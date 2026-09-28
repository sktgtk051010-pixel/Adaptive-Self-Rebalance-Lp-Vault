// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FullMath} from "../libraries/UniswapMath.sol";

/**
 * @title TeamVesting
 * @notice 团队锁仓：1年悬崖期 + 3年线性释放
 */
contract TeamVesting is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ============ 不可变状态 ============
    IERC20 public immutable REWARD_TOKEN;      // ALP 代币
    address public immutable TEAM_WALLET;      // 团队钱包地址

    // ============ 常量 ============
    uint256 public constant CLIFF_PERIOD = 365 days;      // 1年悬崖期
    uint256 public constant VESTING_PERIOD = 1095 days;    // 3年线性释放
    uint256 public constant TOTAL_AMOUNT = 2_000_000e18;  // 总量 200万 ALP

    // ============ 可变状态 ============
    uint256 public startTime;                   // 开始时间
    uint256 public releasedAmount;               // 已领取数量

    // ============ 事件 ============
    event VestingStarted(uint256 startTime);
    event TeamClaimed(address indexed team, uint256 amount);

    constructor(
        address _rewardToken,
        address _teamWallet
    ) Ownable(msg.sender) {
        require(_rewardToken != address(0), "TeamVesting: zero token");
        require(_teamWallet != address(0), "TeamVesting: zero team wallet");

        REWARD_TOKEN = IERC20(_rewardToken);
        TEAM_WALLET = _teamWallet;
    }

    /**
     * @notice 开始锁仓（部署后调用一次）
     */
    function startVesting() external onlyOwner {
        require(startTime == 0, "TeamVesting: already started");
        startTime = block.timestamp;
        emit VestingStarted(startTime);
    }

    /**
     * @notice 团队领取已释放的 ALP
     */
    function claim() external nonReentrant {
        require(msg.sender == TEAM_WALLET, "TeamVesting: not team wallet");
        require(startTime > 0, "TeamVesting: not started");

        uint256 vested = vestedAmount();
        uint256 claimable = vested - releasedAmount;
        require(claimable > 0, "TeamVesting: nothing to claim");

        releasedAmount += claimable;
        REWARD_TOKEN.safeTransfer(TEAM_WALLET, claimable);

        emit TeamClaimed(TEAM_WALLET, claimable);
    }

    /**
     * @notice 查从开始到现在应该释放了多少
     */
    function vestedAmount() public view returns (uint256) {
        if (startTime == 0) return 0;

        uint256 cliffEnd = startTime + CLIFF_PERIOD;
        if (block.timestamp < cliffEnd) return 0;  // 悬崖期内一分不给

        uint256 vestingEnd = cliffEnd + VESTING_PERIOD;
        if (block.timestamp >= vestingEnd) return TOTAL_AMOUNT;  // 全释放完了

        // 线性释放：(现在 - 悬崖结束时间) / 线性期 × 总量
        uint256 elapsed = block.timestamp - cliffEnd;
        return FullMath.mulDiv(TOTAL_AMOUNT, elapsed, VESTING_PERIOD);
    }

    /**
     * @notice 查已经领取了多少
     */
    function released() external view returns (uint256) {
        return releasedAmount;
    }
}
