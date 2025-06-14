// SPDX-License-Identifier: MIT
// PromptStaking.sol
// NFT质押合约
//
// 质押规定好的三种NFT，名称分别是Memory，Prompt和Memes，按质押权重占比分配产出PTC。
// 如果把Prompt 的算力权重记为 50，那么 Memory 的算力权重就是1，Meme的算力权重就是 2500。
// 奖励周期Round:固定周期产出固定数量，每隔一个产出周期（10分钟，使用时间戳），产出160个PTC。
// 减半周期Period:每两年进行一次固定产出数量减半。
// 无预留、预挖等其他产出方法。
// 奖励采用时间戳惰性累积模型，确保每次操作都能正确计算奖励。
// 用户可随时质押和解除质押。
// 用户可个别质押或批量质押NFT。
// 用户可个别解押或批量解押或全部解押NFT。
// 批量质押和解押NFT，支持同类型和不同类型的批量操作。
// 用户可随时提取产出的可提取的PTC，可全部提取或部分提取。
// 支持救援功能，允许合约所有者提取误转入的ERC20代币、ETH和非质押NFT，但禁止提取PTC代币和三种质押NFT。
// 合约使用OpenZeppelin的Ownable和ReentrancyGuard模块，确保合约安全性和所有权管理。

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// PromptStaking 合约
// 允许用户质押三种特定的NFT，并根据质押的NFT类型和数量分配PTC奖励
contract PromptStaking is Ownable, ReentrancyGuard {
    // 定义质押信息结构体
    // 每个用户的质押信息包括NFT地址、tokenId、权重和质押时间戳
    struct StakeInfo {
        address nft;
        uint256 tokenId;
        uint256 weight;
        uint256 stakedAt; 
    }

    // PTC代币合约地址
    IERC20 public immutable ptc; 

    // 奖励开始时间戳：用于计算奖励周期的起始时间
    // 此时间戳在合约部署时设置，之后不会更改
    uint256 public startRewardTimestamp; 

    // 定义常量
    uint256 public constant PERIOD_DURATION = 600; // 10分钟，600秒
    uint256 public constant INITIAL_REWARD = 160 ether; // 初始每周期奖励160个PTC
    uint256 public constant HALVING_INTERVAL = 2 * 365 days; // 2年区块数

    // 三种支持的NFT地址
    address public immutable memoryNFT;
    address public immutable promptNFT;
    address public immutable memesNFT;

    // 用户质押信息
    mapping(address => StakeInfo[]) public userStakes;//用户质押NFT
    mapping(address => uint256) public pendingReward;//用户待领取奖励
    mapping(address => uint256) public userWeight;//用户权重

    // 全局权重变量
    uint256 public totalWeight; // 全局总权重（所有用户的权重之和

    // 用户最后领取奖励的时间戳
    mapping(address => uint256) public userLastClaimedTimestamp;

    // 事件定义:质押、解押和领取奖励事件
    event Staked(address indexed user, address indexed nft, uint256 tokenId);
    event Unstaked(address indexed user, address indexed nft, uint256 tokenId);
    event Claimed(address indexed user, uint256 amount);

    // 构造函数，初始化PTC代币地址和NFT合约地址
    // PTC代币合约地址需要在部署前先部署PromptCoin合约并传入地址  
    // NFT合约地址需要在部署前先部署相应的NFT合约并传入地址
    // 合约部署后无法更改PTC代币和NFT合约地址
    constructor(address _ptc, address _memory, address _prompt, address _memes) Ownable(msg.sender) {
        ptc = IERC20(_ptc);
        memoryNFT = _memory;
        promptNFT = _prompt;
        memesNFT = _memes;
        startRewardTimestamp = block.timestamp;// 设置奖励开始时间为合约部署时间
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

    // 获取当前已经经过的减半周期数
    // 根据当前时间戳和初始奖励开始时间戳计算已经经过的减半周期数
    function _getHalvingRounds() internal view returns (uint256) {
        return (block.timestamp - startRewardTimestamp) / HALVING_INTERVAL;
    }

    // 获取当前周期的奖励数量
    // 根据当前时间戳和初始奖励计算当前周期的奖励数量
    function _getRewardPerPeriod() internal view returns (uint256) {
        uint256 halvings = _getHalvingRounds();
        if (halvings == 0) {
            return INITIAL_REWARD; // 初始奖励
        } else {
            return INITIAL_REWARD >> halvings; // 每次减半
        }
    }

    // 核心函数：更新指定用户的奖励（惰性计算机制）
    // 计算用户在当前周期内的奖励，并更新用户的待领取奖励和总分配奖励
    // 此函数会在质押、解押和领取奖励时调用，确保用户的奖励是最新的
    function _updateReward(address user) internal {
        // 如果用户没有质押NFT，则不需要更新奖励
        if (userWeight[user] == 0) {
            return; // 用户没有质押NFT，则不需要更新奖励
        }
        // 获取当前周期和用户最后领取奖励的周期
        uint256 currentPeriod = (block.timestamp - startRewardTimestamp) / PERIOD_DURATION;
        uint256 lastClaimedPeriod = (userLastClaimedTimestamp[user] - startRewardTimestamp) / PERIOD_DURATION;
        if (lastClaimedPeriod >= currentPeriod) {
            return; // 如果已经同步到当前周期，则不需要更新
        }
        uint256 periods = currentPeriod - lastClaimedPeriod;
        uint256 rewardPerPeriod = _getRewardPerPeriod();
        if (totalWeight == 0) {
            return; // 如果没有用户质押，则不分配奖励
        }
        // 计算总分配奖励和用户的奖励份额
        uint256 totalReward = rewardPerPeriod * periods;
        uint256 userShare = (userWeight[user] * totalReward) / totalWeight;
    
        pendingReward[user] += userShare; // 更新用户待领取奖励
        pendingReward[user] += userShare; // 更新用户待领取奖励
        userLastClaimedTimestamp[user] = block.timestamp; // 更新用户最后领取奖励的时间戳
    }

    // 质押单个NFT
    // 用户可以质押单个NFT，合约会自动计算权重并更新用户的质押信息
    function stake(address nft, uint256 tokenId) external nonReentrant onlySupportedNFT(nft) {
        _updateReward(msg.sender); // 更新用户奖励

        IERC721(nft).transferFrom(msg.sender, address(this), tokenId); // 转移NFT到合约地址

        uint256 weight = _getWeight(nft); // 获取NFT的权重
        userStakes[msg.sender].push(StakeInfo({
            nft: nft,
            tokenId: tokenId,
            weight: weight,
            stakedAt: block.timestamp // 记录质押时间戳
        }));

        userWeight[msg.sender] += weight; // 更新用户权重
        totalWeight += weight; // 更新总权重

        emit Staked(msg.sender, nft, tokenId); // 触发质押事件
    }

    // 解押单个NFT
    // 用户可以解押单个NFT，合约会自动更新用户的质押信息和权重
    function unstake(address nft, uint256 tokenId) external nonReentrant onlySupportedNFT(nft) {
        _updateReward(msg.sender); // 更新用户奖励

        StakeInfo[] storage stakes = userStakes[msg.sender];
        uint256 len = stakes.length;

        for (uint256 i = 0; i < len; i++) {
            if (stakes[i].nft == nft && stakes[i].tokenId == tokenId) {
                uint256 weight = stakes[i].weight;
                totalWeight -= weight; // 更新总权重
                userWeight[msg.sender] -= weight; // 更新用户权重

                IERC721(nft).transferFrom(address(this), msg.sender, tokenId); // 转移NFT回用户

                // 如果是最后一个元素，直接pop
                if (i != len - 1) {
                    stakes[i] = stakes[len - 1]; // 用最后一个元素替换当前元素
                }
                stakes.pop(); // 移除最后一个元素

                emit Unstaked(msg.sender, nft, tokenId); // 触发解押事件
                return; // 找到并解押后退出函数
            }
        }
        revert("Token ID not found in stake"); // 如果未找到对应的NFT，抛出异常
    }
    
    // 批量质押同类型NFT
    // 用户可以批量质押同类型的NFT，合约会自动计算权重并更新用户的质押信息
    function stakeBatch(address nft, uint256[] calldata tokenIds) external onlySupportedNFT(nft) {
        require(tokenIds.length > 0, "No token IDs provided");
        _updateReward(msg.sender); // 更新用户奖励
        
        uint256 weight = _getWeight(nft); // 获取NFT的权重
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            IERC721(nft).transferFrom(msg.sender, address(this), tokenId); // 转移NFT到合约地址

            userStakes[msg.sender].push(StakeInfo({
                nft: nft,
                tokenId: tokenId,
                weight: weight,
                stakedAt: block.timestamp // 记录质押时间戳
            }));

            userWeight[msg.sender] += weight; // 更新用户权重
            totalWeight += weight; // 更新总权重

            emit Staked(msg.sender, nft, tokenId); // 触发质押事件
        }
    }

    // 批量解押同类型NFT
    // 用户可以批量解押同类型的NFT，合约会自动更新用户的质押信息和权重
    // 注意：用户质押nft数量太多可能导致gas高甚至超过上限而无法执行
    function unstakeBatch(address nft, uint256[] calldata tokenIds) external nonReentrant onlySupportedNFT(nft) {
        require(tokenIds.length > 0, "No token IDs provided");
        _updateReward(msg.sender); // 更新用户奖励

        StakeInfo[] storage stakes = userStakes[msg.sender];
        uint256 len = stakes.length;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            bool found = false;

            for (uint256 j = 0; j < len; j++) {
                if (stakes[j].nft == nft && stakes[j].tokenId == tokenId) {
                    uint256 weight = stakes[j].weight;
                    totalWeight -= weight; // 更新总权重
                    userWeight[msg.sender] -= weight; // 更新用户权重

                    IERC721(nft).transferFrom(address(this), msg.sender, tokenId); // 转移NFT回用户

                    // 如果是最后一个元素，直接pop
                    if (j != len - 1) {
                        stakes[j] = stakes[len - 1]; // 用最后一个元素替换当前元素
                    }
                    stakes.pop(); // 移除最后一个元素
                    len--; // 更新长度

                    emit Unstaked(msg.sender, nft, tokenId); // 触发解押事件
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
    function unstake(address nft) external nonReentrant onlySupportedNFT(nft) {
        _updateReward(msg.sender);

        StakeInfo[] storage stakes = userStakes[msg.sender];
        uint256 len = stakes.length;

        for (uint256 i = len; i > 0; i--) {
            uint256 idx = i - 1;
            if (stakes[idx].nft == nft) {
                uint256 tokenId = stakes[idx].tokenId; // 先保存tokenId
                uint256 weight = stakes[idx].weight;
                totalWeight -= weight;
                userWeight[msg.sender] -= weight;

                IERC721(nft).transferFrom(address(this), msg.sender, stakes[idx].tokenId);

                 // 如果是最后一个元素，直接pop
                if (idx != stakes.length - 1) {
                    stakes[idx] = stakes[stakes.length - 1];
                }
                stakes.pop();

                emit Unstaked(msg.sender, nft, tokenId);
            }
        }
    }

    // 批量质押不同类型的NFT
    // 用户可以批量质押不同类型的NFT，合约会自动计算权重并更新用户的质押信息
    function stakeBatch(address[] calldata nfts, uint256[] calldata tokenIds) external {
        require(nfts.length == tokenIds.length, "Length mismatch");
        _updateReward(msg.sender); // 更新用户奖励

        for (uint256 i = 0; i < nfts.length; i++) {
            address nft = nfts[i];
            uint256 tokenId = tokenIds[i];
            require(_isSupportedNFT(nft), "Unsupported NFT");

            IERC721(nft).transferFrom(msg.sender, address(this), tokenId); // 转移NFT到合约地址

            uint256 weight = _getWeight(nft); // 获取NFT的权重
            userStakes[msg.sender].push(StakeInfo({
                nft: nft,
                tokenId: tokenId,
                weight: weight,
                stakedAt: block.timestamp // 记录质押时间戳
            }));

            userWeight[msg.sender] += weight; // 更新用户权重
            totalWeight += weight; // 更新总权重

            emit Staked(msg.sender, nft, tokenId); // 触发质押事件
        }
    }

    // 批量解押不同类型的NFT
    // 用户可以批量解押不同类型的NFT，合约会自动更新用户的质押信息和权重
    // 注意：用户质押nft数量太多可能导致gas高甚至超过上限而无法执行
    function unstakeBatch(address[] calldata nfts, uint256[] calldata tokenIds) external nonReentrant {
        require(nfts.length == tokenIds.length, "Length mismatch");
        _updateReward(msg.sender); // 更新用户奖励

        StakeInfo[] storage stakes = userStakes[msg.sender];
        uint256 len = stakes.length;

        for (uint256 i = 0; i < nfts.length; i++) {
            address nft = nfts[i];
            uint256 tokenId = tokenIds[i];
            require(_isSupportedNFT(nft), "Unsupported NFT");

            bool found = false;
            for (uint256 j = 0; j < len; j++) {
                if (stakes[j].nft == nft && stakes[j].tokenId == tokenId) {
                    uint256 weight = stakes[j].weight;
                    totalWeight -= weight; // 更新总权重
                    userWeight[msg.sender] -= weight; // 更新用户权重

                    IERC721(nft).transferFrom(address(this), msg.sender, tokenId); // 转移NFT回用户

                    // 如果是最后一个元素，直接pop
                    if (j != len - 1) {
                        stakes[j] = stakes[len - 1]; // 用最后一个元素替换当前元素
                    }
                    stakes.pop(); // 移除最后一个元素
                    len--; // 更新长度

                    emit Unstaked(msg.sender, nft, tokenId); // 触发解押事件
                    found = true;
                    break; // 找到并解押后退出循环
                }
            }
            require(found, "Token ID not found in stake"); // 如果未找到对应的NFT，抛出异常
        }
    }
        
    // 解押所有质押的NFT
    // 用户可以解押所有质押的NFT，合约会自动更新用户的质押信息和权重
    // 注意：用户质押NFT数量过多时，调用本函数可能导致gas消耗极高甚至超过区块gas上限，建议分批解押。
    function unstakeAll() external nonReentrant {
        _updateReward(msg.sender); // 更新用户奖励

        StakeInfo[] storage stakes = userStakes[msg.sender];
        uint256 len = stakes.length;

        require(len > 0, "No NFTs to unstake");

        for (uint256 i = 0; i < len; i++) {
            StakeInfo memory stake = stakes[i];
            uint256 weight = stake.weight;
            totalWeight -= weight; // 更新总权重
            userWeight[msg.sender] -= weight; // 更新用户权重

            IERC721(stake.nft).transferFrom(address(this), msg.sender, stake.tokenId); // 转移NFT回用户
            emit Unstaked(msg.sender, stake.nft, stake.tokenId); // 触发解押事件
        }

        delete userStakes[msg.sender]; // 清空用户质押记录
    }
        
    // 领取所有可以领取的PTC奖励
    function claim() external nonReentrant {
        _updateReward(msg.sender); // 更新用户奖励
        uint256 reward = pendingReward[msg.sender]; // 获取用户待领取奖励

        require(reward > 0, "No claimable reward"); // 确保有可领取的奖励
        require(ptc.balanceOf(address(this)) >= reward, "Insufficient PTC balance in contract"); // 确保合约有足够的PTC余额

        pendingReward[msg.sender] = 0; // 清空用户待领取奖励
        ptc.transfer(msg.sender, reward); // 转移PTC到用户地址

        emit Claimed(msg.sender, reward); // 触发领取奖励事件
    }

    // 领取指定数量的PTC奖励
    // 用户可以领取指定数量的PTC奖励
    function claim(uint256 amount) external nonReentrant {
        _updateReward(msg.sender); // 更新用户奖励
        uint256 reward = pendingReward[msg.sender]; // 获取用户待领取奖励

        require(amount > 0, "Amount must be greater than zero"); // 确保领取数量大于0
        require(amount <= reward, "Amount exceeds claimable reward"); // 确保领取数量不超过待领取奖励
        require(ptc.balanceOf(address(this)) >= amount, "Insufficient PTC balance in contract"); // 确保合约有足够的PTC余额

        pendingReward[msg.sender] -= amount; // 减少用户待领取奖励
        ptc.transfer(msg.sender, amount); // 转移PTC到用户地址

        emit Claimed(msg.sender, amount); // 触发领取奖励事件
    }
        
    // 查询用户当前可领取的PTC奖励（包含未更新周期）
    function claimable(address user) external view returns (uint256) {
        uint256 currentPeriod = (block.timestamp - startRewardTimestamp) / PERIOD_DURATION;
        uint256 lastClaimedPeriod = (userLastClaimedTimestamp[user] - startRewardTimestamp) / PERIOD_DURATION;

        // 若为首次调用，视为已同步到当前周期
        if (userLastClaimedTimestamp[user] == 0 || lastClaimedPeriod >= currentPeriod) {
            return pendingReward[user];
        }

        uint256 periods = currentPeriod - lastClaimedPeriod;
        uint256 rewardPerPeriod = _getRewardPerPeriod();

        if (totalWeight == 0) {
            return pendingReward[user];
        }

        uint256 totalReward = rewardPerPeriod * periods;
        uint256 userShare = (userWeight[user] * totalReward) / totalWeight;

        return pendingReward[user] + userShare;
    }


    // 获取用户的权重
    function getUserWeight(address user) external view returns (uint256) {
        return userWeight[user];
    }

    // 获取用户所有质押NFT信息
    // 注意：用户质押nft数量太多可能导致无法返回
    function getStakedNFTs(address user) external view returns (StakeInfo[] memory) {
        return userStakes[user];
    }

    // 获取用户所有质押NFT信息
    // 用户质押nft数量太多时使用
    function getStakedNFTs(address user, uint256 start, uint256 end) external view returns (StakeInfo[] memory) {
        StakeInfo[] storage stakes = userStakes[user];
        require(start < end && end <= stakes.length, "Invalid range");
        
        StakeInfo[] memory result = new StakeInfo[](end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = stakes[i];
        }
        return result;
    }

    // 查看当前周期奖励
    function currentRewardPerPeriod() external view returns (uint256) {
        return _getRewardPerPeriod();
    }

    // 查看合约剩余的 PTC 总量
    // 净剩余需要线下遍历用户claimable计算
    function getRemainingPTC() external view returns (uint256) {
        return ptc.balanceOf(address(this));
    }

    // 救援合约内误转入的ERC20代币（禁止PTC）
    function rescueERC20(address token, address to, uint256 amount) external nonReentrant onlyOwner {
        require(token != address(ptc), "Rescue of PTC is prohibited");
        IERC20 erc20 = IERC20(token);
        require(amount <= erc20.balanceOf(address(this)), "Amount exceeds contract balance");
        erc20.transfer(to, amount);
    }

    // 救援合约内误转入的主网币
    function rescueGas(address payable to, uint256 amount) external nonReentrant onlyOwner {
        require(amount <= address(this).balance, "Amount exceeds contract balance");
        (bool success, ) = to.call{value: amount}("");
        require(success, "Transfer failed");
    }
    // 救援合约内误转入的ERC721 NFT（禁止三种质押NFT）
    // 注意：_isSupportedNFT 仅检查当前三种NFT，若未来支持更多类型，需同步更新此函数，否则可能导致新支持的NFT无法被禁止救援，存在扩展性风险。
    function rescueERC721(address nft, address to, uint256 tokenId) external nonReentrant onlyOwner {
        require(_isSupportedNFT(nft) == false, "Rescue of staked NFTs is prohibited");
        IERC721 erc721 = IERC721(nft);
        require(erc721.ownerOf(tokenId) == address(this), "Token not owned by contract");
        erc721.transferFrom(address(this), to, tokenId);
    }
}