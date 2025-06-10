// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// PromptCoin Contract
contract PromptCoin is ERC20, Ownable {
    constructor() ERC20("PromptCoin", "PTC") {
        _mint(msg.sender, 33_000_000 * 1e18);
    }
}