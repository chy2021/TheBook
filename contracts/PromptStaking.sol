// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// NFT质押合约
//
// 质押规定好的三种NFT，名称分别是Memory，Prompt和Memes，按质押权重占比分配产出PTC。
// 如果把Prompt 的算力权重记为 1，那么 Memory 的算力权重就是0.02，Meme的算力权重就是 50。
// 固定周期产出固定数量，每隔一个产出周期（近似10分钟左右，使用时间戳），产出160个PTC。
// 需要每两年左右的区块时间进行一次产出减半。无预留、预挖等其他产出方法。
// 奖励采用时间戳惰性累积模型，确保每次操作都能正确计算奖励
// 用户可随时解除质押，可个别解押或全部解押NFT。
// 用户可随时提取全部账户下当前产出的PTC。

contract PromptStaking is Ownable, ReentrancyGuard {
    struct StakeInfo {
        address nft;
        uint256 tokenId;
        uint256 weight;
        uint256 stakedAt; 
    }

    IERC20 public immutable ptc;
    uint256 public startRewardTimestamp;

    uint256 public constant PERIOD_DURATION = 600; // 10分钟，600秒
    uint256 public constant INITIAL_REWARD = 160 ether; // 初始每周期奖励160个PTC
    uint256 public constant HALVING_INTERVAL = 2 * 365 days; // 约2年区块数

    address public immutable memoryNFT;
    address public immutable promptNFT;
    address public immutable memesNFT;

    mapping(address => StakeInfo[]) public userStakes;//用户质押NFT
    mapping(address => uint256) public pendingReward;//用户待领取奖励
    mapping(address => uint256) public userWeight;//用户权重

    uint256 public totalWeight;

    // 记录每个用户上次结算时间，支持惰性奖励计算
    mapping(address => uint256) public userLastClaimedTimestamp;

    event Staked(address indexed user, address indexed nft, uint256 tokenId);
    event Unstaked(address indexed user, address indexed nft, uint256 tokenId);
    event Claimed(address indexed user, uint256 amount);

    constructor(address _ptc, address _memory, address _prompt, address _memes) {
        ptc = IERC20(_ptc);
        memoryNFT = _memory;
        promptNFT = _prompt;
        memesNFT = _memes;
        startRewardTimestamp = block.timestamp;
    }

    modifier onlySupportedNFT(address nft) {
        require(nft == promptNFT || nft == memoryNFT || nft == memesNFT, "Unsupported NFT");
        _;
    }

    function _isSupportedNFT(address nft) internal view returns (bool) {
        return nft == memoryNFT || nft == promptNFT || nft == memesNFT;
    }

    // 计算NFT对应权重
    function _getWeight(address nft) internal view returns (uint256) {
        if (nft == promptNFT) return 50;      
        if (nft == memoryNFT) return 1;      
        if (nft == memesNFT) return 2500;      
        revert("Unsupported NFT");
    }

    // 计算当前减半轮数
    function _getHalvingRounds() internal view returns (uint256) {
        return (block.timestamp - startRewardTimestamp) / HALVING_INTERVAL;
    }

    // 计算当前每周期奖励
    function _getRewardPerPeriod() internal view returns (uint256) {
    uint256 halvings = (block.timestamp - startRewardTimestamp) / HALVING_INTERVAL; // 使用时间差计算减半次数
    return INITIAL_REWARD / (2 ** halvings);
}


    // 更新指定用户的奖励（惰性计算机制）
    function _updateReward(address user) internal {
        uint256 currentPeriod = block.timestamp / PERIOD_DURATION;
        uint256 lastClaimedPeriod = userLastClaimedTimestamp[user] / PERIOD_DURATION;
        
        if (lastClaimedPeriod == 0) lastClaimedPeriod = currentPeriod;
        
        if (currentPeriod > lastClaimedPeriod && totalWeight > 0) {
            uint256 periods = currentPeriod - lastClaimedPeriod;
            uint256 totalReward = _getRewardPerPeriod() * periods;
            pendingReward[user] += (userWeight[user] * totalReward) / totalWeight;
        }
        userLastClaimedTimestamp[user] = block.timestamp;
    }
          

    // 质押单个NFT
    function stake(address nft, uint256 tokenId) external nonReentrant onlySupportedNFT(nft) {
        _updateReward(msg.sender);

        IERC721(nft).transferFrom(msg.sender, address(this), tokenId);
        
        uint256 weight = _getWeight(nft);
        
        userStakes[msg.sender].push(StakeInfo(nft, tokenId, weight, block.timestamp));
        userWeight[msg.sender] += weight;
        totalWeight += weight;

        emit Staked(msg.sender, nft, tokenId);
    }

    //解押单个NFT
    function unstake(address nft, uint256 tokenId) external onlySupportedNFT(nft) {
        _updateReward(msg.sender);

        StakeInfo[] storage stakes = userStakes[msg.sender];
        uint256 len = stakes.length;
        for (uint256 i = 0; i < len; i++) {
            if (stakes[i].nft == nft && stakes[i].tokenId == tokenId) {
                uint256 weight = stakes[i].weight;
                totalWeight -= weight;
                userWeight[msg.sender] -= weight;

                IERC721(nft).transferFrom(address(this), msg.sender, tokenId);

                stakes[i] = stakes[len - 1];
                stakes.pop();

                emit Unstaked(msg.sender, nft, tokenId);
                return;
            }
        }

        revert("Stake not found");
    }



     //解押单种NFT
    function unstake(address nft) external onlySupportedNFT(nft) {
        _updateReward(msg.sender);

        StakeInfo[] storage stakes = userStakes[msg.sender];
        uint256 len = stakes.length;

        for (uint256 i = len; i > 0; i--) {
            uint256 idx = i - 1;
            if (stakes[idx].nft == nft) {
                uint256 weight = stakes[idx].weight;
                totalWeight -= weight;
                userWeight[msg.sender] -= weight;

                IERC721(nft).transferFrom(address(this), msg.sender, stakes[idx].tokenId);

                stakes[idx] = stakes[stakes.length - 1];
                stakes.pop();

                emit Unstaked(msg.sender, nft, stakes[idx].tokenId);
            }
        }
    }


    


    // 批量质押NFT
    function stakeBatch(address[] calldata nfts, uint256[] calldata tokenIds) external {
        require(nfts.length == tokenIds.length, "Length mismatch");
        _updateReward(msg.sender);

        for (uint256 i = 0; i < nfts.length; i++) {
            address nft = nfts[i];
            uint256 tokenId = tokenIds[i];
            require(nft == promptNFT || nft == memoryNFT || nft == memesNFT, "Unsupported NFT");
            IERC721(nft).transferFrom(msg.sender, address(this), tokenId);
            uint256 weight = _getWeight(nft);

            userStakes[msg.sender].push(StakeInfo({
                nft: nft,
                tokenId: tokenId,
                weight: weight,
                stakedAt: block.timestamp
            }));

            userWeight[msg.sender] += weight;
            totalWeight += weight;

            emit Staked(msg.sender, nft, tokenId);
        }
    }


    // 一键全部解押
    function unstakeAll() external {
        uint len = userStakes[msg.sender].length;
        require(len > 0, "No NFTs staked");
        _updateReward(msg.sender);

        for (uint i = len; i > 0; i--) {
            uint idx = i - 1;
            StakeInfo memory info = userStakes[msg.sender][idx];
            totalWeight -= info.weight;
            userWeight[msg.sender] -= info.weight;

            IERC721(info.nft).transferFrom(address(this), msg.sender, info.tokenId);

            emit Unstaked(msg.sender, info.nft, info.tokenId);
            userStakes[msg.sender].pop();
        }
        
    }


    // 领取奖励PTC
    function claim() external {
        _updateReward(msg.sender);
        uint256 reward = pendingReward[msg.sender];
        require(reward > 0, "Nothing to claim");
        
        require(ptc.balanceOf(address(this)) >= reward, "Insufficient PTC balance in contract");
        pendingReward[msg.sender] = 0;
        ptc.transfer(msg.sender, reward);

        emit Claimed(msg.sender, reward);
    }

    // 获取用户当前权重
    function getUserWeight(address user) external view returns (uint256) {
        return userWeight[user];
    }

    // 获取用户所有质押NFT信息
    function getStakedNFTs(address user) external view returns (StakeInfo[] memory) {
        return userStakes[user];
    }

    // 获取用户当前可领取PTC
    function claimable(address user) external view returns (uint256) {
        // 手动计算用户上次领取奖励后的周期数，并据此计算应得奖励
        uint256 currentPeriod = block.timestamp / PERIOD_DURATION;
        uint256 lastClaimedPeriod = userLastClaimedTimestamp[user] / PERIOD_DURATION;
        
        if (lastClaimedPeriod == 0) {
            // 如果用户从未领取过奖励，则将lastClaimedPeriod设置为当前周期
            lastClaimedPeriod = currentPeriod;
        }
        
        if (currentPeriod > lastClaimedPeriod && totalWeight > 0) {
            // 计算用户应得的奖励
            uint256 periods = currentPeriod - lastClaimedPeriod;
            uint256 totalReward = _getRewardPerPeriod() * periods;
            return (userWeight[user] * totalReward) / totalWeight;
        } else {
            // 如果用户在当前周期之前已经领取过奖励，或者没有质押任何NFT，则返回pendingReward中的值
            return pendingReward[user];
        }
    }


    // 查看当前周期奖励
    function currentRewardPerPeriod() external view returns (uint256) {
        return _getRewardPerPeriod();
    }

    //查看剩余可分发的 PTC 总量
    function getRemainingPTC() external view returns (uint256) {
        return ptc.balanceOf(address(this));
    }


    // 救援合约内误转入的ERC20代币（禁止PTC）
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(ptc), "禁止提取PTC代币");
        IERC20 erc20 = IERC20(token);
        uint256 balance = erc20.balanceOf(address(this));
        require(amount <= balance, "金额超出余额");
        erc20.transfer(to, amount);
    }

    // 救援合约内误转入的ETH
    function rescueETH(address payable to, uint256 amount) external onlyOwner {
        require(address(this).balance >= amount, "ETH余额不足");
        (bool success, ) = to.call{value: amount}("");
        require(success, "ETH转账失败");
    }

    // 救援合约内误转入的ERC721 NFT（禁止三种质押NFT）
    function rescueERC721(address nft, address to, uint256 tokenId) external onlyOwner {
        require(nft != promptNFT && nft != memoryNFT && nft != memesNFT, "禁止提取质押NFT");
        IERC721(nft).transferFrom(address(this), to, tokenId);
    }

}