// SPDX-License-Identifier: MIT
// PromptStaking.sol
// NFT质押合约 V4.0
//
// 支持1种NFT（Prompt），按权重分配PTC奖励。
// 质押挖矿的总数量：30亿
// 释放规则：第一年18%，第二年16%，第三年14%，第四年12%，第五年10%，从第六年开始把剩余数量按照每年释放50%逐年减半的逻辑释放。
// 奖励计算：每次计算时使用当前基数乘以（已销售NFT数量/NFT发行总数）的比例，已销售数量 = NFT发行总数 - 销售地址持有量。
// 奖励分配：用户收益 = 总释放奖励 × 销售比例，剩余部分进入缓冲池。
// 提现：分发操作员（distributor）控制，支持随时为用户提现全部奖励。
// 平台代扣：分发操作员可将单个或多个用户的待领取奖励直接划转至预先配置的平台收款账户，无手续费。
// 权限分离：owner负责合约管理（暂停/恢复、设置参数、救援资产），distributor负责日常奖励分发和代扣。
// 奖励采用全局积分累加器模型，近似连续产出。
// 支持质押/解押/领取奖励单个或批量操作，支持随时领取全部或部分奖励。
// 支持救援功能，允许合约所有者提取误转入的ERC20代币和非质押NFT。
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
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @title PromptStaking
/// @author Thebook
contract PromptStaking is Ownable, ReentrancyGuard, Pausable, IERC721Receiver {
    using SafeERC20 for IERC20;

    // -------------------- Custom Errors --------------------
    error ZeroAddress();
    error InvalidSupply();
    error StartTimeInvalid();
    error AlreadyStaked();
    error NotStakeOwner();
    error TokenNotStaked();
    error NoTokenIds();
    error NoStaked();
    error FeeRateTooHigh();
    error NoClaimable();
    error AmountZero();
    error AmountExceedsPending();
    error LengthMismatch();
    error CannotRescuePTC();
    error CannotRescueStakedNFT();
    error NoPendingWithdrawal();
    error WithdrawalDelayNotMet();
    error BufferPoolNotSet();
    error InsufficientBufferPool();
    error TooEarlyForAdditional();
    error PlatformReceiverNotSet();
    error EmptyUserList();
    error NotDistributor();
    error UnsolicitedNFTTransfer();

    // -------------------- 质押结构体 --------------------
    /// @notice 用户单个NFT质押信息
    struct StakeInfo {
        uint256 tokenId;    // NFT编号
        uint256 stakedAt;   // 质押时间戳
    }

    /// @notice 用户质押及奖励信息
    struct UserInfo {
        StakeInfo[] stakes;     // 用户所有质押NFT
        uint256 rewardDebt;     // 上次结算时的 accRewardPerWeight 快照
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

    uint256 public constant REMAINING_AFTER_5_YEARS = 900000000 ether; // 前5年释放21亿，剩余9亿用于第6年后动态释放
    uint256 public constant FRACTION = 5000; // 50% = 5000/10000，保持不变，第六年开始每年释放年初剩余的50%
    uint256 public constant MAX_DYNAMIC_YEARS = 100; // 第6年后动态释放的最大年数上限，防止循环耗尽gas
    uint256 public constant MAX_FEE_RATE = 10000; // 手续费率上限 100%

    // 第6年后的额外注入奖励（按注入时间前向生效，不回溯历史区间）
    struct AdditionalInjection {
        uint256 amount;     // 注入金额
        uint256 fromYear;   // 生效起始年索引（相对于start6，0=第6年，1=第7年...）
    }
    AdditionalInjection[] public additionalInjections;
    uint256 public totalAdditionalReward; // 累计注入总量（便于查询）

    // 释放周期：前5年固定，第6年开始动态释放
    uint256 public constant SCHEDULE_PERIOD_DURATION = 365 days;
    uint256[5] public schedulePeriodTotals;

    uint256 public startRewardTimestamp; // 奖励产出起始时间

    uint256 public accRewardPerWeight;   // 全局积分累加器（1e18精度）
    uint256 public lastRewardTimestamp;  // 上次奖励计算时间戳
    uint256 public totalStakeCount;      // 全局质押的NFT总数
    uint256 public totalPendingReward;   // 全局待领取奖励总量
    uint256 public totalClaimedPTC;      // 全局已发放给用户的PTC总量（不含缓冲池和手续费）
    uint256 public totalFeesPaid;        // 全局累计手续费总量

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

    // -------------------- 分发权参数 --------------------
    address public distributor; // 奖励分发操作员地址（独立于owner）

    // -------------------- 平台代扣款参数 --------------------
    address public platformPaymentReceiver; // 平台代扣款收款账户地址
    uint256 public totalPlatformCharged;    // 全局累计平台代扣总量（PTC）

    // -------------------- 缓冲池提现延迟参数 --------------------
    uint256 public constant BUFFER_WITHDRAWAL_DELAY = 1 days; // 缓冲池提取延迟时间

    // -------------------- 销售比例保护参数 --------------------
    uint256 private lastSalesRatioUpdate;
    uint256 private cachedSalesRatio;

    // -------------------- 权限修饰符 --------------------
    modifier onlyDistributor() {
        if (msg.sender != distributor) revert NotDistributor();
        _;
    }

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
    event BufferPoolWithdrawn(address indexed admin, uint256 amount);
    event BufferPoolSet(address indexed admin, address newBufferPool);
    event BufferPoolWithdrawalRequested(address indexed admin, uint256 amount, uint256 requestTime);
    event BufferPoolWithdrawalCancelled(address indexed admin);
    event SalesRatioUpdatePaused(address indexed admin);
    event SalesRatioUpdateResumed(address indexed admin);
    event AdditionalRewardAdded(address indexed admin, uint256 amount);
    event DistributorSet(address indexed admin, address newDistributor);
    event FeeRecipientSet(address indexed admin, address newFeeRecipient);
    event PlatformPaymentReceiverSet(address indexed admin, address newReceiver);
    event PlatformCharged(address indexed user, address indexed receiver, uint256 amount);
    
    // -------------------- 构造函数 --------------------
    /// @notice 构造函数，初始化PTC和NFT合约地址及奖励起始时间
    /// @param _ptc PTC代币地址
    /// @param _promptNFT Prompt NFT地址
    /// @param _startTime 奖励产出起始时间（0为立即开始）
    /// @param _feeRecipient 手续费接收地址
    /// @param _totalNFTSupply NFT发行总数
    /// @param _salesAddress 销售地址
    /// @param _bufferPool 缓冲池地址
    /// @param _distributor 分发操作员地址
    constructor(
        address _ptc,
        address _promptNFT,
        uint256 _startTime,
        address _feeRecipient,
        uint256 _totalNFTSupply,
        address _salesAddress,
        address _bufferPool,
        address _distributor
    ) Ownable(msg.sender)
    {
        if (_ptc == address(0)) revert ZeroAddress();
        if (_promptNFT == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        if (_salesAddress == address(0)) revert ZeroAddress();
        if (_bufferPool == address(0)) revert ZeroAddress();
        if (_distributor == address(0)) revert ZeroAddress();
        if (_totalNFTSupply == 0) revert InvalidSupply();

        ptc = IERC20(_ptc);
        promptNFT = _promptNFT;
        feeRecipient = _feeRecipient;
        distributor = _distributor;
        totalNFTSupply = _totalNFTSupply;
        salesAddress = _salesAddress;
        bufferPool = _bufferPool;

        if (_startTime == 0) {
            startRewardTimestamp = block.timestamp;
        } else {
            if (_startTime < block.timestamp) revert StartTimeInvalid();
            startRewardTimestamp = _startTime;
        }
        // 奖励永远释放，无结束时间

        // 初始化各年释放总量
        // 第一年: 18% = 5.4亿
        schedulePeriodTotals[0] = 540000000 ether;
        // 第二年: 16% = 4.8亿
        schedulePeriodTotals[1] = 480000000 ether;
        // 第三年: 14% = 4.2亿
        schedulePeriodTotals[2] = 420000000 ether;
        // 第四年: 12% = 3.6亿
        schedulePeriodTotals[3] = 360000000 ether;
        // 第五年: 10% = 3亿
        schedulePeriodTotals[4] = 300000000 ether;

        cachedSalesRatio = _computeProtectedSalesRatio();
        lastSalesRatioUpdate = block.timestamp;
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
    function getSystemStats() external view returns (
        uint256 _totalStakeCount,
        uint256 _accRewardPerWeight,
        uint256 _lastRewardTimestamp,
        uint256 _startRewardTimestamp,
        uint256 _bufferPoolReward,
        uint256 _totalClaimedPTC,
        uint256 _totalFeesPaid,
        uint256 _totalPendingReward
    ) {
        _totalStakeCount = totalStakeCount;
        _accRewardPerWeight = accRewardPerWeight;
        _lastRewardTimestamp = lastRewardTimestamp;
        _startRewardTimestamp = startRewardTimestamp;
        _bufferPoolReward = bufferPoolReward;
        _totalClaimedPTC = totalClaimedPTC;
        _totalFeesPaid = totalFeesPaid;
        _totalPendingReward = totalPendingReward;
    }

    /// @notice 获取全局已分配给用户的PTC近似总量（已领取 + 待领取 + 未结算部分，不含缓冲池和手续费）
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
        uint256 nowTime = block.timestamp;
        if (lastRewardTimestamp == 0) lastRewardTimestamp = startRewardTimestamp;
        if (nowTime <= lastRewardTimestamp) return;

        uint256 from = lastRewardTimestamp;
        uint256 to = nowTime;
        uint256 reward = _emittedUntil(to) - _emittedUntil(from);
        lastRewardTimestamp = nowTime;

        if (reward == 0) return;

        if (totalStakeCount == 0) {
            bufferPoolReward += reward;
            return;
        }
        uint256 ratio = getProtectedSalesRatio();
        uint256 adjustedReward = reward * ratio / 1e18;
        bufferPoolReward += reward - adjustedReward;
        accRewardPerWeight += adjustedReward * 1e18 / totalStakeCount;
    }

    /// @dev 计算从奖励开始到时间 t 的累计释放量（确定性计算，不依赖合约余额）
    function _emittedUntil(uint256 t) internal view returns (uint256) {
        if (t <= startRewardTimestamp) return 0;
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
        // 从第六年开始动态释放（基础9亿 + 各笔注入按各自生效年份前向释放）
        uint256 start6 = startRewardTimestamp + 5 * periodDuration;
        if (t > start6) {
            total += _emittedTail(t, start6, periodDuration, REMAINING_AFTER_5_YEARS, 0);
            uint256 injLen = additionalInjections.length;
            for (uint256 j = 0; j < injLen; j++) {
                AdditionalInjection storage inj = additionalInjections[j];
                total += _emittedTail(t, start6, periodDuration, inj.amount, inj.fromYear);
            }
        }
        return total;
    }

    /// @dev 计算单笔资金池从 fromYear 开始按50%减半释放到时间 t 的累计释放量
    /// @param t 目标时间
    /// @param start6 第6年起始时间戳
    /// @param periodDuration 每年时长
    /// @param initialRemaining 该笔资金池初始总量
    /// @param fromYear 该笔资金开始参与释放的年索引（0=第6年）
    function _emittedTail(
        uint256 t,
        uint256 start6,
        uint256 periodDuration,
        uint256 initialRemaining,
        uint256 fromYear
    ) internal pure returns (uint256) {
        uint256 yearsPassed = (t - start6) / periodDuration;
        uint256 maxYears = yearsPassed < MAX_DYNAMIC_YEARS ? yearsPassed : MAX_DYNAMIC_YEARS;
        if (maxYears < fromYear) return 0;

        uint256 remaining = initialRemaining;
        for (uint256 y = 0; y < fromYear && remaining > 0; y++) {
            uint256 dec = remaining * FRACTION / 10000;
            if (dec == 0) break;
            remaining -= dec;
        }

        uint256 emitted = 0;
        for (uint256 y = fromYear; y <= maxYears && remaining > 0; y++) {
            uint256 releaseThisYear = remaining * FRACTION / 10000;
            if (releaseThisYear == 0) break;
            uint256 periodStart = start6 + y * periodDuration;
            if (t <= periodStart) break;
            uint256 periodEnd = periodStart + periodDuration;
            uint256 elapsed = t < periodEnd ? t - periodStart : periodDuration;
            emitted += releaseThisYear * elapsed / periodDuration;
            remaining -= releaseThisYear;
        }
        return emitted;
    }

    /// @dev 更新指定用户的奖励，在质押/解押/提现前调用
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

    /// @dev 从用户 stakes 数组中移除指定 tokenId 的状态（不处理NFT转移）
    function _removeStakeState(address user, uint256 tokenId) internal {
        uint256 idxPlus = stakeIndex[user][tokenId];
        if (idxPlus == 0) revert TokenNotStaked();
        uint256 idx = idxPlus - 1;
        StakeInfo[] storage stakes = users[user].stakes;
        uint256 last = stakes.length - 1;
        if (idx != last) {
            uint256 lastTokenId = stakes[last].tokenId;
            stakes[idx] = stakes[last];
            // 更新被移动元素的索引
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
        if (nftOwners[tokenId] != address(0)) revert AlreadyStaked();
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
        if (tokenIds.length == 0) revert NoTokenIds();
        _updateReward(msg.sender);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            if (nftOwners[tokenId] != address(0)) revert AlreadyStaked();
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
        if (nftOwners[tokenId] != msg.sender) revert NotStakeOwner();
        _removeStakeState(msg.sender, tokenId);
        emit Unstaked(msg.sender, tokenId);
        IERC721(promptNFT).safeTransferFrom(address(this), msg.sender, tokenId);
    }
    
    /// @notice 批量解押NFT
    /// @dev 循环中每次safeTransferFrom回调时，外部view调用可能观察到中间状态（已处理的NFT已移除，未处理的仍存在）。
    ///      nonReentrant已阻止状态变更重入，集成方应避免在onERC721Received回调中依赖本合约的view快照。
    function unstakeBatch(uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        if (tokenIds.length == 0) revert NoTokenIds();
        _updateReward(msg.sender);
        for (uint256 k = 0; k < tokenIds.length; k++) {
            uint256 tokenId = tokenIds[k];
            if (nftOwners[tokenId] != msg.sender) revert NotStakeOwner();
            _removeStakeState(msg.sender, tokenId);
            emit Unstaked(msg.sender, tokenId);
            IERC721(promptNFT).safeTransferFrom(address(this), msg.sender, tokenId);
        }
    }

    /// @notice 一键解押用户所有NFT
    /// @dev 注意：用户质押nft数量太多可能导致gas高甚至超过上限而无法执行。
    ///      循环中每次safeTransferFrom回调时，外部view调用可能观察到中间状态，集成方应避免在回调中依赖本合约的view快照。
    function unstakeAll() external nonReentrant whenNotPaused {
        _updateReward(msg.sender);
        StakeInfo[] storage stakes = users[msg.sender].stakes;
        if (stakes.length == 0) revert NoStaked();
        uint256 count = stakes.length;
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

    /// @notice 分发操作员为用户提现所有可领取的PTC奖励（扣除手续费）
    /// @param user 用户地址
    /// @param feeRate 手续费率，单位1e4（100=1%）
    function withdrawForUser(address user, uint256 feeRate) external nonReentrant whenNotPaused onlyDistributor {
        if (feeRate > MAX_FEE_RATE) revert FeeRateTooHigh();
        _updateReward(user);
        UserInfo storage u = users[user];
        uint256 totalPending = u.pendingReward;
        if (totalPending == 0) revert NoClaimable();
        uint256 amountToClaim = totalPending;

        // 计算手续费
        uint256 fee = amountToClaim * feeRate / 1e4;
        uint256 netAmount = amountToClaim - fee;

        u.pendingReward -= amountToClaim;
        totalPendingReward -= amountToClaim;
        u.claimed += amountToClaim;
        totalClaimedPTC += netAmount;
        if (fee > 0) totalFeesPaid += fee;

        emit Claimed(user, netAmount);
        ptc.safeTransfer(user, netAmount);
        if (fee > 0) ptc.safeTransfer(feeRecipient, fee);
    }

    /// @notice 分发操作员为用户提现指定数量的PTC奖励（扣除手续费）
    /// @param user 用户地址
    /// @param amount 提现金额
    /// @param feeRate 手续费率，单位1e4（100=1%）
    function withdrawForUser(address user, uint256 amount, uint256 feeRate) external nonReentrant whenNotPaused onlyDistributor {
        if (feeRate > MAX_FEE_RATE) revert FeeRateTooHigh();
        _updateReward(user);
        UserInfo storage u = users[user];
        if (amount == 0) revert AmountZero();
        if (amount > u.pendingReward) revert AmountExceedsPending();

        // 计算手续费
        uint256 fee = amount * feeRate / 1e4;
        uint256 netAmount = amount - fee;

        u.pendingReward -= amount;
        totalPendingReward -= amount;
        u.claimed += amount;
        totalClaimedPTC += netAmount;
        if (fee > 0) totalFeesPaid += fee;

        emit Claimed(user, netAmount);
        ptc.safeTransfer(user, netAmount);
        if (fee > 0) ptc.safeTransfer(feeRecipient, fee);
    }

    /// @notice 分发操作员批量为用户提现所有可领取的PTC奖励（扣除手续费）
    /// @param _users 用户地址数组
    /// @param feeRates 手续费率数组，单位1e4（100=1%），对应每个用户
    function withdrawForUsers(address[] calldata _users, uint256[] calldata feeRates) external nonReentrant whenNotPaused onlyDistributor {
        if (_users.length != feeRates.length) revert LengthMismatch();
        for (uint256 i = 0; i < _users.length; i++) {
            if (feeRates[i] > MAX_FEE_RATE) revert FeeRateTooHigh();
        }
        for (uint256 i = 0; i < _users.length; i++) {
            address user = _users[i];
            uint256 feeRate = feeRates[i];
            _updateReward(user);
            UserInfo storage u = users[user];
            uint256 totalPending = u.pendingReward;
            if (totalPending == 0) continue;

            uint256 amountToClaim = totalPending;
            // 计算手续费
            uint256 fee = amountToClaim * feeRate / 1e4;
            uint256 netAmount = amountToClaim - fee;

            u.pendingReward -= amountToClaim;
            totalPendingReward -= amountToClaim;
            u.claimed += amountToClaim;
            totalClaimedPTC += netAmount;
            if (fee > 0) totalFeesPaid += fee;

            emit Claimed(user, netAmount);
            ptc.safeTransfer(user, netAmount);
            if (fee > 0) ptc.safeTransfer(feeRecipient, fee);
        }
    }

    /// @notice 分发操作员批量为用户提现指定数量的PTC奖励（扣除手续费）
    /// @param _users 用户地址数组
    /// @param amounts 提现金额数组，对应每个用户
    /// @param feeRates 手续费率数组，单位1e4（100=1%），对应每个用户
    function withdrawForUsers(address[] calldata _users, uint256[] calldata amounts, uint256[] calldata feeRates) external nonReentrant whenNotPaused onlyDistributor {
        if (_users.length != amounts.length || amounts.length != feeRates.length) revert LengthMismatch();
        for (uint256 i = 0; i < feeRates.length; i++) {
            if (feeRates[i] > MAX_FEE_RATE) revert FeeRateTooHigh();
        }
        for (uint256 i = 0; i < _users.length; i++) {
            address user = _users[i];
            uint256 amount = amounts[i];
            uint256 feeRate = feeRates[i];
            if (amount == 0) revert AmountZero();

            _updateReward(user);
            UserInfo storage u = users[user];
            if (amount > u.pendingReward) revert AmountExceedsPending();

            // 计算手续费
            uint256 fee = amount * feeRate / 1e4;
            uint256 netAmount = amount - fee;

            u.pendingReward -= amount;
            totalPendingReward -= amount;
            u.claimed += amount;
            totalClaimedPTC += netAmount;
            if (fee > 0) totalFeesPaid += fee;

            emit Claimed(user, netAmount);
            ptc.safeTransfer(user, netAmount);
            if (fee > 0) ptc.safeTransfer(feeRecipient, fee);
        }
    }

    /// @notice 查询用户当前可领取的PTC奖励（含未结算的实时累积部分）
    function claimable(address user) public view returns (uint256) {
        UserInfo storage u = users[user];
        uint256 stakeCount = u.stakes.length;
        uint256 nowTime = block.timestamp;
        uint256 lastTime = lastRewardTimestamp == 0 ? startRewardTimestamp : lastRewardTimestamp;
        uint256 acc = accRewardPerWeight;
        if (nowTime > lastTime && totalStakeCount > 0) {
            uint256 ratio = getProtectedSalesRatioView();
            uint256 reward = _emittedUntil(nowTime) - _emittedUntil(lastTime);
            uint256 adjustedReward = reward * ratio / 1e18;
            acc += adjustedReward * 1e18 / totalStakeCount;
        }
        return u.pendingReward + (stakeCount * (acc - u.rewardDebt) / 1e18);
    }

    /// @notice 查询从奖励开始到时间 t 的累计释放量
    function emittedUntil(uint256 t) external view returns (uint256) {
        return _emittedUntil(t);
    }

    /// @notice 救援合约内误转入的ERC20代币（禁止PTC）
    function rescueERC20(address token, uint256 amount) external nonReentrant onlyOwner {
        if (token == address(ptc)) revert CannotRescuePTC();
        if (token == address(0)) revert ZeroAddress();
        emit ERC20Rescued(msg.sender, token, amount);
        IERC20(token).safeTransfer(owner(), amount);
    }

    /// @notice 救援合约内误转入的ERC721 NFT（禁止Prompt质押NFT）
    function rescueERC721(address nft, uint256 tokenId) external nonReentrant onlyOwner {
        if (nft == promptNFT) revert CannotRescueStakedNFT();
        if (nft == address(0)) revert ZeroAddress();
        emit ERC721Rescued(msg.sender, nft, tokenId);
        IERC721(nft).safeTransferFrom(address(this), owner(), tokenId);
    }

    /// @notice 用户紧急批量解押（仅暂停时可用，基于已有accRewardPerWeight结算奖励到pendingReward后再解押）
    function emergencyUnstakeBatch(uint256 count) external nonReentrant whenPaused {
        UserInfo storage u = users[msg.sender];
        StakeInfo[] storage stakes = u.stakes;
        if (stakes.length == 0) revert NoStaked();
        uint256 stakeCount = stakes.length;
        if (stakeCount > 0 && accRewardPerWeight > u.rewardDebt) {
            uint256 pending = stakeCount * (accRewardPerWeight - u.rewardDebt) / 1e18;
            u.pendingReward += pending;
            totalPendingReward += pending;
        }
        u.rewardDebt = accRewardPerWeight;
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
    }

    /// @notice 分发操作员随时解押任意NFT返回至原质押用户（含结算）
    /// @dev 仅distributor可调，无需用户授权，适用于特殊情况（如到期、司法、合规等）
    /// @param tokenIds NFT编号列表
    function unstakeBatchPlatform(uint256[] calldata tokenIds) external nonReentrant whenNotPaused onlyDistributor {
        if (tokenIds.length == 0) revert NoTokenIds();
        _updateGlobal();
        address lastUser = address(0);
        for (uint256 batchIdx = 0; batchIdx < tokenIds.length; batchIdx++) {
            uint256 tokenId = tokenIds[batchIdx];
            address user = nftOwners[tokenId];
            if (user == address(0)) revert TokenNotStaked();
            if (user != lastUser) {
                _settleUser(user);
                lastUser = user;
            }
            _removeStakeState(user, tokenId);
            emit Unstaked(user, tokenId);
            IERC721(promptNFT).safeTransferFrom(address(this), user, tokenId);
        }
    }

    /// @dev 仅结算用户奖励（不调用 _updateGlobal），供已完成全局更新后使用
    function _settleUser(address user) internal {
        UserInfo storage u = users[user];
        uint256 stakeCount = u.stakes.length;
        if (stakeCount > 0) {
            uint256 pending = stakeCount * (accRewardPerWeight - u.rewardDebt) / 1e18;
            u.pendingReward += pending;
            totalPendingReward += pending;
        }
        u.rewardDebt = accRewardPerWeight;
    }

    /// @notice 设置手续费接收地址
    /// @param _feeRecipient 新的手续费接收地址
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        if (_feeRecipient == address(0)) revert ZeroAddress();
        feeRecipient = _feeRecipient;
        emit FeeRecipientSet(msg.sender, _feeRecipient);
    }

    /// @notice 设置分发操作员地址（仅owner可调）
    /// @param _distributor 新的分发操作员地址
    function setDistributor(address _distributor) external onlyOwner {
        if (_distributor == address(0)) revert ZeroAddress();
        distributor = _distributor;
        emit DistributorSet(msg.sender, _distributor);
    }

    /// @notice 设置平台代扣款收款账户地址
    /// @param _receiver 新的平台收款地址
    function setPlatformPaymentReceiver(address _receiver) external onlyOwner {
        if (_receiver == address(0)) revert ZeroAddress();
        platformPaymentReceiver = _receiver;
        emit PlatformPaymentReceiverSet(msg.sender, _receiver);
    }

    /// @dev 内部代扣逻辑：将用户 amount 的待领取奖励转入平台收款账户（无手续费）
    /// @param user 被代扣的用户地址
    /// @param amount 代扣金额（必须 >0 且 <= 用户 pendingReward）
    function _chargeUser(address user, uint256 amount) internal {
        UserInfo storage u = users[user];
        if (amount > u.pendingReward) revert AmountExceedsPending();

        u.pendingReward -= amount;
        totalPendingReward -= amount;
        u.claimed += amount;
        totalClaimedPTC += amount;
        totalPlatformCharged += amount;

        emit PlatformCharged(user, platformPaymentReceiver, amount);
        ptc.safeTransfer(platformPaymentReceiver, amount);
    }

    /// @notice 分发操作员代扣单个用户指定数量奖励至平台收款账户（无手续费）
    /// @param user 被代扣的用户地址
    /// @param amount 代扣金额
    function chargeUser(address user, uint256 amount) external nonReentrant whenNotPaused onlyDistributor {
        if (platformPaymentReceiver == address(0)) revert PlatformReceiverNotSet();
        if (amount == 0) revert AmountZero();
        _updateReward(user);
        _chargeUser(user, amount);
    }

    /// @notice 分发操作员批量代扣多个用户指定数量奖励至平台收款账户（无手续费）
    /// @param _users 被代扣的用户地址数组
    /// @param amounts 对应每个用户的代扣金额数组
    function chargeUsers(address[] calldata _users, uint256[] calldata amounts) external nonReentrant whenNotPaused onlyDistributor {
        if (platformPaymentReceiver == address(0)) revert PlatformReceiverNotSet();
        if (_users.length != amounts.length) revert LengthMismatch();
        if (_users.length == 0) revert EmptyUserList();
        for (uint256 i = 0; i < _users.length; i++) {
            uint256 amount = amounts[i];
            if (amount == 0) revert AmountZero();
            address user = _users[i];
            _updateReward(user);
            _chargeUser(user, amount);
        }
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
        if (_bufferPool == address(0)) revert ZeroAddress();
        bufferPool = _bufferPool;
        emit BufferPoolSet(msg.sender, _bufferPool);
    }

    /// @notice 管理员请求提现缓冲池奖励（时间锁保护）
    /// @param amount 请求提现的金额
    function requestBufferWithdrawal(uint256 amount) external onlyOwner {
        if (amount == 0) revert AmountZero();
        if (amount > bufferPoolReward) revert InsufficientBufferPool();
        if (bufferPool == address(0)) revert BufferPoolNotSet();

        pendingBufferWithdrawal = amount;
        bufferWithdrawalRequestTime = block.timestamp;
        emit BufferPoolWithdrawalRequested(msg.sender, amount, bufferWithdrawalRequestTime);
    }

    /// @notice 管理员取消缓冲池提现请求
    function cancelBufferWithdrawal() external onlyOwner {
        if (pendingBufferWithdrawal == 0) revert NoPendingWithdrawal();
        pendingBufferWithdrawal = 0;
        bufferWithdrawalRequestTime = 0;
        emit BufferPoolWithdrawalCancelled(msg.sender);
    }

    /// @notice 管理员执行缓冲池提现（需等待延迟时间）
    function executeBufferWithdrawal() external onlyOwner nonReentrant {
        if (pendingBufferWithdrawal == 0) revert NoPendingWithdrawal();
        if (block.timestamp < bufferWithdrawalRequestTime + BUFFER_WITHDRAWAL_DELAY) revert WithdrawalDelayNotMet();
        if (bufferPool == address(0)) revert BufferPoolNotSet();

        uint256 amount = pendingBufferWithdrawal;
        if (amount > bufferPoolReward) revert InsufficientBufferPool();

        // 清空待处理请求
        pendingBufferWithdrawal = 0;
        bufferWithdrawalRequestTime = 0;

        // 执行提现
        bufferPoolReward -= amount;
        ptc.safeTransfer(bufferPool, amount);
        emit BufferPoolWithdrawn(msg.sender, amount);
    }

    /// @notice 管理员注入额外奖励（第6年后的减半发放总量，仅从下一个完整年度开始前向释放，不回溯历史）
    /// @param amount 注入的PTC金额
    function addAdditionalReward(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert AmountZero();
        uint256 start6 = startRewardTimestamp + 5 * SCHEDULE_PERIOD_DURATION;
        if (block.timestamp < start6) revert TooEarlyForAdditional();
        _updateGlobal();
        uint256 fromYear = (block.timestamp - start6) / SCHEDULE_PERIOD_DURATION + 1;
        additionalInjections.push(AdditionalInjection({
            amount: amount,
            fromYear: fromYear
        }));
        totalAdditionalReward += amount;
        ptc.safeTransferFrom(msg.sender, address(this), amount);
        emit AdditionalRewardAdded(msg.sender, amount);
    }

    /// @notice 查询额外注入记录数量
    function getAdditionalInjectionsCount() external view returns (uint256) {
        return additionalInjections.length;
    }

    /// @notice ERC721接收回调：promptNFT仅允许合约自身发起的转入（即通过stake流程），其他NFT无条件接受
    function onERC721Received(
        address operator,
        address,
        uint256,
        bytes calldata
    ) external view override returns (bytes4) {
        if (msg.sender == promptNFT && operator != address(this)) {
            revert UnsolicitedNFTTransfer();
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}