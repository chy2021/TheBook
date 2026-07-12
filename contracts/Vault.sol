// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract Vault is Ownable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    // 基础错误类型
    error ZeroAddress();
    error InvalidAmount();
    error InvalidSigner();
    error InvalidNonce();
    error ExpiredSignature();
    error InsufficientBalance();

    struct WithdrawRequest {
        address user;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
    }

    // PTC 代币地址
    IERC20 public immutable ptc;
    // 手续费接收地址
    address public immutable feeRecipient;
    // 负责签名授权提币的地址
    address public immutable signer;

    // 15% 手续费，按 10000 基准点计算
    uint256 public constant FEE_BPS = 1500;
    uint256 public constant BPS_DENOMINATOR = 10000;

    // 记录每个用户每个 nonce 是否已使用，防止重放攻击
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    // 存款与提币事件
    event PTCDeposited(address indexed sender, uint256 amount, uint256 timestamp);
    event PTCWithdrawn(address indexed user, uint256 totalAmount, uint256 userReceived, uint256 feeAmount, uint256 timestamp);

    bytes32 private constant WITHDRAW_TYPEHASH =
        keccak256("WithdrawRequest(address user,uint256 amount,uint256 nonce,uint256 deadline)");

    // 构造函数：初始化代币、手续费接收地址和签名授权地址
    constructor(address _ptc, address _feeRecipient, address _signer)
        Ownable(msg.sender)
        EIP712("PromptVault", "1")
    {
        if (_ptc == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        if (_signer == address(0)) revert ZeroAddress();

        ptc = IERC20(_ptc);
        feeRecipient = _feeRecipient;
        signer = _signer;
    }

    // 向 Vault 存入 PTC
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        ptc.safeTransferFrom(msg.sender, address(this), amount);
        emit PTCDeposited(msg.sender, amount, block.timestamp);
    }

    // 使用 EIP-712 签名进行提币，默认收取 15% 手续费
    function withdraw(uint256 amount, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
        nonReentrant
    {
        if (amount == 0) revert InvalidAmount();
        if (deadline < block.timestamp) revert ExpiredSignature();
        if (usedNonces[msg.sender][nonce]) revert InvalidNonce();
        if (ptc.balanceOf(address(this)) < amount) revert InsufficientBalance();

        // 先标记 nonce，防止重复提交
        usedNonces[msg.sender][nonce] = true;

        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(WITHDRAW_TYPEHASH, msg.sender, amount, nonce, deadline))
        );
        address recovered = ECDSA.recover(digest, signature);
        if (recovered != signer) revert InvalidSigner();

        // 计算手续费和实际到账金额
        uint256 feeAmount = amount * FEE_BPS / BPS_DENOMINATOR;
        uint256 userReceived = amount - feeAmount;

        ptc.safeTransfer(msg.sender, userReceived);
        if (feeAmount > 0) {
            ptc.safeTransfer(feeRecipient, feeAmount);
        }

        emit PTCWithdrawn(msg.sender, amount, userReceived, feeAmount, block.timestamp);
    }
}
