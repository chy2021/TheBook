// SPDX-License-Identifier: MIT
// PromptStaking.sol
// NFT质押合约 V4.0
//
// 支持1种NFT（Prompt），按权重分配PTC奖励。
// 质押挖矿的总数量：30亿
// 释放规则：第一年25%，第二年15%，第三年12%，第四年10%，第五年8%，从第六年开始把剩余数量按照每年释放50%逐年减半的逻辑释放。
// 奖励计算：每次计算时使用当前基数乘以（已销售NFT数量/NFT发行总数）的比例，已销售数量 = NFT发行总数 - 销售地址持有量。
// 奖励分配：用户收益 = 总释放奖励 × 销售比例，剩余部分进入缓冲池。
// 提现：管理员控制，用户不能自行提现，支持随时为用户提现全部奖励。
// 奖励采用全局积分累加器模型，近似连续产出。
// 支持质押/解押/领取奖励单个或批量操作，支持随时领取全部或部分奖励。
// 支持救援功能，允许合约所有者提取误转入的ERC20代币、ETH和非质押NFT。
// 安全性：使用OpenZeppelin库，包含重入保护和可暂停功能。管理员操作（如救援、调整参数）需要谨慎执行。
// 注意：用户质押NFT数量过多可能导致单次操作gas过高，建议分批操作。
// Author: Thebook

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

using SafeERC20 for IERC20;

/// @title PromptStaking
/// @author Thebook
contract PromptStaking is Ownable, ReentrancyGuard, Pausable, ERC721Holder {
    // -------------------- 质押结构体 --------------------
    /// @notice 用户单个NFT质押信息
    struct StakeInfo {
        uint256 tokenId;    // NFT编号
        uint256 stakedAt;   // 质押时间戳
    }

    /// @notice 用户质押及奖励信息
    struct UserInfo {
        StakeInfo[] stakes;     // 用户所有质押NFT
        uint256 rewardDebt;     // 上次操作时的accRewardPerNFT * stakeCount
        uint256 pendingReward;  // 待领取奖励
        uint256 claimed;        // 累计已领取奖励
    }

    /// @notice 用户质押信息
    mapping(address => UserInfo) public users;

    /// @notice 质押反向索引，记录每个NFT(tokenId)当前质押所属用户
    mapping(uint256 => address) public nftOwners;
    // 存储用户 stakes 数组中 tokenId 的索引加1（0 表示不存在）: stakeIndex[user][tokenId] = index+1
    mapping(address => mapping(uint256 => uint256)) public stakeIndex;

    // -------------------- 合约参数 --------------------
    IERC20 public immutable ptc;           // PTC代币合约
    address public immutable promptNFT;    // Prompt NFT合约地址

    uint256 public constant TOTAL_REWARD = 3000000000 ether; // 总奖励 30亿

    // 前5年总释放量，用于计算第6年后的剩余
    uint256 public constant RELEASED_AFTER_5_YEARS = 2100000000 ether; // 21亿
    uint256 public constant REMAINING_AFTER_5_YEARS = 900000000 ether; // 9亿
    uint256 public constant FRACTION = 5000; // 50% = 5000/10000，保持不变，第六年开始每年释放年初剩余的50%

    // 第6年后的额外注入奖励
    uint256 public additionalRewardAfter5Years;

    // Reward schedule: 前5年固定，第6年开始动态释放
    uint256 public constant SCHEDULE_PERIODS = 6;
    uint256 public constant SCHEDULE_PERIOD_DURATION = 365 days; // 1 year per period
    // Total PTC to release per period (units: wei)
    uint256[6] public schedulePeriodTotals;

    uint256 public startRewardTimestamp; // 奖励产出起始时间

    uint256 public accRewardPerWeight;   // 全局积分累加器（1e18精度）
    uint256 public lastRewardTimestamp;  // 上次奖励计算时间戳
    uint256 public totalStakeCount;      // 全局质押的NFT总数
    uint256 public totalPendingReward;   // 全局待领取奖励总量
    uint256 public totalClaimedPTC;      // 全局已发放给用户的PTC总量（不含缓冲池）

    // -------------------- 销售参数 --------------------
    uint256 public totalNFTSupply;       // NFT发行总数
    address public salesAddress;         // 销售地址

    // -------------------- 缓冲池参数 --------------------
    address public bufferPool;
    uint256 public bufferPoolReward;
    uint256 public pendingBufferWithdrawal;
    uint256 public bufferWithdrawalRequestTime;

    // -------------------- 手续费参数 --------------------
    address public feeRecipient; // 手续费接收地址

    // -------------------- 缓冲池提现延迟参数 --------------------
    uint256 public constant BUFFER_WITHDRAWAL_DELAY = 1 days; // 缓冲池提取延迟时间

    // -------------------- 销售比例保护参数 --------------------
    uint256 private lastSalesRatioUpdate; // 上次销售比例更新时间
    uint256 private cachedSalesRatio; // 缓存的销售比例（1e18精度）

    // -------------------- 紧急控制参数 --------------------
    bool public salesRatioUpdatePaused; // 销售比例更新暂停标志

    /// @notice 紧急暂停销售比例更新（防止外部合约攻击）
    function emergencyPauseSalesRatioUpdate() external onlyOwner {
        salesRatioUpdatePaused = true;
        emit SalesRatioUpdatePaused(msg.sender);
    }

    /// @notice 恢复销售比例更新
    function resumeSalesRatioUpdate() external onlyOwner {
        salesRatioUpdatePaused = false;
        emit SalesRatioUpdateResumed(msg.sender);
    }

    // -------------------- 事件定义 --------------------
    event Staked(address indexed user, uint256 indexed tokenId);
    event Unstaked(address indexed user, uint256 indexed tokenId);
    event Claimed(address indexed user, uint256 amount);
    event EmergencyUnstake(address indexed user, uint256 indexed tokenId);
    event ERC20Rescued(address indexed operator, address token, uint256 amount);
    event ERC721Rescued(address indexed operator, address nft, uint256 tokenId);
    event GASRescued(address indexed operator, uint256 amount);
    event BufferPoolWithdrawn(address indexed admin, uint256 amount);
    event BufferPoolSet(address indexed admin, address newBufferPool);
    event BufferPoolWithdrawalRequested(address indexed admin, uint256 amount, uint256 requestTime);
    event BufferPoolWithdrawalCancelled(address indexed admin);
    event SalesRatioUpdatePaused(address indexed admin);
    event SalesRatioUpdateResumed(address indexed admin);
    event AdditionalRewardAdded(address indexed admin, uint256 amount);
    
    // -------------------- 构造函数 --------------------
    /// @notice 构造函数，初始化PTC和NFT合约地址及奖励起始时间
    /// @param _ptc PTC代币地址
    /// @param _promptNFT Prompt NFT地址
    /// @param _startTime 奖励产出起始时间（0为立即开始）
    /// @param _feeRecipient 手续费接收地址
    /// @param _totalNFTSupply NFT发行总数
    /// @param _salesAddress 销售地址
    /// @param _bufferPool 缓冲池地址
    constructor(
        address _ptc,
        address _promptNFT,
        uint256 _startTime,
        address _feeRecipient,
        uint256 _totalNFTSupply,
        address _salesAddress,
        address _bufferPool
    ) Ownable(msg.sender)
    {
        require(_ptc != address(0), "address zero");
        require(_promptNFT != address(0), "address zero");
        require(_feeRecipient != address(0), "address zero");
        require(_salesAddress != address(0), "address zero");
        require(_bufferPool != address(0), "address zero");
        require(_totalNFTSupply > 0, "Invalid total NFT supply");

        ptc = IERC20(_ptc);
        promptNFT = _promptNFT;
        feeRecipient = _feeRecipient;
        totalNFTSupply = _totalNFTSupply;
        salesAddress = _salesAddress;
        bufferPool = _bufferPool;

        if (_startTime == 0) {
            startRewardTimestamp = block.timestamp;
        } else {
            require(_startTime >= block.timestamp, "StartTime must be in the future");
            startRewardTimestamp = _startTime;
        }
        // 奖励永远释放，无结束时间

        // Initialize schedule totals (单位: 亿 = 100,000,000)
        // 第一年: 25% = 7.5亿
        schedulePeriodTotals[0] = 750000000 ether;
        // 第二年: 15% = 4.5亿
        schedulePeriodTotals[1] = 450000000 ether;
        // 第三年: 12% = 3.6亿
        schedulePeriodTotals[2] = 360000000 ether;
        // 第四年: 10% = 3亿
        schedulePeriodTotals[3] = 300000000 ether;
        // 第五年: 8% = 2.4亿
        schedulePeriodTotals[4] = 240000000 ether;
        // 第六年及以后: 动态释放
        schedulePeriodTotals[5] = 0;
    }

    // -------------------- 辅助查询函数 ------------------
    /// @dev 计算当前销售比例（不修改状态）
    /// @return 销售比例（1e18精度）
    function _computeProtectedSalesRatio() internal view returns (uint256) {
        uint256 sold = totalNFTSupply - IERC721(promptNFT).balanceOf(salesAddress);
        uint256 rawRatio = sold * 1e18 / totalNFTSupply;
        return rawRatio;
    }

    /// @notice 获取受保护的销售比例（带缓存、上限保护和紧急暂停）
    /// @return 销售比例（1e18精度）
    function getProtectedSalesRatio() public returns (uint256) {
        if (salesRatioUpdatePaused) {
            return cachedSalesRatio;
        }
        if (block.timestamp - lastSalesRatioUpdate >= 1 hours) {
            cachedSalesRatio = _computeProtectedSalesRatio();
            lastSalesRatioUpdate = block.timestamp;
        }
        return cachedSalesRatio;
    }

    /// @notice 获取受保护的销售比例（视图版，不修改状态）
    /// @return 销售比例（1e18精度）
    function getProtectedSalesRatioView() public view returns (uint256) {
        if (salesRatioUpdatePaused) {
            return cachedSalesRatio;
        }
        return _computeProtectedSalesRatio();
    }

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
    function getStakedNFTOwner(uint256 tokenId) external view returns (address) {
        return nftOwners[tokenId];
    }

    /// @notice 获取用户概览信息，便于链下一次性读取常用字段
    /// @param user 用户地址
    /// @return stakeCount 质押项数量
    /// @return claimableAmount 当前可领取（包含未写入 pending 的部分）
    /// @return claimed 已累计领取总量
    function getUserSummary(address user) external view returns (uint256 stakeCount, uint256 claimableAmount, uint256 claimed) {
        stakeCount = users[user].stakes.length;
        claimableAmount = claimable(user);
        claimed = users[user].claimed;
    }

    /// @notice 获取合约关键全局统计信息，便于链下监控
    /// @return _totalStakeCount 全局质押NFT总数
    /// @return _accRewardPerWeight 全局 accRewardPerWeight
    /// @return _lastRewardTimestamp 上次奖励计算时间戳
    /// @return _startRewardTimestamp 奖励开始时间戳
    /// @return _bufferPoolReward 缓冲池总量
    function getSystemStats() external view returns (uint256 _totalStakeCount, uint256 _accRewardPerWeight, uint256 _lastRewardTimestamp, uint256 _startRewardTimestamp, uint256 _bufferPoolReward) {
        _totalStakeCount = totalStakeCount;
        _accRewardPerWeight = accRewardPerWeight;
        _lastRewardTimestamp = lastRewardTimestamp;
        _startRewardTimestamp = startRewardTimestamp;
        _bufferPoolReward = bufferPoolReward;
    }

    /// @notice 获取当前全局已发放给用户的PTC总量，包括已领取和未领取部分（不含缓冲池）
    /// 计算方式：totalClaimedPTC + totalPendingReward + 当前周期未结算的奖励（按销售比例调整）
    /// 是模糊值，因为当前周期奖励按比例调整后会进入缓冲池，无法准确分配到用户，但可以近似认为未结算部分也属于用户待领取范围
    /// 因手续费在提现时扣除，合约里不知道手续费具体多少，所以不考虑手续费因素，直接计算按销售比例调整后的奖励总量
    function getTotalAllocatedPTC() external view returns (uint256) {
        uint256 unaccounted = 0;
        uint256 nowTime = block.timestamp;
        uint256 lastTime = lastRewardTimestamp == 0 ? startRewardTimestamp : lastRewardTimestamp;
        if (nowTime > lastTime && totalStakeCount > 0) {
            uint256 ratio = getProtectedSalesRatioView();
            uint256 reward = _emittedUntil(nowTime) - _emittedUntil(lastTime);
            uint256 adjustedReward = reward * ratio / 1e18;
            unaccounted = adjustedReward;
        }
        return totalClaimedPTC + totalPendingReward + unaccounted;
    }

    // -------------------- 核心函数 --------------------

    /// @notice 更新全局奖励状态（分段累加）
    function _updateGlobal() internal {
        uint256 nowTime = block.timestamp; // 移除结束时间限制
        if (lastRewardTimestamp == 0) lastRewardTimestamp = startRewardTimestamp;
        if (nowTime <= lastRewardTimestamp) return;
        if (totalStakeCount == 0) {
            lastRewardTimestamp = nowTime;
            return;
        }
        uint256 from = lastRewardTimestamp;
        uint256 to = nowTime;

        // Compute total emitted up to 'to' and up to 'from', then take difference.
        uint256 reward = _emittedUntil(to) - _emittedUntil(from);
        // 使用受保护的销售比例计算
        uint256 ratio = getProtectedSalesRatio();
        // 调整奖励
        uint256 adjustedReward = reward * ratio / 1e18;
        // 剩余部分进入缓冲池
        bufferPoolReward += reward - adjustedReward;
        // 分配给用户（手续费在提现时扣除）
        accRewardPerWeight += adjustedReward * 1e18 / totalStakeCount;
        lastRewardTimestamp = nowTime;
    }

    /// @dev 计算从奖励开始到时间`t`的总释放量，包含前5年固定释放和第6年开始的动态释放
    /// 修复：使用确定性计算，不依赖合约当前余额，避免循环依赖问题
    function _emittedUntil(uint256 t) public view returns (uint256) {
        if (t <= startRewardTimestamp) return 0;
        // 移除结束时间限制，因为奖励永远释放
        uint256 total = 0;
        uint256 periodDuration = SCHEDULE_PERIOD_DURATION;
        // 前5年固定释放
        for (uint256 i = 0; i < 5; i++) {
            uint256 periodStart = startRewardTimestamp + i * periodDuration;
            if (t <= periodStart) break;
            uint256 periodEnd = periodStart + periodDuration;
            uint256 elapsed = t < periodEnd ? t - periodStart : periodDuration;
            total += schedulePeriodTotals[i] * elapsed / periodDuration;
        }
        // 从第六年开始动态释放
        uint256 start6 = startRewardTimestamp + 5 * periodDuration;
        if (t > start6) {
            uint256 remaining = REMAINING_AFTER_5_YEARS + additionalRewardAfter5Years;
            uint256 yearsPassed = (t - start6) / periodDuration;
            for (uint256 y = 0; y <= yearsPassed && remaining > 0; y++) {
                uint256 releaseThisYear = remaining * FRACTION / 10000;
                uint256 periodStart = start6 + y * periodDuration;
                if (t <= periodStart) break;
                uint256 periodEnd = periodStart + periodDuration;
                uint256 elapsed = t < periodEnd ? t - periodStart : periodDuration;
                total += releaseThisYear * elapsed / periodDuration;
                remaining -= releaseThisYear;
            }
        }
        return total;
    }

    /// @notice 更新指定用户的奖励（全局积分累加器模型）
    // 该函数会在每次质押、解押和领取奖励时调用，确保用户的奖励状态是最新的
    function _updateReward(address user) internal {
        _updateGlobal();
        UserInfo storage u = users[user];
        uint256 stakeCount = u.stakes.length;
        if (stakeCount > 0) {
            uint256 pending = stakeCount * (accRewardPerWeight - u.rewardDebt) / 1e18;
            u.pendingReward += pending;
            totalPendingReward += pending;
        }
        u.rewardDebt = accRewardPerWeight;
    }

    /// @notice 内部函数：从用户stakes数组中移除指定tokenId的状态（不处理NFT转移）
    function _removeStakeState(address user, uint256 tokenId) internal {
        uint256 idxPlus = stakeIndex[user][tokenId];
        require(idxPlus != 0, "Token ID not staked");
        uint256 idx = idxPlus - 1;
        StakeInfo[] storage stakes = users[user].stakes;
        uint256 last = stakes.length - 1;
        if (idx != last) {
            uint256 lastTokenId = stakes[last].tokenId;
            stakes[idx] = stakes[last];
            // update moved token index
            stakeIndex[user][lastTokenId] = idx + 1;
        }
        stakes.pop();
        delete stakeIndex[user][tokenId];
        delete nftOwners[tokenId];
        totalStakeCount -= 1;
    }

    // ========== 质押解押相关 ==========
    /// @notice 质押单个NFT
    function stake(uint256 tokenId) external nonReentrant whenNotPaused {
        _updateReward(msg.sender);
        require(nftOwners[tokenId] == address(0), "Already staked");
        // push and record index+1
        uint256 idx = users[msg.sender].stakes.length;
        users[msg.sender].stakes.push(StakeInfo({
            tokenId: tokenId,
            stakedAt: block.timestamp
        }));
        stakeIndex[msg.sender][tokenId] = idx + 1;
        totalStakeCount += 1;
        nftOwners[tokenId] = msg.sender;
        emit Staked(msg.sender, tokenId);
        IERC721(promptNFT).safeTransferFrom(msg.sender, address(this), tokenId);
    }

    /// @notice 批量质押NFT
    function stakeBatch(uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        require(tokenIds.length > 0, "No token IDs provided");
        _updateReward(msg.sender);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            require(nftOwners[tokenId] == address(0), "Already staked");
            uint256 idx = users[msg.sender].stakes.length;
            users[msg.sender].stakes.push(StakeInfo(tokenId, block.timestamp));
            stakeIndex[msg.sender][tokenId] = idx + 1;
            nftOwners[tokenId] = msg.sender;
        }
        totalStakeCount += tokenIds.length;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            emit Staked(msg.sender, tokenIds[i]);
            IERC721(promptNFT).safeTransferFrom(msg.sender, address(this), tokenIds[i]);
        }
    }

    /// @notice 解押单个NFT
    function unstake(uint256 tokenId) external nonReentrant whenNotPaused {
        _updateReward(msg.sender);
        require(nftOwners[tokenId] == msg.sender, "Not stake owner");
        _removeStakeState(msg.sender, tokenId);
        emit Unstaked(msg.sender, tokenId);
        IERC721(promptNFT).safeTransferFrom(address(this), msg.sender, tokenId);
    }
    
    /// @notice 批量解押NFT
    function unstakeBatch(uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        require(tokenIds.length > 0, "No token IDs provided");
        _updateReward(msg.sender);
        for (uint256 k = 0; k < tokenIds.length; k++) {
            uint256 tokenId = tokenIds[k];
            require(nftOwners[tokenId] == msg.sender, "Not stake owner");
            _removeStakeState(msg.sender, tokenId);
            emit Unstaked(msg.sender, tokenId);
            IERC721(promptNFT).safeTransferFrom(address(this), msg.sender, tokenId);
        }
    }

    /// @notice 一键解押用户所有NFT
    /// 注意：用户质押nft数量太多可能导致gas高甚至超过上限而无法执行
    function unstakeAll() external nonReentrant whenNotPaused {
        _updateReward(msg.sender);
        StakeInfo[] storage stakes = users[msg.sender].stakes;
        require(stakes.length > 0, "No NFT staked");
        uint256 count = stakes.length;
        // pop from end and remove mappings
        while (stakes.length > 0) {
            uint256 tid = stakes[stakes.length - 1].tokenId;
            stakes.pop();
            delete stakeIndex[msg.sender][tid];
            delete nftOwners[tid];
            emit Unstaked(msg.sender, tid);
            IERC721(promptNFT).safeTransferFrom(address(this), msg.sender, tid);
        }
        totalStakeCount -= count;
    }

    /// @notice 管理员为用户提现所有可领取的PTC奖励（扣除手续费）
    /// @param user 用户地址
    /// @param feeRate 手续费率，单位1e4（100=1%）
    function withdrawForUser(address user, uint256 feeRate) external nonReentrant whenNotPaused onlyOwner {
        require(feeRate <= 10000, "Invalid fee rate");
        _updateReward(user);
        UserInfo storage u = users[user];
        uint256 totalPending = u.pendingReward;
        require(totalPending > 0, "No claimable reward");

        uint256 amountToClaim = totalPending;
        require(ptc.balanceOf(address(this)) >= amountToClaim, "Insufficient balance");

        // 计算手续费
        uint256 fee = amountToClaim * feeRate / 1e4;
        uint256 netAmount = amountToClaim - fee;

        // 扣减用户 pending
        u.pendingReward -= amountToClaim;
        totalPendingReward -= amountToClaim;
        u.claimed += amountToClaim;

        emit Claimed(user, netAmount);
        ptc.safeTransfer(user, netAmount);
        totalClaimedPTC += netAmount;
        // 手续费转给 feeRecipient
        if (fee > 0) {
            ptc.safeTransfer(feeRecipient, fee);
        }
    }

    /// @notice 管理员为用户提现指定数量的PTC奖励（扣除手续费）
    /// @param user 用户地址
    /// @param amount 提现金额
    /// @param feeRate 手续费率，单位1e4（100=1%）
    function withdrawForUser(address user, uint256 amount, uint256 feeRate) external nonReentrant whenNotPaused onlyOwner {
        require(feeRate <= 10000, "Invalid fee rate");
        _updateReward(user);
        UserInfo storage u = users[user];

        require(amount > 0, "Amount must be greater than zero");
        uint256 totalPending = claimable(user);
        require(amount <= totalPending, "Amount exceeds claimable reward");
        require(ptc.balanceOf(address(this)) >= amount, "Insufficient balance");

        // 计算手续费
        uint256 fee = amount * feeRate / 1e4;
        uint256 netAmount = amount - fee;

        u.pendingReward -= amount;
        totalPendingReward -= amount;
        u.claimed += amount;

        ptc.safeTransfer(user, netAmount);
        totalClaimedPTC += netAmount;
        emit Claimed(user, netAmount);
        // 手续费转给 feeRecipient
        if (fee > 0) {
            ptc.safeTransfer(feeRecipient, fee);
        }
    }

    /// @notice 管理员批量为用户提现所有可领取的PTC奖励（扣除手续费）
    /// @param _users 用户地址数组
    /// @param feeRates 手续费率数组，单位1e4（100=1%），对应每个用户
    function withdrawForUsers(address[] calldata _users, uint256[] calldata feeRates) external nonReentrant whenNotPaused onlyOwner {
        require(_users.length == feeRates.length, "Users and feeRates length mismatch");
        for (uint256 i = 0; i < _users.length; i++) {
            require(feeRates[i] <= 10000, "Invalid fee rate");
        }
        for (uint256 i = 0; i < _users.length; i++) {
            address user = _users[i];
            uint256 feeRate = feeRates[i];
            _updateReward(user);
            UserInfo storage u = users[user];
            uint256 totalPending = u.pendingReward;
            if (totalPending == 0) continue;

            uint256 amountToClaim = totalPending;
            require(ptc.balanceOf(address(this)) >= amountToClaim, "Insufficient balance");

            // 计算手续费
            uint256 fee = amountToClaim * feeRate / 1e4;
            uint256 netAmount = amountToClaim - fee;

            u.pendingReward -= amountToClaim;
            totalPendingReward -= amountToClaim;
            u.claimed += amountToClaim;

            emit Claimed(user, netAmount);
            ptc.safeTransfer(user, netAmount);
            totalClaimedPTC += netAmount;
            // 手续费转给 feeRecipient
            if (fee > 0) {
                ptc.safeTransfer(feeRecipient, fee);
            }
        }
    }

    /// @notice 管理员批量为用户提现指定数量的PTC奖励（扣除手续费）
    /// @param _users 用户地址数组
    /// @param amounts 提现金额数组，对应每个用户
    /// @param feeRates 手续费率数组，单位1e4（100=1%），对应每个用户
    function withdrawForUsers(address[] calldata _users, uint256[] calldata amounts, uint256[] calldata feeRates) external nonReentrant whenNotPaused onlyOwner {
        require(_users.length == amounts.length && amounts.length == feeRates.length, "Length mismatch");
        for (uint256 i = 0; i < feeRates.length; i++) {
            require(feeRates[i] <= 10000, "Invalid fee rate");
        }
        for (uint256 i = 0; i < _users.length; i++) {
            address user = _users[i];
            uint256 amount = amounts[i];
            uint256 feeRate = feeRates[i];
            require(amount > 0, "Amount must be greater than zero");

            _updateReward(user);
            UserInfo storage u = users[user];
            uint256 totalPending = claimable(user);
            require(amount <= totalPending, "Amount exceeds claimable reward");
            require(ptc.balanceOf(address(this)) >= amount, "Insufficient balance");

            // 计算手续费
            uint256 fee = amount * feeRate / 1e4;
            uint256 netAmount = amount - fee;

            u.pendingReward -= amount;
            totalPendingReward -= amount;
            u.claimed += amount;

            ptc.safeTransfer(user, netAmount);
            totalClaimedPTC += netAmount;
            emit Claimed(user, netAmount);
            // 手续费转给 feeRecipient
            if (fee > 0) {
                ptc.safeTransfer(feeRecipient, fee);
            }
        }
    }
        
    /// @notice 查询用户当前可领取的PTC奖励（包含未更新周期）
    function claimable(address user) public view returns (uint256) {
        UserInfo storage u = users[user];
        uint256 stakeCount = u.stakes.length;
        uint256 nowTime = block.timestamp; // 移除结束时间限制
        uint256 acc = accRewardPerWeight;
        if (nowTime > lastRewardTimestamp && totalStakeCount > 0) {
            uint256 ratio = getProtectedSalesRatioView();
            uint256 reward = _emittedUntil(nowTime) - _emittedUntil(lastRewardTimestamp);
            uint256 adjustedReward = reward * ratio / 1e18;
            acc += adjustedReward * 1e18 / totalStakeCount;
        }
        return u.pendingReward + (stakeCount * (acc - u.rewardDebt) / 1e18);
    }

    /// @notice Public view of total emitted tokens up to time `t` (t clipped to schedule end).
    function emittedUntil(uint256 t) external view returns (uint256) {
        return _emittedUntil(t);
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

    /// @notice 救援合约内误转入的ERC721 NFT（禁止Prompt质押NFT）
    function rescueERC721(address nft, uint256 tokenId) external nonReentrant onlyOwner {
        require(nft != promptNFT, "Cannot rescue staked NFT type");
        require(nft != address(0), "Zero address");
        emit ERC721Rescued(msg.sender, nft, tokenId);
        IERC721(nft).safeTransferFrom(address(this), owner(), tokenId);
    }

    /// @notice 用户紧急批量解押（仅暂停时可用，不结算奖励）
    /// 修复：不重置rewardDebt，避免用户奖励丢失
    function emergencyUnstakeBatch(uint256 count) external nonReentrant whenPaused {
        StakeInfo[] storage stakes = users[msg.sender].stakes;
        require(stakes.length > 0, "No NFT staked");
        uint256 n = count > stakes.length ? stakes.length : count;
        for (uint256 i = 0; i < n; i++) {
            uint256 idx = stakes.length - 1;
            uint256 tid = stakes[idx].tokenId;
            stakes.pop();
            delete stakeIndex[msg.sender][tid];
            delete nftOwners[tid];
            emit EmergencyUnstake(msg.sender, tid);
            IERC721(promptNFT).safeTransferFrom(address(this), msg.sender, tid);
        }
        totalStakeCount -= n;
        // 移除：不再重置rewardDebt，避免奖励丢失
        // users[msg.sender].rewardDebt = accRewardPerWeight;
    }

    /// @notice 平台管理员（owner）随时解押任意NFT返回至原质押用户（含结算）
    /// @dev 仅owner可调，无需用户授权，适用于特殊情况（如到期、司法、合规等）
    /// @param tokenIds NFT编号列表
    function unstakeBatchPlatform(uint256[] calldata tokenIds) external nonReentrant whenNotPaused onlyOwner {
        require(tokenIds.length > 0, "No token IDs provided");
        for (uint256 batchIdx = 0; batchIdx < tokenIds.length; batchIdx++) {
            uint256 tokenId = tokenIds[batchIdx];
            address user = nftOwners[tokenId];
            require(user != address(0), "NFT not staked");
            _updateReward(user);
            _removeStakeState(user, tokenId);
            emit Unstaked(user, tokenId);
            IERC721(promptNFT).safeTransferFrom(address(this), user, tokenId);
        }
    }

    /// @notice 设置手续费接收地址
    /// @param _feeRecipient 新的手续费接收地址
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "Zero address");
        feeRecipient = _feeRecipient;
    }

    /// @notice 合约暂停（仅owner可调）
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice 合约恢复（仅owner可调）
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice 设置缓冲池地址
    /// @param _bufferPool 新的缓冲池地址
    function setBufferPool(address _bufferPool) external onlyOwner {
        require(_bufferPool != address(0), "Zero address");
        bufferPool = _bufferPool;
        emit BufferPoolSet(msg.sender, _bufferPool);
    }

    /// @notice 管理员请求提现缓冲池奖励（时间锁保护）
    /// @param amount 请求提现的金额
    function requestBufferWithdrawal(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than zero");
        require(amount <= bufferPoolReward, "Insufficient buffer pool reward");
        require(bufferPool != address(0), "Buffer pool not set");

        pendingBufferWithdrawal = amount;
        bufferWithdrawalRequestTime = block.timestamp;
        emit BufferPoolWithdrawalRequested(msg.sender, amount, bufferWithdrawalRequestTime);
    }

    /// @notice 管理员执行缓冲池提现（需等待延迟时间）
    function executeBufferWithdrawal() external onlyOwner nonReentrant {
        require(pendingBufferWithdrawal > 0, "No pending withdrawal");
        require(block.timestamp >= bufferWithdrawalRequestTime + BUFFER_WITHDRAWAL_DELAY,
                "Withdrawal delay not met");
        require(bufferPool != address(0), "Buffer pool not set");

        uint256 amount = pendingBufferWithdrawal;
        require(amount <= bufferPoolReward, "Insufficient buffer pool reward");

        // 清空待处理请求
        pendingBufferWithdrawal = 0;
        bufferWithdrawalRequestTime = 0;

        // 执行提现
        bufferPoolReward -= amount;
        ptc.safeTransfer(bufferPool, amount);
        emit BufferPoolWithdrawn(msg.sender, amount);
    }

    /// @notice 管理员注入额外奖励（第6年后的减半发放总量）
    /// @param amount 注入的PTC金额
    function addAdditionalReward(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        require(block.timestamp >= startRewardTimestamp + 5 * SCHEDULE_PERIOD_DURATION, "Can only add after 5 years");
        additionalRewardAfter5Years += amount;
        ptc.safeTransferFrom(msg.sender, address(this), amount);
        emit AdditionalRewardAdded(msg.sender, amount);
    }
}