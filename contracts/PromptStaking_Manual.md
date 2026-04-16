# PromptStaking V4.0 — 部署、接口与管理手册

## 目录

- [1. 合约概述](#1-合约概述)
- [2. 部署指南](#2-部署指南)
- [3. 释放规则](#3-释放规则)
- [4. 接口参考](#4-接口参考)
- [5. 管理员操作手册](#5-管理员操作手册)
- [6. 事件参考](#6-事件参考)
- [7. 错误码参考](#7-错误码参考)
- [8. 运维监控](#8-运维监控)
- [9. 应急预案](#9-应急预案)
- [10. 安全注意事项](#10-安全注意事项)

---

## 1. 合约概述

| 项目 | 内容 |
|------|------|
| 合约名 | `PromptStaking` |
| 版本 | V4.0 |
| Solidity | ^0.8.20 |
| 依赖 | OpenZeppelin v5 (Ownable, ReentrancyGuard, Pausable, ERC721Holder, SafeERC20) |
| 许可证 | MIT |

**核心机制**：用户质押 Prompt NFT 获取 PTC 代币奖励。奖励按全局积分累加器模型（MasterChef 模式）分配，每个 NFT 权重相同。管理员控制提现操作，并支持将用户的待领取奖励直接代扣至平台收款账户用于平台消费（无手续费）。

---

## 2. 部署指南

### 2.1 前置条件

部署前确保以下合约和地址已准备就绪：

| 名称 | 说明 | 类型 |
|------|------|------|
| PTC 代币合约 | 已部署的 ERC20 代币 | 合约地址 |
| Prompt NFT 合约 | 已部署的 ERC721 NFT | 合约地址 |
| 手续费接收地址 | 接收管理员提现手续费的地址 | EOA 或合约 |
| 销售地址 | 持有未售出 NFT 的地址 | EOA 或合约 |
| 缓冲池地址 | 接收未分配奖励的地址 | EOA 或合约 |
| NFT 发行总数 | Prompt NFT 的总发行量 | uint256 |
| 平台收款账户 | 接收平台代扣款的地址（部署后由 Owner 单独设置） | EOA 或合约 |

### 2.2 构造函数参数

```solidity
constructor(
    address _ptc,           // PTC 代币合约地址（不可为零地址）
    address _promptNFT,     // Prompt NFT 合约地址（不可为零地址）
    uint256 _startTime,     // 奖励起始时间戳，传 0 表示部署时立即开始
    address _feeRecipient,  // 手续费接收地址（不可为零地址）
    uint256 _totalNFTSupply,// NFT 发行总数（必须 > 0）
    address _salesAddress,  // 销售地址（不可为零地址）
    address _bufferPool     // 缓冲池地址（不可为零地址）
)
```

> **重要**：`_ptc` 和 `_promptNFT` 部署后不可修改（immutable）。`_totalNFTSupply` 和 `_salesAddress` 部署后也不可修改。请务必确认无误后再部署。

### 2.3 部署流程

**第一步：部署合约**

使用 Hardhat / Foundry / Remix 部署，传入所有构造参数。

**第二步：向合约转入 PTC**

合约本身不铸造 PTC，需要管理员预先将足够的 PTC 转入合约地址。

建议最少转入前 2 年释放量：
- 第一年：540,000,000 PTC
- 第二年：480,000,000 PTC
- 合计：1,020,000,000 PTC（10.2 亿）

```
ptc.transfer(stakingContractAddress, 1020000000 * 10**18)
```

**第三步：验证部署**

调用以下只读函数确认部署参数：

```
ptc()                    → 应返回 PTC 合约地址
promptNFT()              → 应返回 NFT 合约地址
startRewardTimestamp()   → 应返回正确的起始时间
feeRecipient()           → 应返回手续费接收地址
totalNFTSupply()         → 应返回 NFT 发行总数
salesAddress()           → 应返回销售地址
bufferPool()             → 应返回缓冲池地址
schedulePeriodTotals(0)  → 540000000000000000000000000 (5.4亿 ether)
schedulePeriodTotals(1)  → 480000000000000000000000000 (4.8亿 ether)
schedulePeriodTotals(2)  → 420000000000000000000000000 (4.2亿 ether)
schedulePeriodTotals(3)  → 360000000000000000000000000 (3.6亿 ether)
schedulePeriodTotals(4)  → 300000000000000000000000000 (3.0亿 ether)
```

**第四步：配置平台收款账户（可选，需启用平台代扣时必做）**

```solidity
setPlatformPaymentReceiver(platformReceiverAddress)
```

- 部署时 `platformPaymentReceiver` 默认为零地址，此时 `chargeUser` / `chargeUsers` 调用将 revert
- 设置非零地址后，Owner 才能调用平台代扣接口

**第五步：转移 Owner 至多签钱包**

```solidity
transferOwnership(multisigAddress)
```

建议使用 Gnosis Safe 多签钱包（至少 3/5 签名）。

### 2.4 不可修改参数（immutable/constant）

| 参数 | 值 | 说明 |
|------|------|------|
| `ptc` | 部署时确定 | PTC 代币合约，immutable |
| `promptNFT` | 部署时确定 | NFT 合约地址，immutable |
| `TOTAL_REWARD` | 3,000,000,000 ether | 总奖励 30 亿 |
| `REMAINING_AFTER_5_YEARS` | 900,000,000 ether | 前5年后剩余 9 亿 |
| `FRACTION` | 5000 | 第 6 年起每年释放 50% |
| `MAX_DYNAMIC_YEARS` | 100 | 动态释放最大年数 |
| `MAX_FEE_RATE` | 10000 | 手续费率上限 100% |
| `SCHEDULE_PERIOD_DURATION` | 365 days | 每个释放周期 365 天 |
| `BUFFER_WITHDRAWAL_DELAY` | 1 days | 缓冲池提现延迟 |

### 2.5 可修改参数

| 参数 | 修改函数 | 权限 |
|------|----------|------|
| `feeRecipient` | `setFeeRecipient(address)` | onlyOwner |
| `bufferPool` | `setBufferPool(address)` | onlyOwner |
| `platformPaymentReceiver` | `setPlatformPaymentReceiver(address)` | onlyOwner |
| `salesRatioUpdatePaused` | `emergencyPauseSalesRatioUpdate()` / `resumeSalesRatioUpdate()` | onlyOwner |
| 合约暂停状态 | `pause()` / `unpause()` | onlyOwner |

---

## 3. 释放规则

### 3.1 前 5 年固定释放

| 年份 | 释放比例 | 释放量（PTC） |
|------|---------|--------------|
| 第 1 年 | 18% | 540,000,000 |
| 第 2 年 | 16% | 480,000,000 |
| 第 3 年 | 14% | 420,000,000 |
| 第 4 年 | 12% | 360,000,000 |
| 第 5 年 | 10% | 300,000,000 |
| **合计** | **70%** | **2,100,000,000** |

### 3.2 第 6 年起动态释放

剩余 900,000,000 PTC（+ 管理员注入的额外金额）按每年释放年初剩余量的 50% 逐年减半：

| 年份 | 年初剩余 | 当年释放 |
|------|---------|---------|
| 第 6 年 | 900,000,000 | 450,000,000 |
| 第 7 年 | 450,000,000 | 225,000,000 |
| 第 8 年 | 225,000,000 | 112,500,000 |
| 第 9 年 | 112,500,000 | 56,250,000 |
| 第 10 年 | 56,250,000 | 28,125,000 |
| ... | 逐年减半 | ... |

### 3.3 奖励分配机制

每次结算时，释放的奖励按销售比例分为两部分：

```
销售比例 = (NFT发行总数 - 销售地址持有的NFT数量) / NFT发行总数

用户可得奖励 = 释放量 × 销售比例
缓冲池奖励   = 释放量 × (1 - 销售比例)
```

- 销售比例有 1 小时缓存，每小时最多刷新一次
- 支持紧急暂停销售比例更新
- 无人质押期间的释放量全部进入缓冲池

---

## 4. 接口参考

### 4.1 用户接口（任何人均可调用）

#### `stake(uint256 tokenId)`
质押单个 NFT。

- 前置条件：用户需先 `approve` 合约地址
- 修饰符：`nonReentrant`, `whenNotPaused`

#### `stakeBatch(uint256[] calldata tokenIds)`
批量质押多个 NFT。

- 前置条件：用户需先 `setApprovalForAll` 或逐个 `approve`
- 修饰符：`nonReentrant`, `whenNotPaused`
- 注意：数量过大可能导致 gas 超出区块限制，建议链下控制批量大小

#### `unstake(uint256 tokenId)`
解押单个 NFT，同时结算奖励到 `pendingReward`。

- 修饰符：`nonReentrant`, `whenNotPaused`

#### `unstakeBatch(uint256[] calldata tokenIds)`
批量解押多个 NFT。

- 修饰符：`nonReentrant`, `whenNotPaused`

#### `unstakeAll()`
一键解押用户所有 NFT。

- 修饰符：`nonReentrant`, `whenNotPaused`
- 注意：NFT 数量过多时可能 gas 不足

#### `emergencyUnstakeBatch(uint256 count)`
紧急批量解押（仅合约暂停时可用）。

- 修饰符：`nonReentrant`, `whenPaused`
- 不结算奖励，保留 `rewardDebt` 以便恢复后正常领取
- `count` 控制每次解押数量，防止 gas 超限

### 4.2 管理员接口（仅 Owner）

#### 提现操作

| 函数 | 说明 |
|------|------|
| `withdrawForUser(address user, uint256 feeRate)` | 为单个用户提现全部可领取奖励 |
| `withdrawForUser(address user, uint256 amount, uint256 feeRate)` | 为单个用户提现指定数量奖励 |
| `withdrawForUsers(address[] _users, uint256[] feeRates)` | 批量为用户提现全部可领取奖励 |
| `withdrawForUsers(address[] _users, uint256[] amounts, uint256[] feeRates)` | 批量为用户提现指定数量奖励 |

**feeRate 说明**：单位 1/10000。100 = 1%，500 = 5%，10000 = 100%。

#### 平台代扣款操作（用于用户在平台消费）

| 函数 | 说明 |
|------|------|
| `chargeUser(address user, uint256 amount)` | 将单个用户指定数量的待领取奖励直接划转至平台收款账户 |
| `chargeUsers(address[] _users, uint256[] amounts)` | 批量为多个用户按各自指定数量进行代扣 |

**特性说明**：

- **无手续费**：全额转入 `platformPaymentReceiver`，不抽取任何比例
- **仅扣待领取部分**：从用户 `pendingReward` 中扣减，不会影响其已质押的 NFT
- **必须预先设置**：调用前须通过 `setPlatformPaymentReceiver` 配置平台收款账户，否则 revert `PlatformReceiverNotSet`
- **会计口径**：代扣金额会累加到用户 `claimed`、全局 `totalClaimedPTC` 以及独立统计的 `totalPlatformCharged`
- **修饰符**：`onlyOwner`、`nonReentrant`、`whenNotPaused`
- **金额要求**：`amount` 必须 > 0 且 ≤ 用户当前 `pendingReward`（结算后）

#### 平台解押

| 函数 | 说明 |
|------|------|
| `unstakeBatchPlatform(uint256[] tokenIds)` | 管理员强制解押任意 NFT 返还给原质押用户（含结算） |

#### 缓冲池管理

| 函数 | 说明 |
|------|------|
| `requestBufferWithdrawal(uint256 amount)` | 请求提现缓冲池（开始 1 天等待期） |
| `cancelBufferWithdrawal()` | 取消待处理的缓冲池提现请求 |
| `executeBufferWithdrawal()` | 执行缓冲池提现（需等待 1 天延迟后） |

#### 参数设置

| 函数 | 说明 |
|------|------|
| `setFeeRecipient(address)` | 设置手续费接收地址 |
| `setBufferPool(address)` | 设置缓冲池地址 |
| `setPlatformPaymentReceiver(address)` | 设置平台代扣款收款账户地址 |
| `emergencyPauseSalesRatioUpdate()` | 紧急暂停销售比例更新 |
| `resumeSalesRatioUpdate()` | 恢复销售比例更新 |
| `pause()` | 暂停合约（阻止质押/解押/提现等常规操作） |
| `unpause()` | 恢复合约 |

#### 救援功能

| 函数 | 说明 |
|------|------|
| `rescueERC20(address token, uint256 amount)` | 救援误转入的 ERC20 代币（禁止 PTC） |
| `rescueERC721(address nft, uint256 tokenId)` | 救援误转入的 ERC721 NFT（禁止 Prompt NFT） |
| `rescueGAS(uint256 amount)` | 救援误转入的主网币 |

#### 额外奖励注入

| 函数 | 说明 |
|------|------|
| `addAdditionalReward(uint256 amount)` | 第 6 年后注入额外奖励，加入动态释放池 |

- 仅在 `startRewardTimestamp + 5年` 之后可调用
- 调用前需先 `ptc.approve(stakingContract, amount)`
- 会从调用者账户转入 PTC

### 4.3 只读查询接口

#### 用户查询

| 函数 | 返回值 | 说明 |
|------|--------|------|
| `claimable(address user)` | `uint256` | 用户当前可领取的 PTC 数量（含实时累积） |
| `getUserSummary(address user)` | `(stakeCount, claimableAmount, claimed)` | 用户概览：质押数量、可领取、已领取 |
| `getStakedNFTs(address user, uint256 offset, uint256 limit)` | `StakeInfo[]` | 用户质押的 NFT 列表（分页） |
| `getStakedNFTsCount(address user)` | `uint256` | 用户质押的 NFT 总数 |
| `getStakedNFTOwner(uint256 tokenId)` | `address` | 查询某个 NFT 当前的质押者 |
| `users(address)` | `(rewardDebt, pendingReward, claimed)` | 用户原始数据（不含实时累积） |

#### 全局查询

| 函数 | 返回值 | 说明 |
|------|--------|------|
| `getSystemStats()` | 8 个 uint256 | 全局统计信息 |
| `getTotalAllocatedPTC()` | `uint256` | 已分配给用户的 PTC 总量（含实时未结算部分） |
| `emittedUntil(uint256 t)` | `uint256` | 从开始到时间 t 的累计释放量 |
| `getProtectedSalesRatioView()` | `uint256` | 当前销售比例（1e18 精度） |
| `platformPaymentReceiver()` | `address` | 当前平台代扣款收款账户 |
| `totalPlatformCharged()` | `uint256` | 全局累计平台代扣总量（PTC） |

#### `getSystemStats()` 返回值明细

| 字段 | 说明 |
|------|------|
| `_totalStakeCount` | 全局质押 NFT 总数 |
| `_accRewardPerWeight` | 全局积分累加器（1e18 精度） |
| `_lastRewardTimestamp` | 上次奖励计算时间 |
| `_startRewardTimestamp` | 奖励起始时间 |
| `_bufferPoolReward` | 缓冲池累计奖励 |
| `_totalClaimedPTC` | 已发放给用户的 PTC 净额 |
| `_totalFeesPaid` | 累计手续费总额 |
| `_totalPendingReward` | 全局待领取奖励 |

---

## 5. 管理员操作手册

### 5.1 日常提现操作

**为单个用户提现全部奖励（3% 手续费）：**
```solidity
withdrawForUser(userAddress, 300)  // 300 = 3%
```

**为单个用户提现指定数量（5% 手续费）：**
```solidity
withdrawForUser(userAddress, 1000 ether, 500)  // 500 = 5%
```

**批量提现全部奖励（每人手续费可不同）：**
```solidity
withdrawForUsers(
    [user1, user2, user3],
    [300, 300, 500]  // user1和user2收3%，user3收5%
)
```

**批量提现指定金额（每人金额和手续费可不同）：**
```solidity
withdrawForUsers(
    [user1, user2],
    [1000 ether, 500 ether],
    [300, 300]
)
```

### 5.2 平台代扣款操作（用户在平台消费）

**使用前置条件**：必须先通过 `setPlatformPaymentReceiver` 配置平台收款账户。

**设置平台收款账户（首次使用或变更时）：**
```solidity
setPlatformPaymentReceiver(platformReceiverAddress)
```

**为单个用户代扣指定金额（无手续费）：**
```solidity
chargeUser(userAddress, 500 ether)
```

**批量代扣多个用户指定金额（无手续费，每人金额可不同）：**
```solidity
chargeUsers(
    [user1, user2, user3],
    [500 ether, 200 ether, 1000 ether]
)
```

**注意事项**：

- 代扣金额会从用户 `pendingReward` 扣减，并累加至 `claimed`、`totalClaimedPTC`、`totalPlatformCharged`
- 与 `withdrawForUser` 相比无手续费，PTC 全额进入 `platformPaymentReceiver`
- 若某个用户的 `pendingReward` 不足 `amount`，整笔交易 revert（`AmountExceedsPending`），请先调用 `claimable(user)` 查询后再下发

### 5.3 缓冲池提现操作（两步走 + 1 天等待期）

```
第一步：requestBufferWithdrawal(amount)   → 发起请求
等待：  至少 1 天（86400 秒）
第二步：executeBufferWithdrawal()          → 执行提现

如需取消：cancelBufferWithdrawal()
```

### 5.4 第 6 年后注入额外奖励

```
第一步：ptc.approve(stakingContract, amount)   → 授权 PTC
第二步：addAdditionalReward(amount)             → 注入奖励
```

注入的金额将与剩余的 9 亿 PTC 合并，按 50% 年减半规则继续释放。

### 5.5 平台强制解押

适用场景：到期回收、司法要求、合规需要。

```solidity
unstakeBatchPlatform([tokenId1, tokenId2, tokenId3])
```

- 会自动结算用户的待领取奖励
- NFT 直接返还给原质押用户
- 建议将同一用户的 tokenId 排列在一起以节省 gas

---

## 6. 事件参考

| 事件 | 参数 | 触发时机 |
|------|------|---------|
| `Staked` | `user(indexed), tokenId(indexed)` | 质押 NFT |
| `Unstaked` | `user(indexed), tokenId(indexed)` | 解押 NFT |
| `Claimed` | `user(indexed), amount` | 用户领取 PTC（amount 为扣除手续费后的净额） |
| `EmergencyUnstake` | `user(indexed), tokenId(indexed)` | 紧急解押 |
| `BufferPoolWithdrawalRequested` | `admin(indexed), amount, requestTime` | 请求缓冲池提现 |
| `BufferPoolWithdrawalCancelled` | `admin(indexed)` | 取消缓冲池提现 |
| `BufferPoolWithdrawn` | `admin(indexed), amount` | 执行缓冲池提现 |
| `BufferPoolSet` | `admin(indexed), newBufferPool` | 设置缓冲池地址 |
| `FeeRecipientSet` | `admin(indexed), newFeeRecipient` | 设置手续费地址 |
| `PlatformPaymentReceiverSet` | `admin(indexed), newReceiver` | 设置平台代扣收款账户 |
| `PlatformCharged` | `user(indexed), receiver(indexed), amount` | 平台代扣款执行 |
| `SalesRatioUpdatePaused` | `admin(indexed)` | 暂停销售比例更新 |
| `SalesRatioUpdateResumed` | `admin(indexed)` | 恢复销售比例更新 |
| `AdditionalRewardAdded` | `admin(indexed), amount` | 注入额外奖励 |
| `ERC20Rescued` | `operator(indexed), token, amount` | 救援 ERC20 |
| `ERC721Rescued` | `operator(indexed), nft, tokenId` | 救援 ERC721 |
| `GASRescued` | `operator(indexed), amount` | 救援主网币 |

---

## 7. 错误码参考

| 错误码 | 触发条件 |
|--------|---------|
| `ZeroAddress` | 传入零地址 |
| `InvalidSupply` | NFT 发行总数为 0 |
| `StartTimeInvalid` | 起始时间在过去 |
| `AlreadyStaked` | NFT 已被质押 |
| `NotStakeOwner` | 不是该 NFT 的质押者 |
| `TokenNotStaked` | NFT 未处于质押状态 |
| `NoTokenIds` | tokenIds 数组为空 |
| `NoStaked` | 用户无质押的 NFT |
| `FeeRateTooHigh` | 手续费率超过 10000 (100%) |
| `NoClaimable` | 无可领取的奖励 |
| `AmountZero` | 金额为 0 |
| `AmountExceedsPending` | 提现金额超过可领取奖励 |
| `InsufficientBalance` | 合约主网币余额不足 |
| `LengthMismatch` | 批量操作的数组长度不一致 |
| `CannotRescuePTC` | 不允许救援 PTC 代币 |
| `CannotRescueStakedNFT` | 不允许救援 Prompt NFT |
| `TransferFailed` | 主网币转账失败 |
| `NoPendingWithdrawal` | 没有待处理的缓冲池提现请求 |
| `WithdrawalDelayNotMet` | 缓冲池提现延迟未满 |
| `BufferPoolNotSet` | 缓冲池地址未设置 |
| `InsufficientBufferPool` | 缓冲池余额不足 |
| `TooEarlyForAdditional` | 尚未到第 6 年，不能注入额外奖励 |
| `PlatformReceiverNotSet` | 未设置 `platformPaymentReceiver` 就调用代扣接口 |
| `EmptyUserList` | 平台代扣的批量用户数组为空 |

---

## 8. 运维监控

### 8.1 资金平衡监控

定期检查以下恒等式（允许 wei 级误差）：

```
emittedUntil(now) ≈ bufferPoolReward + totalClaimedPTC + totalFeesPaid + totalPendingReward + 未结算部分
```

简化监控公式（调用合约函数）：

```
emittedUntil(block.timestamp)  ≈  getTotalAllocatedPTC() + bufferPoolReward + totalFeesPaid
```

> 说明：`totalClaimedPTC` 已同时包含「用户直接领取净额」与「平台代扣总额」。如需单独核对平台消费，可用：
> `totalPlatformCharged ≤ totalClaimedPTC`

### 8.2 PTC 余额充裕性监控

```
ptc.balanceOf(stakingContract)  ≥  totalPendingReward + bufferPoolReward
```

如果 PTC 余额不足以覆盖未来释放，需及时补充。

### 8.3 关键指标日报

建议每日采集并记录以下指标：

| 指标 | 数据来源 | 关注点 |
|------|---------|--------|
| 总质押 NFT 数 | `totalStakeCount` | 质押率趋势 |
| 累计已发放 PTC | `totalClaimedPTC` | 发放进度 |
| 累计手续费 | `totalFeesPaid` | 手续费收入 |
| 累计平台代扣 | `totalPlatformCharged` | 平台消费代扣规模（已含在 `totalClaimedPTC` 内） |
| 缓冲池累计 | `bufferPoolReward` | 未分配奖励规模 |
| 待领取总量 | `totalPendingReward` | 用户未提现的奖励规模 |
| 合约 PTC 余额 | `ptc.balanceOf(contract)` | 余额充裕性 |
| 销售比例 | `getProtectedSalesRatioView()` | NFT 销售进度 |
| 累计释放量 | `emittedUntil(now)` | 释放进度 vs 预期 |

### 8.4 各年释放量验证

部署后可通过以下方式验证释放计划是否正确：

```
emittedUntil(startRewardTimestamp + 365 days) = 540,000,000 ether  (第1年末)
emittedUntil(startRewardTimestamp + 730 days) = 1,020,000,000 ether (第2年末)
emittedUntil(startRewardTimestamp + 1095 days) = 1,440,000,000 ether (第3年末)
emittedUntil(startRewardTimestamp + 1460 days) = 1,800,000,000 ether (第4年末)
emittedUntil(startRewardTimestamp + 1825 days) = 2,100,000,000 ether (第5年末)
emittedUntil(startRewardTimestamp + 2190 days) = 2,550,000,000 ether (第6年末)
emittedUntil(startRewardTimestamp + 2555 days) = 2,775,000,000 ether (第7年末)
```

---

## 9. 应急预案

### 9.1 发现合约漏洞

1. 立即调用 `pause()` 暂停合约
2. 评估漏洞影响范围
3. 如果涉及销售比例操纵，调用 `emergencyPauseSalesRatioUpdate()`
4. 通知用户通过 `emergencyUnstakeBatch(count)` 取回 NFT
5. 制定修复方案，必要时部署新合约并迁移

### 9.2 外部合约被攻击（NFT 合约或 PTC 合约）

1. 调用 `emergencyPauseSalesRatioUpdate()` 冻结销售比例
2. 调用 `pause()` 暂停合约
3. 评估影响后决定后续操作

### 9.3 Owner 私钥泄露

1. 立即通过多签发起 `transferOwnership()` 转移至新的多签钱包
2. 检查是否有异常操作（监控事件日志）

### 9.4 PTC 余额即将不足

1. 向合约地址转入更多 PTC
2. 临时暂停批量提现，优先保障单笔提现

### 9.5 用户 NFT 无法取回（gas 不足）

如果用户质押了过多 NFT 导致 `unstakeAll` gas 超限：
- 使用 `unstakeBatch` 分批解押
- 暂停时可使用 `emergencyUnstakeBatch(count)` 按数量分批

---

## 10. 安全注意事项

### 10.1 Owner 权限

Owner 拥有以下重要权限，必须通过多签钱包管控：

- 为用户提现（可设置任意手续费率，最高 100%）
- 将用户的待领取奖励代扣至平台收款账户（无手续费，用于平台消费场景）
- 暂停/恢复合约
- 强制解押用户的 NFT
- 提取缓冲池资金
- 修改手续费接收地址、缓冲池地址、平台代扣款收款账户
- 救援合约内的其他代币/ETH

**强烈建议**：部署后立即将 Owner 转移至 Gnosis Safe 多签钱包（至少 3/5）。

### 10.2 不可逆操作

- `transferOwnership`：Owner 转移不可撤销
- 构造函数参数（`ptc`, `promptNFT`, `totalNFTSupply`, `salesAddress`）：部署后永久固定
- 已发放的 PTC 奖励不可回收

### 10.3 PTC 代币安全

- `rescueERC20` 禁止救援 PTC 代币，防止管理员挪用质押奖励
- `rescueERC721` 禁止救援 Prompt NFT 合约的任何 NFT
- 缓冲池提现有 1 天时间锁保护

### 10.4 批量操作 gas 管理

合约未设置批量操作的硬性数量上限，需在链下管理：

| 操作 | 建议单次上限 | 说明 |
|------|-------------|------|
| `stakeBatch` | 100-200 个 | 受 NFT 转账 gas 成本限制 |
| `unstakeBatch` | 100-200 个 | 受 NFT 转账 gas 成本限制 |
| `withdrawForUsers` | 200-500 个 | 受 PTC 转账 gas 成本限制 |
| `chargeUsers` | 200-500 个 | 受 PTC 转账 gas 成本限制 |
| `unstakeBatchPlatform` | 100-200 个 | 受 NFT 转账 gas 成本限制 |

建议上线前在目标链上实测确定最优批量大小。
