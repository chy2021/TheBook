// SPDX-License-Identifier: MIT
// PromptStaking.sol
// NFT质押合约（全局积分累加器模型）
//
// 支持三种NFT（Memory、Prompt、Memes），按权重分配PTC奖励。
// 权重：Prompt=50，Memory=1，Memes=2500。
// 产出速率:初始每10分钟产出160个PTC。
// 减半周期:每两年进行一次固定产出数量减半。
// 无预留、预挖等其他产出方法。
// 奖励采用全局积分累加器模型，周期产出+周期内线性插值，近似连续产出
// 质押/解押/领取奖励均可单个或批量操作，支持随时领取全部或部分奖励。
// 批量质押和解押NFT，支持同类型和不同类型的批量操作。
// 用户可随时提取产出的可提取的PTC，可全部提取或部分提取。
// 支持救援功能，允许合约所有者提取误转入的ERC20代币、ETH和非质押NFT，但禁止提取PTC代币和三种质押NFT。
// 合约使用OpenZeppelin的Ownable和ReentrancyGuard模块，确保合约安全性和所有权管理。
// 无人质押和插队稀释导致的丢失奖励视为销毁。

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

// PromptStaking 合约
contract PromptStaking is Ownable, ReentrancyGuard, Pausable, ERC721Holder {
    // 定义质押信息结构体
    // 每个用户的质押信息包括NFT地址、tokenId、权重和质押时间戳
    struct StakeInfo {
        address nft;
        uint256 tokenId;
        uint256 stakedAt; 
    }
    // 定义用户信息结构体
    struct UserInfo {
        StakeInfo[] stakes;
        uint256 weight;         // 当前总权重
        uint256 rewardDebt;     // 上次操作时的accRewardPerWeight * weight
        uint256 pendingReward;  // 待领取奖励
        uint256 claimed;        // 累计已领取奖励
    }

    // PTC代币合约
    IERC20 public immutable ptc; 
    // 三种支持的NFT地址
    address public immutable memoryNFT;
    address public immutable promptNFT;
    address public immutable memesNFT;

    // 定义常量
    uint256 public constant PERIOD_DURATION = 600; // 10分钟，600秒
    uint256 public constant INITIAL_REWARD = 160 ether; // 初始每周期奖励160个PTC
    uint256 public constant HALVING_INTERVAL = 2 * 365 days; // 2年区块数
    // 开始产出后364896000秒,第12年209天时全部产出
    uint256 public constant PRODUCTION_DURATION = 364896000; 

    uint256 public startRewardTimestamp; // 奖励产出起始时间
    uint256 public endRewardTimestamp;   // 奖励产出结束时间

    // 全局积分累加器
    uint256 public accRewardPerWeight; // 1e18精度
    // 上次奖励计算时间戳
    uint256 public lastRewardTimestamp;
    // 全局权重变量
    uint256 public totalWeight; // 全局总权重（所有用户的权重之和

    // 用户质押信息
    mapping(address => UserInfo) public users; // 用户质押信息
     
    // 手续费接收地址和费率
    address public feeRecipient;
    // 手续费率，单位为1e4（即0.01%）
    uint256 public feeRate;      // 1e4为单位
    // 累计未提取手续费
    uint256 public pendingFee;   // 累计未提取手续费

    // 事件定义:质押、解押和领取奖励事件
    event Staked(address indexed user, address indexed nft, uint256 tokenId, uint256 weight, uint256 timestamp);
    event Unstaked(address indexed user, address indexed nft, uint256 tokenId, uint256 weight, uint256 timestamp);
    event Claimed(address indexed user, uint256 amount, uint256 timestamp);
    event EmergencyUnstake(address indexed user, address indexed nft, uint256 tokenId, uint256 timestamp);
    
    // 合约暂停和恢复事件
    event Paused(address indexed operator, uint256 timestamp);
    event Unpaused(address indexed operator, uint256 timestamp);
    // 救援事件：用于救援合约内误转入的ERC20代币、ETH和非质押NFT
    event ERC20Rescued(address indexed operator, address token, uint256 amount, uint256 timestamp);
    event ERC721Rescued(address indexed operator, address nft, uint256 tokenId, uint256 timestamp);
    event GASRescued(address indexed operator, uint256 amount, uint256 timestamp);
    
    // 构造函数，初始化PTC代币地址和NFT合约地址
    // PTC代币合约地址需要在部署前先部署PromptCoin合约并传入地址  
    // NFT合约地址需要在部署前先部署相应的NFT合约并传入地址
    // 合约部署后无法更改PTC代币和NFT合约地址
    constructor(
        address _ptc,
        address _memoryNFT,
        address _promptNFT,
        address _memesNFT,
        uint256 _startTime
    ) Ownable(msg.sender) {
        require(_ptc != address(0), "PTC address zero");
        require(_memoryNFT != address(0), "MemoryNFT address zero");
        require(_promptNFT != address(0), "PromptNFT address zero");
        require(_memesNFT != address(0), "MemesNFT address zero");

        ptc = IERC20(_ptc);
        memoryNFT = _memoryNFT;
        promptNFT = _promptNFT;
        memesNFT = _memesNFT;
        // 如果传入的_startTime为0，则用当前区块时间
        startRewardTimestamp = _startTime == 0 ? block.timestamp : _startTime;
        endRewardTimestamp = startRewardTimestamp + PRODUCTION_DURATION;
    }

    // 修饰符：检查NFT是否为支持的三种NFT之一
    modifier onlySupportedNFT(address nft) {
        require(nft == promptNFT || nft == memoryNFT || nft == memesNFT, "Unsupported NFT");
        _;
    }

    // 检查NFT是否为支持的三种NFT之一
    function _isSupportedNFT(address nft) internal view returns (bool) {
        return nft == memoryNFT || nft == promptNFT || nft == memesNFT;
    }

    // 获取NFT的权重
    function _getWeight(address nft) internal view returns (uint256) {
        if (nft == promptNFT) return 50;      
        if (nft == memoryNFT) return 1;      
        if (nft == memesNFT) return 2500;      
        revert("Unsupported NFT");
    }

    // 更新全局奖励状态
    // 该函数会在每次质押、解押和领取奖励时调用，确保全局奖励状态是最新的
    // 奖励计算基于全局积分累加器模型，周期奖励和线性插值
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

    // 更新指定用户的奖励
    // 该函数会在每次质押、解押和领取奖励时调用，确保用户的奖励状态是最新的
    // 用户的奖励是基于全局积分累加器模型计算的
    // 用户的奖励计算公式为：用户权重 * (accRewardPerWeight - 用户上次操作时的accRewardPerWeight) / 1e18
    // 用户的奖励会累加到用户的pendingReward中，并更新用户的rewardDebt
    function _updateReward(address user) internal {
        _updateGlobal();
        UserInfo storage u = users[user];
        if (u.weight > 0) {
            uint256 pending = u.weight * (accRewardPerWeight - u.rewardDebt) / 1e18;
            u.pendingReward += pending;
        }
        u.rewardDebt = accRewardPerWeight;
    }

    // 质押单个NFT
    // 用户可以质押单个NFT，合约会自动计算权重并更新用户的质押信息
    function stake(address nft, uint256 tokenId) external nonReentrant whenNotPaused onlySupportedNFT(nft) {
        _updateReward(msg.sender); // 更新用户奖励

        IERC721(nft).safeTransferFrom(msg.sender, address(this), tokenId); // 转移NFT到合约地址

        uint256 weight = _getWeight(nft); // 获取NFT的权重
        users[msg.sender].stakes.push(StakeInfo({
            nft: nft,
            tokenId: tokenId,
            stakedAt: block.timestamp // 记录质押时间戳
        }));

        users[msg.sender].weight += weight; // 更新用户权重
        totalWeight += weight; // 更新总权重

        emit Staked(msg.sender, nft, tokenId, weight, block.timestamp); // 触发质押事件
    }

    // 批量质押同类型NFT
    // 用户可以批量质押同类型的NFT，合约会自动计算权重并更新用户的质押信息
    function stakeBatch(address nft, uint256[] calldata tokenIds) external whenNotPaused onlySupportedNFT(nft) {
        require(tokenIds.length > 0, "No token IDs provided");
        _updateReward(msg.sender); // 更新用户奖励
        
        uint256 weight = _getWeight(nft); // 获取NFT的权重
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            IERC721(nft).safeTransferFrom(msg.sender, address(this), tokenId); // 转移NFT到合约地址

            users[msg.sender].stakes.push(StakeInfo({
                nft: nft,
                tokenId: tokenId,
                stakedAt: block.timestamp // 记录质押时间戳
            }));

            users[msg.sender].weight += weight; // 更新用户权重
            totalWeight += weight; // 更新总权重

            emit Staked(msg.sender, nft, tokenId, weight, block.timestamp); // 触发质押事件
        }
    }

    // 批量质押不同类型的NFT
    // 用户可以批量质押不同类型的NFT，合约会自动计算权重并更新用户的质押信息
    function stakeBatch(address[] calldata nfts, uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        require(nfts.length == tokenIds.length, "Length mismatch");
        _updateReward(msg.sender); // 更新用户奖励

        for (uint256 i = 0; i < nfts.length; i++) {
            address nft = nfts[i];
            uint256 tokenId = tokenIds[i];
            require(_isSupportedNFT(nft), "Unsupported NFT");

            IERC721(nft).safeTransferFrom(msg.sender, address(this), tokenId); // 转移NFT到合约地址

            uint256 weight = _getWeight(nft); // 获取NFT的权重
            // 将质押信息添加到用户的质押列表
            // 记录质押时间戳
            users[msg.sender].stakes.push(StakeInfo({
                nft: nft,
                tokenId: tokenId,
                stakedAt: block.timestamp // 记录质押时间戳
            }));

            users[msg.sender].weight += weight; // 更新用户权重
            totalWeight += weight; // 更新总权重

            emit Staked(msg.sender, nft, tokenId, weight, block.timestamp); // 触发质押事件
        }
    }

    // 解押单个NFT
    // 用户可以解押单个NFT，合约会自动更新用户的质押信息和权重
    function unstake(address nft, uint256 tokenId) external nonReentrant whenNotPaused onlySupportedNFT(nft) {
        _updateReward(msg.sender); // 更新用户奖励

        StakeInfo[] storage stakes = users[msg.sender].stakes;
        uint256 len = stakes.length;

        for (uint256 i = 0; i < len; i++) {
            if (stakes[i].nft == nft && stakes[i].tokenId == tokenId) {
                uint256 weight = _getWeight(nft);
                totalWeight -= weight; // 更新总权重
                users[msg.sender].weight -= weight; // 更新用户权重

                IERC721(nft).safeTransferFrom(address(this), msg.sender, tokenId); // 转移NFT回用户

                // 如果是最后一个元素，直接pop
                if (i != len - 1) {
                    stakes[i] = stakes[len - 1]; // 用最后一个元素替换当前元素
                }
                stakes.pop(); // 移除最后一个元素

                emit Unstaked(msg.sender, nft, tokenId, weight, block.timestamp); // 触发解押事件
                return; // 找到并解押后退出函数
            }
        }
        revert("Token ID not found in stake"); // 如果未找到对应的NFT，抛出异常
    }
    
    // 批量解押同类型NFT
    // 用户可以批量解押同类型的NFT，合约会自动更新用户的质押信息和权重
    // 注意：用户质押nft数量太多可能导致gas高甚至超过上限而无法执行
    function unstakeBatch(address nft, uint256[] calldata tokenIds) external nonReentrant whenNotPaused onlySupportedNFT(nft) {
        require(tokenIds.length > 0, "No token IDs provided");
        _updateReward(msg.sender); // 更新用户奖励

        StakeInfo[] storage stakes = users[msg.sender].stakes;
        uint256 len = stakes.length;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            bool found = false;

            for (uint256 j = 0; j < len; j++) {
                if (stakes[j].nft == nft && stakes[j].tokenId == tokenId) {
                    uint256 weight = _getWeight(nft);
                    totalWeight -= weight; // 更新总权重
                    users[msg.sender].weight -= weight; // 更新用户权重

                    IERC721(nft).safeTransferFrom(address(this), msg.sender, tokenId); // 转移NFT回用户

                    // 如果是最后一个元素，直接pop
                    if (j != len - 1) {
                        stakes[j] = stakes[len - 1]; // 用最后一个元素替换当前元素
                    }
                    stakes.pop(); // 移除最后一个元素
                    len--; // 更新长度

                    emit Unstaked(msg.sender, nft, tokenId, weight, block.timestamp); // 触发解押事件
                    found = true;
                    break; // 找到并解押后退出循环
                }
            }
            require(found, "Token ID not found in stake"); // 如果未找到对应的NFT，抛出异常
        }
    }

    // 解押同类型所有的NFT
    // 用户可以解押单种NFT，合约会自动更新用户的质押信息和权重
    // 注意：用户质押nft数量太多可能导致gas高甚至超过上限而无法执行
    function unstake(address nft) external nonReentrant whenNotPaused onlySupportedNFT(nft) {
        _updateReward(msg.sender);

        StakeInfo[] storage stakes = users[msg.sender].stakes;
        uint256 len = stakes.length;

        for (uint256 i = len; i > 0; i--) {
            uint256 idx = i - 1;
            if (stakes[idx].nft == nft) {
                uint256 tokenId = stakes[idx].tokenId; // 先保存tokenId
                uint256 weight = _getWeight(nft);
                totalWeight -= weight;
                users[msg.sender].weight -= weight;

                IERC721(nft).safeTransferFrom(address(this), msg.sender, stakes[idx].tokenId);

                 // 如果是最后一个元素，直接pop
                if (idx != stakes.length - 1) {
                    stakes[idx] = stakes[stakes.length - 1];
                }
                stakes.pop();

                emit Unstaked(msg.sender, nft, tokenId, weight, block.timestamp);
            }
        }
    }

    // 领取所有可以领取的PTC奖励
    function claim() external nonReentrant whenNotPaused {
        _updateReward(msg.sender); // 更新用户奖励
        
        UserInfo storage u = users[msg.sender];
        uint256 reward = u.pendingReward;

        require(reward > 0, "No claimable reward"); // 确保有可领取的奖励
        require(ptc.balanceOf(address(this)) >= reward, "Insufficient PTC balance in contract"); // 确保合约有足够的PTC余额

        u.pendingReward = 0;
        u.claimed += reward;
        ptc.transfer(msg.sender, reward); // 转移PTC到用户地址

        emit Claimed(msg.sender, reward, block.timestamp); // 触发领取奖励事件
    }

    // 领取指定数量的PTC奖励
    // 用户可以领取指定数量的PTC奖励
    function claim(uint256 amount) external nonReentrant whenNotPaused {
        _updateReward(msg.sender); // 更新用户奖励
        UserInfo storage u = users[msg.sender];

        require(amount > 0, "Amount must be greater than zero");
        require(amount <= u.pendingReward, "Amount exceeds claimable reward");
        require(ptc.balanceOf(address(this)) >= amount, "Insufficient PTC balance in contract");

        u.pendingReward -= amount;
        u.claimed += amount;

        ptc.transfer(msg.sender, amount); // 转移PTC到用户地址
        emit Claimed(msg.sender, amount, block.timestamp); // 触发领取奖励事件
    }
        
    // 查询用户当前可领取的PTC奖励（包含未更新周期）
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
            // 计算本次应收手续费
            uint256 fee = reward * feeRate / 1e4;
            acc +=  (reward - fee) * 1e18 / totalWeight;
        }
        return u.pendingReward + (u.weight * (acc - u.rewardDebt) / 1e18);
    }

    // 获取用户所有质押NFT信息
    // 注意：用户质押nft数量太多可能导致无法返回
    function getStakedNFTs(address user) external view returns (StakeInfo[] memory) {
        return users[user].stakes;
    }

    // 获取用户所有质押NFT信息
    // 用户质押nft数量太多时使用
    function getStakedNFTs(address user, uint256 start, uint256 end) external view returns (StakeInfo[] memory) {
        StakeInfo[] storage stakes = users[user].stakes;
        require(start < end && end <= stakes.length, "Invalid range");
        
        StakeInfo[] memory result = new StakeInfo[](end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = stakes[i];
        }
        return result;
    }

    // 查看合约剩余的 PTC 总量
    // 净剩余需要线下遍历用户claimable计算
    function getRemainingPTC() external view returns (uint256) {
        return ptc.balanceOf(address(this));
    }

    // 救援合约内误转入的ERC20代币（禁止PTC）
    function rescueERC20(address token, uint256 amount) external onlyOwner {
        require(token != address(ptc), "Cannot rescue PTC");
        IERC20(token).transfer(owner(), amount);
        emit ERC20Rescued(msg.sender, token, amount, block.timestamp);
    }

    // 救援合约内误转入的主网币
    function rescueGAS(address payable to, uint256 amount) external nonReentrant onlyOwner {
        require(amount <= address(this).balance, "Amount exceeds contract balance");
        (bool success, ) = to.call{value: amount}("");
        require(success, "Transfer failed");
        emit GASRescued(msg.sender, amount, block.timestamp);
    }

    // 救援合约内误转入的ERC721 NFT（禁止三种质押NFT）
    function rescueERC721(address nft, uint256 tokenId) external onlyOwner {
        require(!_isSupportedNFT(nft), "Cannot rescue staked NFT");
        IERC721(nft).transferFrom(address(this), owner(), tokenId);
        emit ERC721Rescued(msg.sender, nft, tokenId, block.timestamp);
    }

    // 奖励是否已经产完
    function isProductionFinished() public view returns (bool) {
        return block.timestamp >= endRewardTimestamp;
    }

    // 产出结束时间戳
    function getEndRewardTimestamp() public view returns (uint256) {
        return endRewardTimestamp;
    }

    // 获取用户总产出（已领取 + 可领取）
    function totalMined(address user) external view returns (uint256) {
        return users[user].claimed + claimable(user);
    }

    // 紧急解押批量操作
    // 允许用户在紧急情况下批量解押NFT 
    function emergencyUnstakeBatch(uint256 count) external nonReentrant whenPaused {
        StakeInfo[] storage stakes = users[msg.sender].stakes;
        require(stakes.length > 0, "No NFT staked");
        uint256 n = count > stakes.length ? stakes.length : count;
        for (uint256 i = 0; i < n; i++) {
            StakeInfo storage info = stakes[stakes.length - 1];
            IERC721(info.nft).transferFrom(address(this), msg.sender, info.tokenId);
            emit EmergencyUnstake(msg.sender, info.nft, info.tokenId, block.timestamp);
            stakes.pop();
        }
        if (stakes.length == 0) {
            users[msg.sender].weight = 0;
        }
    }

    // 设置手续费接收地址和费率
    // 费率单位为1e4（即0.01%），最大值为1000（即100%）
    function setFee(address _recipient, uint256 _rate) external onlyOwner {
        require(_rate <= 10000, "Fee too high");
        feeRecipient = _recipient;
        feeRate = _rate;
    }

    // 允许手续费接收地址提取累计的手续费
    function claimFee() external {
        require(msg.sender == feeRecipient, "Not fee recipient");
        uint256 amount = pendingFee;
        require(amount > 0, "No fee to claim");
        require(ptc.balanceOf(address(this)) >= amount, "Insufficient PTC balance in contract");
        pendingFee = 0;
        ptc.transfer(feeRecipient, amount);
    }

    // 合约暂停功能
    function pause() external onlyOwner {
        _pause();
        emit Paused(msg.sender, block.timestamp);
    }

    // 合约恢复功能
    function unpause() external onlyOwner {
        _unpause();
        emit Unpaused(msg.sender, block.timestamp);
    }

}