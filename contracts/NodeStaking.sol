// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract NodeStaking is Ownable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    // 基础错误类型
    error ZeroAddress();
    error AlreadyStaked();
    error StakeNotReady();
    error TokenNotStaked();
    error NotStakeOwner();
    error AlreadyMarked();
    error NoTokenIds();

    // 用户质押信息结构体
    struct StakeInfo {
        uint256 tokenId;
        uint256 unlockTime;
    }

    // PTC 代币、NFT 合约以及 Vault 地址
    IERC20 public immutable ptc;
    IERC721 public immutable nft;
    address public vault;
    address public immutable feeRecipient;

    // 质押所需的 PTC 数量与锁仓时长
    uint256 public constant STAKE_AMOUNT = 10_000 * 1e18;
    uint256 public constant STAKE_DURATION = 365 days;

    // 用户的活跃质押记录
    mapping(address => StakeInfo[]) private _stakes;
    mapping(address => mapping(uint256 => uint256)) private _stakeIndex;
    // NFT 质押归属与解锁时间
    mapping(uint256 => address) public nftOwner;
    mapping(uint256 => uint256) public stakeUnlockTime;
    // NFT 是否已经被标记为已质押
    mapping(uint256 => bool) public hasBeenStaked;
    // NFT tokenId 白名单，白名单内的 tokenId 可免除 PTC 质押门槛
    mapping(uint256 => bool) public whitelistedTokenIds;

    event NodeStaked(address indexed user, uint256 indexed tokenId, uint256 startTime, uint256 endTime);
    event NodeUnstaked(address indexed user, uint256 indexed tokenId, uint256 timestamp);
    event WhitelistSet(uint256 indexed tokenId, bool enabled);
    event VaultUpdated(address indexed oldVault, address indexed newVault);

    // 构造函数：初始化 PTC、NFT、Vault 和手续费接收地址
    constructor(address _ptc, address _nft, address _vault, address _feeRecipient) Ownable(msg.sender) {
        if (_ptc == address(0)) revert ZeroAddress();
        if (_nft == address(0)) revert ZeroAddress();
        if (_vault == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();

        ptc = IERC20(_ptc);
        nft = IERC721(_nft);
        vault = _vault;
        feeRecipient = _feeRecipient;
    }

    // 设置 NFT tokenId 白名单，允许特定 tokenId 免除 PTC 质押
    function setWhitelistedTokenId(uint256 tokenId, bool enabled) external onlyOwner {
        whitelistedTokenIds[tokenId] = enabled;
        emit WhitelistSet(tokenId, enabled);
    }

    // 动态更新 Vault 地址，便于后续切换或升级
    function setVault(address _vault) external onlyOwner {
        if (_vault == address(0)) revert ZeroAddress();
        address oldVault = vault;
        vault = _vault;
        emit VaultUpdated(oldVault, _vault);
    }

    // 单个 NFT 质押
    function stake(uint256 tokenId) external nonReentrant {
        _stake(tokenId);
    }

    // 批量 NFT 质押
    function stakeBatch(uint256[] calldata tokenIds) external nonReentrant {
        if (tokenIds.length == 0) revert NoTokenIds();
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _stake(tokenIds[i]);
        }
    }

    // 在锁仓期结束后赎回 NFT
    function unstake(uint256 tokenId) external nonReentrant {
        if (nftOwner[tokenId] != msg.sender) revert NotStakeOwner();
        uint256 unlockTime = stakeUnlockTime[tokenId];
        if (block.timestamp < unlockTime) revert StakeNotReady();

        _removeStake(msg.sender, tokenId);
        nft.safeTransferFrom(address(this), msg.sender, tokenId);
        emit NodeUnstaked(msg.sender, tokenId, block.timestamp);
    }

    // 查询用户当前所有活跃质押信息
    function getActiveStakes(address user) external view returns (uint256[] memory tokenIds, uint256[] memory unlockTimes) {
        StakeInfo[] storage stakes = _stakes[user];
        tokenIds = new uint256[](stakes.length);
        unlockTimes = new uint256[](stakes.length);
        for (uint256 i = 0; i < stakes.length; i++) {
            tokenIds[i] = stakes[i].tokenId;
            unlockTimes[i] = stakes[i].unlockTime;
        }
        return (tokenIds, unlockTimes);
    }

    function isStakedMarked(uint256 tokenId) external view returns (bool) {
        return hasBeenStaked[tokenId];
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // 内部质押逻辑
    function _stake(uint256 tokenId) internal {
        if (nftOwner[tokenId] != address(0)) revert AlreadyStaked();
        if (hasBeenStaked[tokenId]) revert AlreadyMarked();

        // 只有不在 tokenId 白名单中的 NFT 需要转入 Vault 的 PTC 质押金额
        if (!whitelistedTokenIds[tokenId]) {
            ptc.safeTransferFrom(msg.sender, vault, STAKE_AMOUNT);
        }

        nft.safeTransferFrom(msg.sender, address(this), tokenId);

        // 设定 365 天锁仓期
        uint256 unlockTime = block.timestamp + STAKE_DURATION;
        _pushStake(msg.sender, tokenId, unlockTime);
        nftOwner[tokenId] = msg.sender;
        stakeUnlockTime[tokenId] = unlockTime;
        hasBeenStaked[tokenId] = true;

        emit NodeStaked(msg.sender, tokenId, block.timestamp, unlockTime);
    }

    function _pushStake(address user, uint256 tokenId, uint256 unlockTime) internal {
        StakeInfo[] storage stakes = _stakes[user];
        _stakeIndex[user][tokenId] = stakes.length + 1;
        stakes.push(StakeInfo({ tokenId: tokenId, unlockTime: unlockTime }));
    }

    function _removeStake(address user, uint256 tokenId) internal {
        uint256 idxPlus = _stakeIndex[user][tokenId];
        if (idxPlus == 0) revert TokenNotStaked();
        uint256 idx = idxPlus - 1;
        StakeInfo[] storage stakes = _stakes[user];
        uint256 last = stakes.length - 1;
        if (idx != last) {
            StakeInfo memory lastStake = stakes[last];
            stakes[idx] = lastStake;
            _stakeIndex[user][lastStake.tokenId] = idx + 1;
        }
        stakes.pop();
        delete _stakeIndex[user][tokenId];
        delete nftOwner[tokenId];
        delete stakeUnlockTime[tokenId];
    }
}
