# PromptStaking 合约更新文档

## 更新概述

本次更新对 PromptStaking.sol 合约进行了重大修改，主要包括：

1. **奖励计算机制升级**：引入销售比例调整和缓冲池机制
2. **提现机制重构**：从用户自助提现改为管理员完全控制
3. **移除限制机制**：删除所有提现限制和时间锁相关代码
4. **新增管理员功能**：添加池子管理和缓冲池操作

## 详细修改内容

### 1. 奖励计算机制升级

#### 销售比例计算
- **新增变量**：
  - `uint256 public totalNFTSupply`：NFT发行总数
  - `address public salesAddress`：销售地址
- **计算逻辑**：
  - 已销售NFT数量 = `totalNFTSupply - IERC721(promptNFT).balanceOf(salesAddress)`
  - 销售比例 = `已销售数量 / totalNFTSupply`
  - 用户奖励 = `总释放奖励 × 销售比例`
  - 缓冲池奖励 = `总释放奖励 - 用户奖励`

#### 缓冲池机制
- **新增变量**：
  - `address public bufferPool`：缓冲池地址
  - `uint256 public bufferPoolReward`：缓冲池奖励总量
- **功能**：
  - 每次奖励计算时，剩余部分自动进入缓冲池
  - 管理员可以设置缓冲池地址
  - 管理员可以随时从缓冲池提现奖励

### 2. 提现机制重构

#### 移除用户自助提现
- 删除了所有用户直接调用提现的功能
- 用户现在无法自行提取奖励

#### 管理员控制提现
- **保留函数**：
  - `withdrawForUser(address user, uint256 feeRate)`：为单个用户提现全部奖励
  - `withdrawForUser(address user, uint256 amount, uint256 feeRate)`：为单个用户提现指定金额
  - `withdrawForUsers(address[] users, uint256[] feeRates)`：批量提现全部奖励
  - `withdrawForUsers(address[] users, uint256[] amounts, uint256[] feeRates)`：批量提现指定金额
- **特点**：
  - 仅管理员（owner）可调用
  - 支持手续费扣除
  - 手续费转给 `feeRecipient` 地址

### 3. 移除限制机制

#### 删除的变量
- `withdrawalLimitDuration`：提现限制时间
- `withdrawalLimitRate`：提现限制比例
- `pendingWithdrawalLimitDuration`：待变更限制时间
- `pendingWithdrawalLimitRate`：待变更限制比例
- `withdrawalLimitChangeTime`：变更时间锁
- `WITHDRAWAL_CHANGE_DELAY`：时间锁延迟常量

#### 删除的函数
- `getWithdrawalLimitInfo()`：获取提现限制信息
- `allowedClaimable()`：查询允许提现金额
- `_allowedClaimAmount()`：计算允许提现金额
- `proposeWithdrawalLimitChange()`：提议变更提现限制
- `applyWithdrawalLimitChange()`：应用提现限制变更

#### 删除的事件
- `WithdrawalLimitProposed`：提现限制提议事件
- `WithdrawalLimitChanged`：提现限制变更事件

### 4. 构造函数修改

#### 参数变更
**旧构造函数**：
```solidity
constructor(
    address _ptc,
    address _promptNFT,
    uint256 _startTime,
    address _feeRecipient,
    uint256 _withdrawalLimitDuration,
    uint256 _withdrawalLimitRate
)
```

**新构造函数**：
```solidity
constructor(
    address _ptc,
    address _promptNFT,
    uint256 _startTime,
    address _feeRecipient,
    uint256 _totalNFTSupply,
    address _salesAddress
)
```

### 5. 新增管理员功能

#### 池子管理
- `addToPool(uint256 amount)`：管理员添加PTC到合约池子
- 事件：`PoolAdded(address admin, uint256 amount)`

#### 缓冲池管理
- `setBufferPool(address _bufferPool)`：设置缓冲池地址
- `withdrawBufferPool(uint256 amount)`：从缓冲池提现奖励
- 事件：
  - `BufferPoolSet(address admin, address newBufferPool)`
  - `BufferPoolWithdrawn(address admin, uint256 amount)`

### 6. 核心函数修改

#### `_updateGlobal()` 函数
```solidity
// 计算已销售NFT数量
uint256 sold = totalNFTSupply - IERC721(promptNFT).balanceOf(salesAddress);
// 计算比例因子
uint256 ratio = sold * 1e18 / totalNFTSupply;
// 调整奖励
uint256 adjustedReward = reward * ratio / 1e18;
// 剩余部分进入缓冲池
bufferPoolReward += reward - adjustedReward;
// 分配给用户
accRewardPerWeight += adjustedReward * 1e18 / totalStakeCount;
```

#### `_emittedUntil()` 函数
```solidity
// 动态释放计算时扣除缓冲池奖励
uint256 remaining = ptc.balanceOf(address(this)) - totalPendingReward - bufferPoolReward;
```

#### `claimable()` 函数
- 修复了奖励预估计算，确保与 `_updateGlobal()` 保持一致
- 正确应用销售比例因子

#### `getSystemStats()` 函数
- 新增返回 `bufferPoolReward` 参数

## 影响分析

### 对现有用户的影響
- **质押/解押**：不受影响，功能保持不变
- **奖励计算**：现在会根据NFT销售情况调整奖励比例
- **提现**：用户无法自行提现，必须通过管理员操作

### 对管理员的影响
- **新增职责**：需要主动为用户提现奖励
- **新增功能**：可以管理缓冲池和添加池子资金
- **简化管理**：无需处理提现限制和时间锁

### 对合约安全性的影响
- **安全性提升**：管理员完全控制资金流向
- **简化逻辑**：移除复杂的限制机制，降低出错风险
- **新增风险**：管理员操作失误可能影响用户体验

## 部署注意事项

1. **构造函数参数**：部署时需要提供 `totalNFTSupply` 和 `salesAddress`
2. **缓冲池设置**：部署后需要调用 `setBufferPool()` 设置缓冲池地址
3. **销售地址**：确保 `salesAddress` 是正确的NFT销售合约地址
4. **NFT供应量**：`totalNFTSupply` 必须准确反映实际NFT发行总量

## 测试建议

1. **奖励计算测试**：
   - 验证不同销售比例下的奖励分配
   - 测试缓冲池奖励累积和提现

2. **提现功能测试**：
   - 验证管理员提现功能正常
   - 测试批量提现和手续费计算

3. **边界情况测试**：
   - NFT全部售出时的奖励计算
   - 缓冲池地址变更后的提现
   - 销售地址持有量变化的影响

## 版本信息

- **更新日期**：2026年3月21日
- **合约版本**：PromptStaking V3
- **Solidity版本**：^0.8.20
- **主要变更**：奖励机制重构 + 管理员控制提现</content>
<parameter name="filePath">d:\GitHub\TheBook\docs\staking-contract-updates.md