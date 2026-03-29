// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title BatchTokenDistributor
/// @notice 专门用于批量向多个地址一次性发放 ERC20 代币的合约
contract BatchTokenDistributor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;

    event BatchDistributed(uint256 recipientCount, uint256 totalAmount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event ERC721Rescued(address indexed token, address indexed to, uint256 tokenId);

    constructor(IERC20 _token) {
        require(address(_token) != address(0), "token address is zero");
        token = _token;
    }

    /// @notice 批量按每个地址不同数量发放代币，发起人直接支付
    function batchTransfer(address payer, address[] calldata recipients, uint256[] calldata amounts) external nonReentrant {
        require(payer != address(0), "payer is zero");
        require(msg.sender == owner() || payer == msg.sender, "not authorized to use this payer");
        uint256 n = recipients.length;
        require(n > 0, "empty recipients");
        require(n == amounts.length, "length mismatch");

        uint256 total = 0;

        for (uint256 i = 0; i < n; i++) {
            address recipient = recipients[i];
            uint256 amount = amounts[i];

            require(recipient != address(0), "recipient is zero");
            require(amount > 0, "amount is zero");

            total += amount;
            token.safeTransferFrom(payer, recipient, amount);
        }

        emit BatchDistributed(n, total);
    }

    /// @notice 批量按固定数量发放代币，发起人直接支付
    function batchTransferFixedAmount(address payer, address[] calldata recipients, uint256 amount) external nonReentrant {
        require(payer != address(0), "payer is zero");
        require(msg.sender == owner() || payer == msg.sender, "not authorized to use this payer");
        uint256 n = recipients.length;
        require(n > 0, "empty recipients");
        require(amount > 0, "amount is zero");

        uint256 total = amount * n;

        for (uint256 i = 0; i < n; i++) {
            address recipient = recipients[i];
            require(recipient != address(0), "recipient is zero");
            token.safeTransferFrom(payer, recipient, amount);
        }

        emit BatchDistributed(n, total);
    }

    /// @notice 回收误转入的 ERC20 代币，可以回收主代币
    function rescueERC20(address tokenAddr, address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "recipient is zero");
        IERC20(tokenAddr).safeTransfer(to, amount);
        emit ERC20Rescued(tokenAddr, to, amount);
    }

    /// @notice 回收误转入的 ERC721 代币
    function rescueERC721(address tokenAddr, address to, uint256 tokenId) external onlyOwner nonReentrant {
        require(to != address(0), "recipient is zero");
        IERC721(tokenAddr).safeTransferFrom(address(this), to, tokenId);
        emit ERC721Rescued(tokenAddr, to, tokenId);
    }
}
