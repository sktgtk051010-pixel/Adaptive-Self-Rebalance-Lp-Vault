// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGovernance} from "../interfaces/ICoreInterfaces.sol";

/**
 * @title GovernanceToken
 * @notice 治理代币，金库份额持有者可获得
 */
contract GovernanceToken is ERC20 {
    address public minter;

    constructor() ERC20("Adaptive LP Governance", "ALP-GOV") {
        minter = msg.sender;
    }

    modifier onlyMinter() {
        require(msg.sender == minter, "GovToken: not minter");
        _;
    }

    function setMinter(address _minter) external {
        require(msg.sender == minter, "GovToken: not minter");
        minter = _minter;
    }

    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyMinter {
        _burn(from, amount);
    }
}

/**
 * @title AdaptiveGovernance
 * @notice 链上治理模块（Variation 3）
 * @dev 治理代币持有者可提案、投票修改策略参数
 */
contract AdaptiveGovernance is IGovernance, ReentrancyGuard, Ownable {
    /// @notice 治理代币
    GovernanceToken public immutable GOV_TOKEN;

    /// @notice 金库地址
    address public vault;

    /// @notice 策略参数
    StrategyParams public params;

    /// @notice 提案状态
    enum ProposalState {
        Pending,    // 等待投票开始
        Active,     // 投票中
        Succeeded,  // 通过
        Executed,   // 已执行
        Defeated,   // 未通过
        Canceled    // 取消
    }

    /// @notice 提案类型
    enum ProposalType {
        SET_TWAP_WINDOW,
        SET_REBALANCE_THRESHOLD,
        SET_INCENTIVE_BPS,
        SET_MAX_SLIPPAGE,
        SET_WEIGHT_CAPS,
        SET_RANGE_BPS
    }

    /// @notice 提案结构
    struct Proposal {
        uint256 id;
        address proposer;
        ProposalType pType;
        uint256 newValue;      // 单值参数
        uint256 newValue2;     // 第二值（用于权重等多值参数）
        uint256 newValue3;     // 第三值
        uint256 startBlock;
        uint256 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        bool canceled;
        mapping(address => bool) hasVoted;
    }

    /// @notice 提案计数
    uint256 public proposalCount;

    /// @notice 提案映射
    mapping(uint256 => Proposal) public proposals;

    /// @notice 投票延迟（区块数）
    uint256 public votingDelay = 1;  // ~12秒

    /// @notice 投票周期（区块数）
    uint256 public votingPeriod = 28800;  // ~4天 (按12秒/块)

    /// @notice 提案门槛（治理代币数量）
    uint256 public proposalThreshold = 1000e18;  // 1000枚

    /// @notice 法定人数（需要的投票数）
    uint256 public quorumVotes = 10000e18;  // 10000枚

    /// @notice 时间锁延迟（秒）
    uint256 public timelockDelay = 172800;  // 48小时

    /// @notice 待执行操作
    struct TimelockAction {
        uint256 readyTime;
        ProposalType pType;
        uint256 v1;
        uint256 v2;
        uint256 v3;
    }
    mapping(uint256 => TimelockAction) public timelockActions;

    event ProposalCreated(
        uint256 indexed id,
        address indexed proposer,
        ProposalType pType,
        uint256 newValue
    );
    event VoteCast(address indexed voter, uint256 indexed proposalId, bool support, uint256 votes);
    event ProposalExecuted(uint256 indexed id);
    event ProposalCanceled(uint256 indexed id);
    event ParamsUpdated(StrategyParams newParams);

    constructor(address _govToken) Ownable(msg.sender) {
        GOV_TOKEN = GovernanceToken(_govToken);

        // 默认参数
        params = StrategyParams({
            twapWindow: 1800,           // 30分钟
            rebalanceThreshold: 500,    // 5%
            incentiveBps: 500,          // 5%
            maxSlippageBps: 100,        // 1%
            v2WeightCap: 6000,          // 60%
            v3LowFeeWeightCap: 5000,    // 50%
            v3HighFeeWeightCap: 7000,   // 70%
            tightRangeBps: 200,         // ±2%
            mediumRangeBps: 1000,       // ±10%
            wideRangeBps: 3000          // ±30%
        });
    }

    /// @notice 设置金库地址
    function setVault(address _vault) external onlyOwner {
        vault = _vault;
    }

    // ============ 提案逻辑 ============

    /// @notice 创建提案
    function propose(
        ProposalType pType,
        uint256 newValue,
        uint256 newValue2,
        uint256 newValue3,
        string calldata /* description */
    ) external returns (uint256) {
        require(
            GOV_TOKEN.balanceOf(msg.sender) >= proposalThreshold,
            "Governance: below proposal threshold"
        );

        uint256 id = ++proposalCount;
        Proposal storage p = proposals[id];
        p.id = id;
        p.proposer = msg.sender;
        p.pType = pType;
        p.newValue = newValue;
        p.newValue2 = newValue2;
        p.newValue3 = newValue3;
        p.startBlock = block.number + votingDelay;
        p.endBlock = p.startBlock + votingPeriod;

        emit ProposalCreated(id, msg.sender, pType, newValue);
        return id;
    }

    /// @notice 投票
    function castVote(uint256 proposalId, bool support) external {
        Proposal storage p = proposals[proposalId];
        require(p.id != 0, "Governance: proposal not found");
        require(block.number >= p.startBlock && block.number <= p.endBlock, "Governance: not active");
        require(!p.hasVoted[msg.sender], "Governance: already voted");

        uint256 votes = GOV_TOKEN.balanceOf(msg.sender);
        require(votes > 0, "Governance: no voting power");

        p.hasVoted[msg.sender] = true;
        if (support) {
            p.forVotes += votes;
        } else {
            p.againstVotes += votes;
        }

        emit VoteCast(msg.sender, proposalId, support, votes);
    }

    /// @notice 查询提案状态
    function getProposalState(uint256 proposalId) public view returns (ProposalState) {
        Proposal storage p = proposals[proposalId];
        require(p.id != 0, "Governance: proposal not found");

        if (p.canceled) return ProposalState.Canceled;
        if (p.executed) return ProposalState.Executed;
        if (block.number <= p.startBlock) return ProposalState.Pending;
        if (block.number <= p.endBlock) return ProposalState.Active;
        if (p.forVotes >= quorumVotes && p.forVotes > p.againstVotes) {
            return ProposalState.Succeeded;
        }
        return ProposalState.Defeated;
    }

    /// @notice 执行提案（通过后）
    function executeProposal(uint256 proposalId) external nonReentrant {
        require(getProposalState(proposalId) == ProposalState.Succeeded, "Governance: not succeeded");

        Proposal storage p = proposals[proposalId];
        p.executed = true;

        // 加入时间锁
        timelockActions[proposalId] = TimelockAction({
            readyTime: block.timestamp + timelockDelay,
            pType: p.pType,
            v1: p.newValue,
            v2: p.newValue2,
            v3: p.newValue3
        });

        emit ProposalExecuted(proposalId);
    }

    /// @notice 执行时间锁操作
    function executeTimelock(uint256 proposalId) external nonReentrant {
        TimelockAction storage action = timelockActions[proposalId];
        require(action.readyTime > 0, "Governance: no timelock");
        require(block.timestamp >= action.readyTime, "Governance: timelock not ready");

        _applyParam(action.pType, action.v1, action.v2, action.v3);
        delete timelockActions[proposalId];

        emit ParamsUpdated(params);
    }

    /// @notice 取消提案
    function cancelProposal(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        require(msg.sender == p.proposer || msg.sender == owner(), "Governance: not authorized");
        p.canceled = true;
        emit ProposalCanceled(proposalId);
    }

    // ============ 参数访问 ============

    function getParams() external view override returns (StrategyParams memory) {
        return params;
    }

    function setTWAPWindow(uint32 window) external override onlyOwner {
        params.twapWindow = window;
        emit ParamsUpdated(params);
    }

    function setRebalanceThreshold(uint256 threshold) external override onlyOwner {
        params.rebalanceThreshold = threshold;
        emit ParamsUpdated(params);
    }

    function setIncentiveBps(uint256 bps) external override onlyOwner {
        params.incentiveBps = bps;
        emit ParamsUpdated(params);
    }

    function setMaxSlippageBps(uint256 bps) external override onlyOwner {
        params.maxSlippageBps = bps;
        emit ParamsUpdated(params);
    }

    function setWeightCaps(uint256 v2, uint256 v3Low, uint256 v3High) external override onlyOwner {
        params.v2WeightCap = v2;
        params.v3LowFeeWeightCap = v3Low;
        params.v3HighFeeWeightCap = v3High;
        emit ParamsUpdated(params);
    }

    function setRangeBps(uint256 tight, uint256 medium, uint256 wide) external override onlyOwner {
        params.tightRangeBps = tight;
        params.mediumRangeBps = medium;
        params.wideRangeBps = wide;
        emit ParamsUpdated(params);
    }

    // ============ 内部函数 ============

    function _applyParam(ProposalType pType, uint256 v1, uint256 v2, uint256 v3) internal {
        if (pType == ProposalType.SET_TWAP_WINDOW) {
            params.twapWindow = uint32(v1);
        } else if (pType == ProposalType.SET_REBALANCE_THRESHOLD) {
            params.rebalanceThreshold = v1;
        } else if (pType == ProposalType.SET_INCENTIVE_BPS) {
            params.incentiveBps = v1;
        } else if (pType == ProposalType.SET_MAX_SLIPPAGE) {
            params.maxSlippageBps = v1;
        } else if (pType == ProposalType.SET_WEIGHT_CAPS) {
            params.v2WeightCap = v1;
            params.v3LowFeeWeightCap = v2;
            params.v3HighFeeWeightCap = v3;
        } else if (pType == ProposalType.SET_RANGE_BPS) {
            params.tightRangeBps = v1;
            params.mediumRangeBps = v2;
            params.wideRangeBps = v3;
        }
    }
}
