// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Treasury - 国库合约
 * @notice 管理协议国库资金，所有支出必须通过治理提案执行
 */
contract Treasury is Ownable {
    using SafeERC20 for IERC20;

    // ============ 数据结构 ============

    /**
     * @notice 支出记录
     * @param token 支出的代币地址
     * @param to 接收方地址
     * @param amount 支出金额
     * @param reason 支出原因
     * @param timestamp 支出时间戳
     */
    struct Spending {
        address token;
        address to;
        uint256 amount;
        string reason;
        uint256 timestamp;
    }

    // ============ 状态变量 ============

    /// @notice 所有支出记录
    Spending[] public spendings;

    // ============ 事件 ============

    /**
     * @notice 支出事件
     * @param token 支出的代币地址
     * @param to 接收方地址
     * @param amount 支出金额
     * @param reason 支出原因
     */
    event FundsSpent(address indexed token, address indexed to, uint256 amount, string reason);

    // ============ 构造函数 ============

    /**
     * @notice 构造函数
     * @dev 部署者为初始 owner，部署后调用 transferOwnership 转移给治理合约
     */
    constructor() Ownable(msg.sender) {}

    // ============ 核心函数 ============

    /**
     * @notice 支出资金（只有治理合约能调用）
     * @param token 支出的代币地址
     * @param to 接收方地址
     * @param amount 支出金额
     * @param reason 支出原因
     */
    function spend(address token, address to, uint256 amount, string memory reason) external onlyOwner {
        require(to != address(0), "Treasury: zero address");
        require(amount > 0, "Treasury: zero amount");

        IERC20(token).safeTransfer(to, amount);
        spendings.push(Spending(token, to, amount, reason, block.timestamp));

        emit FundsSpent(token, to, amount, reason);
    }

    // ============ 查询函数 ============

    /**
     * @notice 查询国库中某代币的余额
     * @param token 代币地址
     * @return 余额
     */
    function balanceOf(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /**
     * @notice 查询支出记录总数
     * @return 记录数量
     */
    function getSpendingCount() external view returns (uint256) {
        return spendings.length;
    }

    /**
     * @notice 查询某条支出记录
     * @param index 记录索引
     * @return token 支出的代币地址
     * @return to 接收方地址
     * @return amount 支出金额
     * @return reason 支出原因
     * @return timestamp 支出时间戳
     */
    function getSpending(uint256 index) external view returns (
        address token,
        address to,
        uint256 amount,
        string memory reason,
        uint256 timestamp
    ) {
        require(index < spendings.length, "Treasury: index out of bounds");
        Spending memory spendEvent = spendings[index];
        return (spendEvent.token, spendEvent.to, spendEvent.amount, spendEvent.reason, spendEvent.timestamp);
    }
}

