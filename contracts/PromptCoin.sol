// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// PromptCoin Contract
// 总发行量: 100亿 (10,000,000,000) PTC
contract PromptCoin is ERC20, Ownable {
    constructor() ERC20("PromptCoin", "PTC"){
        // mint total supply = 10,000,000,000 * 10^18
        _mint(msg.sender, 10_000_000_000 * 1e18);
    }
}