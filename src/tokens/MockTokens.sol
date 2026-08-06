// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockWETH
 * @notice 测试用WETH模拟代币，支持mint和deposit/withdraw
 */
contract MockWETH is ERC20 {
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    constructor() ERC20("Wrapped Ether", "WETH") {}

    /// @notice 免费mint用于测试（测试mock无权限限制）
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice 存入ETH获得WETH
    function deposit() external payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    /// @notice 销毁WETH取回ETH
    function withdraw(uint256 wad) external {
        _burn(msg.sender, wad);
        (bool success, ) = payable(msg.sender).call{value: wad}("");
        require(success, "ETH transfer failed");
        emit Withdrawal(msg.sender, wad);
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }
}

/**
 * @title MockUSDC
 * @notice 测试用USDC模拟代币，6位精度
 */
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice 免费mint用于测试（测试mock无权限限制）
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title MockERC20
 * @notice 通用测试用ERC20代币
 */
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
    {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
