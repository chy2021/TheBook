// SPDX-License-Identifier: MIT
// PromptStaking.sol
// NFT质押合约
//
// 支持三种NFT（Memory、Prompt、Memes），按权重分配PTC奖励。
// 权重：Prompt=50，Memory=1，Memes=2500。
// 产出速率:初始速率每10分钟产出160个PTC，按秒产出。
// 减半周期:每两年产出速率减半。
// 奖励采用全局积分累加器模型，周期产出+周期内线性插值，近似连续产出。
// 支持质押/解押/领取奖励单个或批量操作，支持随时领取全部或部分奖励。
// 支持批量质押和解押NFT，支持同类型和不同类型的批量操作。
// 支持救援功能，允许合约所有者提取误转入的ERC20代币、ETH和非质押NFT。

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

using SafeERC20 for IERC20;

/// @title PromptStaking
/// @author Thebook
contract PromptStaking is Ownable, ReentrancyGuard, Pausable, ERC721Holder {
    // -------------------- 质押结构体 --------------------
    /// @notice 用户单个NFT质押信息
    struct StakeInfo {
        address nft;        // NFT合约地址
        uint256 tokenId;    // NFT编号
        uint256 stakedAt;   // 质押时间戳
    }

    /// @notice 用户质押及奖励信息
    struct UserInfo {
        StakeInfo[] stakes;     // 用户所有质押NFT
        uint256 weight;         // 当前总权重
        uint256 rewardDebt;     // 上次操作时的accRewardPerWeight * weight
        uint256 pendingReward;  // 待领取奖励
        uint256 claimed;        // 累计已领取奖励
    }

    /// @notice 用户质押信息
    mapping(address => UserInfo) public users;

    /// @notice 质押反向索引，记录每个NFT(tokenId)当前质押所属用户
    mapping(address => mapping(uint256 => address)) public nftOwners;

    // -------------------- 合约参数 --------------------
    IERC20 public immutable ptc;           // PTC代币合约
    address public immutable memoryNFT;    // Memory NFT合约地址
    address public immutable promptNFT;    // Prompt NFT合约地址
    address public immutable memesNFT;     // Memes NFT合约地址

    uint256 public constant PERIOD_DURATION = 600;           // 初始奖励速率：时长(10分钟)
    uint256 public constant INITIAL_REWARD = 160 ether;      // 初始奖励速率：额度(160PTC)
    uint256 public constant HALVING_INTERVAL = 2 * 365 days; // 每两年速率减半
    uint256 public constant PRODUCTION_DURATION = 364896000; // 总产出时长364896000秒

    uint256 public startRewardTimestamp; // 奖励产出起始时间
    uint256 public endRewardTimestamp;   // 奖励产出结束时间

    uint256 public accRewardPerWeight;   // 全局积分累加器（1e18精度）
    uint256 public lastRewardTimestamp;  // 上次奖励计算时间戳
    uint256 public totalWeight;          // 全局总权重（所有用户权重之和）

    // -------------------- 手续费参数 --------------------
    address public feeRecipient; // 手续费接收地址
    uint256 public feeRate;      // 手续费率，单位1e4（100=1%）
    uint256 public pendingFee;   // 累计未提取手续费

    address public pendingFeeRecipient; // 待变更的手续费接收地址
    uint256 public pendingFeeRate;      // 待变更的手续费率
    uint256 public feeRateChangeTime;   // 手续费变更时间锁
    uint256 public constant FEE_CHANGE_DELAY = 1 days;// 手续费变更时间锁延迟（1天）

    // -------------------- 事件定义 --------------------
    event Staked(address indexed user, address indexed nft, uint256 tokenId);
    event Unstaked(address indexed user, address indexed nft, uint256 tokenId);
    event Claimed(address indexed user, uint256 amount);
    event EmergencyUnstake(address indexed user, address indexed nft, uint256 tokenId);
    event ERC20Rescued(address indexed operator, address token, uint256 amount);
    event ERC721Rescued(address indexed operator, address nft, uint256 tokenId);
    event GASRescued(address indexed operator, uint256 amount);
    event FeeRateProposed(address indexed proposer, address newRecipient, uint256 newRate, uint256 executeTime);
    event FeeRateChanged(address indexed executor, address newRecipient, uint256 newRate);
    event FeeClaimed(address indexed recipient, uint256 amount);

    /// @notice 构造函数，初始化PTC和NFT合约地址及奖励起始时间
    /// @param _ptc PTC代币地址
    /// @param _memoryNFT Memory NFT地址
    /// @param _promptNFT Prompt NFT地址
    /// @param _memesNFT Memes NFT地址
    /// @param _startTime 奖励产出起始时间（0为立即开始）
    /// @param _feeRecipient 手续费接收地址
    constructor(
        address _ptc,
        address _memoryNFT,
        address _promptNFT,
        address _memesNFT,
        uint256 _startTime,
        address _feeRecipient
    ) Ownable(msg.sender) {
        require(_ptc != address(0), "address zero");
        require(_memoryNFT != address(0), "address zero");
        require(_promptNFT != address(0), "address zero");
        require(_memesNFT != address(0), "address zero");
        require(_feeRecipient != address(0), "address zero");

        ptc = IERC20(_ptc);
        memoryNFT = _memoryNFT;
        promptNFT = _promptNFT;
        memesNFT = _memesNFT;
        feeRecipient = _feeRecipient;
        if (_startTime == 0) {
            startRewardTimestamp = block.timestamp;
        } else {
            require(_startTime >= block.timestamp, "StartTime must be in the future");
            startRewardTimestamp = _startTime;
        }
        endRewardTimestamp = startRewardTimestamp + PRODUCTION_DURATION;
    }

    // -------------------- 辅助查询函数 ------------------
    /// @notice 获取用户所有质押NFT列表（分页）
    /// @param user 用户地址
    /// @param offset 偏移量
    /// @param limit 限制数量
    /// @return stakes 用户所有质押NFT StakeInfo[]
    function getStakedNFTs(address user, uint256 offset, uint256 limit) external view returns (StakeInfo[] memory stakes) {
        uint256 total = users[user].stakes.length;
        if (offset >= total) return new StakeInfo[](0);
        if (offset + limit > total) limit = total - offset;
        if (offset == 0 && limit == total) {
            return users[user].stakes;
        } else {
            stakes = new StakeInfo[](limit);
            for (uint256 i = 0; i < limit; i++) {
                stakes[i] = users[user].stakes[offset + i];
            }
            return stakes;
        }
    }

    /// @notice 获取用户质押nft总数量
    function getStakedNFTsCount(address user) external view returns (uint256) {
        return users[user].stakes.length;
    }

    /// @notice 获取质押中的nft的所属用户
    function getStakedNFTOwner(address nft, uint256 tokenId) external view returns (address) {
        return nftOwners[nft][tokenId];
    }

    // -------------------- 核心函数 --------------------
    /// @notice 修饰符：检查NFT是否为支持的三种NFT之一
    modifier onlySupportedNFT(address nft) {
        require(nft == promptNFT || nft == memoryNFT || nft == memesNFT, "Unsupported NFT");
        _;
    }

    /// @notice 内部函数：判断NFT是否为支持的三种NFT
    function _isSupportedNFT(address nft) internal view returns (bool) {
        return nft == memoryNFT || nft == promptNFT || nft == memesNFT;
    }

    /// @notice 内部函数：获取NFT权重
    function _getWeight(address nft) internal view returns (uint256) {
        if (nft == promptNFT) return 50;      
        if (nft == memoryNFT) return 1;      
        if (nft == memesNFT) return 2500;      
        revert("Unsupported NFT");
    }

    /// @notice 更新全局奖励状态（分段累加，自动处理减半）
    function _updateGlobal() internal {
        uint256 nowTime = block.timestamp > endRewardTimestamp ? endRewardTimestamp : block.timestamp;
        if (lastRewardTimestamp == 0) lastRewardTimestamp = startRewardTimestamp;
        if (nowTime <= lastRewardTimestamp) return;
        if (totalWeight == 0) {
            lastRewardTimestamp = nowTime;
            return;
        }
        uint256 from = lastRewardTimestamp;
        uint256 to = nowTime;
        uint256 reward = 0;
        while (from < to) {
            // 当前from所在的减半区间的结束时间
            uint256 halvingIndex = (from - startRewardTimestamp) / HALVING_INTERVAL;
            uint256 halvingEnd = startRewardTimestamp + (halvingIndex + 1) * HALVING_INTERVAL;
            if (halvingEnd > to) halvingEnd = to;
            uint256 rewardPerPeriod = INITIAL_REWARD >> halvingIndex;
            uint256 duration = halvingEnd - from;
            // 直接累加这段时间的奖励
            reward += rewardPerPeriod * duration / PERIOD_DURATION;
            from = halvingEnd;
        }
        // 计算本次应收手续费
        uint256 fee = reward * feeRate / 1e4;
        pendingFee += fee;
        // 分配给用户
        accRewardPerWeight += (reward - fee) * 1e18 / totalWeight;
        lastRewardTimestamp = nowTime;
    }

    /// @notice 更新指定用户的奖励（全局积分累加器模型）
    // 该函数会在每次质押、解押和领取奖励时调用，确保用户的奖励状态是最新的
    function _updateReward(address user) internal {
        _updateGlobal();
        UserInfo storage u = users[user];
        if (u.weight > 0) {
            uint256 pending = u.weight * (accRewardPerWeight - u.rewardDebt) / 1e18;
            u.pendingReward += pending;
        }
        u.rewardDebt = accRewardPerWeight;
    }

    // ========== 质押解押相关 ==========
    /// @notice 质押单个NFT
    function stake(address nft, uint256 tokenId) external nonReentrant whenNotPaused onlySupportedNFT(nft) {
        _updateReward(msg.sender); // 更新用户奖励
        uint256 weight = _getWeight(nft); // 获取NFT的权重
        users[msg.sender].stakes.push(StakeInfo({
            nft: nft,
            tokenId: tokenId,
            stakedAt: block.timestamp // 记录质押时间戳
        }));

        users[msg.sender].weight += weight; // 更新用户权重
        totalWeight += weight; // 更新总权重

    nftOwners[nft][tokenId] = msg.sender;

        emit Staked(msg.sender, nft, tokenId); // 触发质押事件
        IERC721(nft).safeTransferFrom(msg.sender, address(this), tokenId); // 转移NFT到合约地址
    }

    /// @notice 批量质押同类型NFT
    function stakeBatch(address nft, uint256[] calldata tokenIds) external nonReentrant whenNotPaused onlySupportedNFT(nft) {
        require(tokenIds.length > 0, "No token IDs provided");
        _updateReward(msg.sender);
        uint256 weight = _getWeight(nft);
        uint256 totalAdd = weight * tokenIds.length;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            users[msg.sender].stakes.push(StakeInfo(nft, tokenId, block.timestamp));
            nftOwners[nft][tokenId] = msg.sender;
        }
        users[msg.sender].weight += totalAdd;
        totalWeight += totalAdd;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            emit Staked(msg.sender, nft, tokenIds[i]);
            IERC721(nft).safeTransferFrom(msg.sender, address(this), tokenIds[i]);
        }
    }

    /// @notice 批量质押不同类型NFT
    function stakeBatch(address[] calldata nfts, uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        require(nfts.length == tokenIds.length, "Length mismatch");
        _updateReward(msg.sender);
        uint256 totalAdd = 0;
        for (uint256 i = 0; i < nfts.length; i++) {
            address nft = nfts[i];
            require(_isSupportedNFT(nft), "Unsupported NFT");
            uint256 weight = _getWeight(nft);
            users[msg.sender].stakes.push(StakeInfo(nft, tokenIds[i], block.timestamp));
            nftOwners[nft][tokenIds[i]] = msg.sender;
            totalAdd += weight;
        }
        users[msg.sender].weight += totalAdd;
        totalWeight += totalAdd;
        
        for (uint256 i = 0; i < nfts.length; i++) {
            emit Staked(msg.sender, nfts[i], tokenIds[i]);
            IERC721(nfts[i]).safeTransferFrom(msg.sender, address(this), tokenIds[i]);
        }
    }

    /// @notice 解押单个NFT
    function unstake(address nft, uint256 tokenId) external nonReentrant whenNotPaused onlySupportedNFT(nft) {
        _updateReward(msg.sender);
        StakeInfo[] storage stakes = users[msg.sender].stakes;
        uint256 len = stakes.length;
        for (uint256 i = 0; i < len; i++) {
            if (stakes[i].nft == nft && stakes[i].tokenId == tokenId) {
                uint256 weight = _getWeight(nft);
                // 状态更新
                totalWeight -= weight;
                users[msg.sender].weight -= weight;
                if (i != len - 1) {
                    stakes[i] = stakes[len - 1];
                }
                stakes.pop();
                delete nftOwners[nft][tokenId];
                emit Unstaked(msg.sender, nft, tokenId);
                
                IERC721(nft).safeTransferFrom(address(this), msg.sender, tokenId);
                return;
            }
        }
        revert("Token ID not found in stake");
    }
    
    /// @notice 批量解押同类型NFT
    function unstakeBatch(address nft, uint256[] calldata tokenIds) external nonReentrant whenNotPaused onlySupportedNFT(nft) {
        require(tokenIds.length > 0, "No token IDs provided");
        _updateReward(msg.sender);
        StakeInfo[] storage stakes = users[msg.sender].stakes;
        for (uint256 k = 0; k < tokenIds.length; k++) {
            uint256 tokenId = tokenIds[k];
            bool found = false;
            for (uint256 i = stakes.length; i > 0; i--) {
                uint256 idx = i - 1;
                if (stakes[idx].nft == nft && stakes[idx].tokenId == tokenId) {
                    uint256 weight = _getWeight(nft);
                    totalWeight -= weight;
                    users[msg.sender].weight -= weight;
                    if (idx != stakes.length - 1) {
                        stakes[idx] = stakes[stakes.length - 1];
                    }
                    stakes.pop();
                    delete nftOwners[nft][tokenId];
                    found = true;
                    emit Unstaked(msg.sender, nft, tokenId);
                    IERC721(nft).safeTransferFrom(address(this), msg.sender, tokenId);
                    break;
                }
            }
            require(found, "Token ID not found in stake");
        }
    }

    /// @notice 解押同类型所有NFT
    // 注意：用户质押nft数量太多可能导致gas高甚至超过上限而无法执行
    function unstake(address nft) external nonReentrant whenNotPaused onlySupportedNFT(nft) {
        _updateReward(msg.sender);
        StakeInfo[] storage stakes = users[msg.sender].stakes;
        require(stakes.length > 0, "No NFT staked");
        for (uint256 i = stakes.length; i > 0; i--) {
            uint256 idx = i - 1;
            if (stakes[idx].nft == nft) {
                
                uint256 weight = _getWeight(nft);
                uint256 tid = stakes[idx].tokenId;
                totalWeight -= weight;
                users[msg.sender].weight -= weight;
                
                if (idx != stakes.length - 1) {
                    stakes[idx] = stakes[stakes.length - 1];
                }
                stakes.pop();
                delete nftOwners[nft][tid];
                
                emit Unstaked(msg.sender, nft, tid);
                IERC721(nft).safeTransferFrom(address(this), msg.sender, tid);
            }
        }
    }

    /// @notice 一键解押用户所有NFT
    /// 注意：用户质押nft数量太多可能导致gas高甚至超过上限而无法执行
    function unstakeAll() external nonReentrant whenNotPaused {
        _updateReward(msg.sender);
        StakeInfo[] storage stakes = users[msg.sender].stakes;
        require(stakes.length > 0, "No NFT staked");
        for (uint256 i = stakes.length; i > 0; i--) {
            uint256 idx = i - 1;
            uint256 weight = _getWeight(stakes[idx].nft);
            address nftAddr = stakes[idx].nft;
            uint256 tid = stakes[idx].tokenId;
            totalWeight -= weight;
            users[msg.sender].weight -= weight;
            
            if (idx != stakes.length - 1) {
                stakes[idx] = stakes[stakes.length - 1];
            }
            stakes.pop();
            delete nftOwners[nftAddr][tid];
            emit Unstaked(msg.sender, nftAddr, tid);
            IERC721(nftAddr).safeTransferFrom(address(this), msg.sender, tid);
        }
    }

    /// @notice 领取所有可领取的PTC奖励
    function claim() external nonReentrant whenNotPaused {
        _updateReward(msg.sender);
        UserInfo storage u = users[msg.sender];
        uint256 reward = u.pendingReward;
        require(reward > 0, "No claimable reward");
        require(ptc.balanceOf(address(this)) >= reward, "Insufficient balance");
        u.pendingReward = 0;
        u.claimed += reward;
        emit Claimed(msg.sender, reward);
        ptc.safeTransfer(msg.sender, reward);
    }

    /// @notice 领取指定数量的PTC奖励
    function claim(uint256 amount) external nonReentrant whenNotPaused {
        _updateReward(msg.sender); // 更新用户奖励
        UserInfo storage u = users[msg.sender];

        require(amount > 0, "Amount must be greater than zero");
        require(amount <= u.pendingReward, "Amount exceeds claimable reward");
        require(ptc.balanceOf(address(this)) >= amount, "Insufficient balance");

        u.pendingReward -= amount;
        u.claimed += amount;

        ptc.safeTransfer(msg.sender, amount); // 转移PTC到用户地址
        emit Claimed(msg.sender, amount); // 触发领取奖励事件
    }
        
    /// @notice 查询用户当前可领取的PTC奖励（包含未更新周期）
    function claimable(address user) public view returns (uint256) {
        UserInfo storage u = users[user];
        uint256 nowTime = block.timestamp > endRewardTimestamp ? endRewardTimestamp : block.timestamp;
        uint256 acc = accRewardPerWeight;
        if (nowTime > lastRewardTimestamp && totalWeight > 0) {
            uint256 from = lastRewardTimestamp;
            uint256 to = nowTime;
            uint256 reward = 0;
            while (from < to) {
                uint256 halvingIndex = (from - startRewardTimestamp) / HALVING_INTERVAL;
                uint256 halvingEnd = startRewardTimestamp + (halvingIndex + 1) * HALVING_INTERVAL;
                if (halvingEnd > to) halvingEnd = to;
                uint256 rewardPerPeriod = INITIAL_REWARD >> halvingIndex;
                uint256 duration = halvingEnd - from;
                reward += rewardPerPeriod * duration / PERIOD_DURATION;
                from = halvingEnd;
            }
            uint256 fee = reward * feeRate / 1e4;
            acc +=  (reward - fee) * 1e18 / totalWeight;
        }
        return u.pendingReward + (u.weight * (acc - u.rewardDebt) / 1e18);
    }

    /// @notice 救援合约内误转入的ERC20代币（禁止PTC）
    function rescueERC20(address token, uint256 amount) external nonReentrant onlyOwner {
        require(token != address(ptc), "Cannot rescue PTC");
        require(token != address(0), "Zero address");
        emit ERC20Rescued(msg.sender, token, amount);
        IERC20(token).safeTransfer(owner(), amount);
    }

    /// @notice 救援合约内误转入的主网币
    function rescueGAS(uint256 amount) external nonReentrant onlyOwner {
        require(amount <= address(this).balance, "Amount exceeds balance");
        emit GASRescued(msg.sender, amount);
        (bool success, ) = owner().call{value: amount}("");
        require(success, "Transfer failed");
    }

    /// @notice 救援合约内误转入的ERC721 NFT（禁止三种质押NFT）
    function rescueERC721(address nft, uint256 tokenId) external nonReentrant onlyOwner {
        require(!_isSupportedNFT(nft), "Cannot rescue staked NFT");
        require(nft != address(0), "Zero address");
        emit ERC721Rescued(msg.sender, nft, tokenId);
        IERC721(nft).safeTransferFrom(address(this), owner(), tokenId);
    }

    /// @notice 用户紧急批量解押（仅暂停时可用，不结算奖励）
    // 注意：紧急解押不会计算奖励，直接将NFT转回用户
    function emergencyUnstakeBatch(uint256 count) external nonReentrant whenPaused {
        StakeInfo[] storage stakes = users[msg.sender].stakes;
        require(stakes.length > 0, "No NFT staked");
        uint256 n = count > stakes.length ? stakes.length : count;
        for (uint256 i = 0; i < n; i++) {
            uint256 idx = stakes.length - 1;
            uint256 weight = _getWeight(stakes[idx].nft);
            address nftAddr = stakes[idx].nft;
            uint256 tid = stakes[idx].tokenId;
            totalWeight -= weight;
            users[msg.sender].weight -= weight;
            delete nftOwners[nftAddr][tid];
            stakes.pop();
            emit EmergencyUnstake(msg.sender, nftAddr, tid);
            IERC721(nftAddr).safeTransferFrom(address(this), msg.sender, tid);
        }
        users[msg.sender].rewardDebt = accRewardPerWeight;
    }

    /// @notice 平台管理员（owner）随时解押任意NFT返回至原质押用户（含结算）
    /// @dev 仅owner可调，无需用户授权，适用于特殊情况（如到期、司法、合规等）
    /// @param nft NFT合约地址
    /// @param tokenIds NFT编号列表
    function unstakeBatchPlatform(address nft, uint256[] calldata tokenIds) external nonReentrant whenNotPaused onlySupportedNFT(nft) onlyOwner {
        require(tokenIds.length > 0, "No token IDs provided");
        for (uint256 batchIdx = 0; batchIdx < tokenIds.length; batchIdx++) {
            uint256 tokenId = tokenIds[batchIdx];
            address user = nftOwners[nft][tokenId];
            require(user != address(0), "NFT not staked");
            _updateReward(user); // 先更新该用户的奖励状态
            StakeInfo[] storage stakes = users[user].stakes;
            uint256 len = stakes.length;
            for (uint256 i = 0; i < len; i++) {
                if (stakes[i].nft == nft && stakes[i].tokenId == tokenId) {
                    uint256 weight = _getWeight(nft);
                    // 状态更新
                    totalWeight -= weight;
                    users[user].weight -= weight;
                    if (i != len - 1) {
                        stakes[i] = stakes[len - 1];
                    }
                    delete nftOwners[nft][tokenId];
                    stakes.pop();
                    emit Unstaked(user, nft, tokenId);
                    IERC721(nft).safeTransferFrom(address(this), user, tokenId);
                    break;
                }
            }
        }
    }

    /// @notice 提议变更手续费接收地址和费率
    /// @dev 变更需要经过时间锁，防止恶意操作
    /// @param _rate 手续费率，单位1e4，最大10000（100%）
    /// @param _recipient 新的手续费接收地址
    function proposeFeeChange(address _recipient, uint256 _rate) external onlyOwner {
        require(_rate <= 10000, "Fee too high");
        require(_recipient != address(0), "Zero address");
        require(_recipient != feeRecipient || _rate != feeRate, "No change");
        require(_recipient != pendingFeeRecipient || _rate != pendingFeeRate,"No change");
        // 只有最后一次 propose 的参数会生效
        pendingFeeRecipient = _recipient;
        pendingFeeRate = _rate;
        feeRateChangeTime = block.timestamp + FEE_CHANGE_DELAY;
        emit FeeRateProposed(msg.sender, _recipient, _rate, feeRateChangeTime);
    }

    /// @notice 手续费变更时间锁，单位秒
    function applyFeeChange() external onlyOwner {
        require(feeRateChangeTime > 0 && block.timestamp >= feeRateChangeTime, "Not ready");
        require(pendingFeeRecipient != feeRecipient || pendingFeeRate != feeRate,"No change");
        feeRecipient = pendingFeeRecipient;
        feeRate = pendingFeeRate;
        emit FeeRateChanged(msg.sender, feeRecipient, feeRate);
        // 清空pending
        feeRateChangeTime = 0;
        pendingFeeRecipient = address(0);
        pendingFeeRate = 0;
    }

    /// @notice 手续费接收地址提取累计手续费
    function claimFee() external nonReentrant {
        require(msg.sender == feeRecipient, "Not recipient");
        uint256 amount = pendingFee;
        require(amount > 0, "No fee");
        require(ptc.balanceOf(address(this)) >= amount, "Insufficient balance");
        pendingFee = 0;
        emit FeeClaimed(msg.sender, amount); 
        ptc.safeTransfer(feeRecipient, amount);
    }

    /// @notice 合约暂停（仅owner可调）
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice 合约恢复（仅owner可调）
    function unpause() external onlyOwner {
        _unpause();
    }
}