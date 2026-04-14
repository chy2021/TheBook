# TokenVestingManager + MonthlyVesting — 合约说明文档

## 目录

- [1. 概述](#1-概述)
- [2. TokenVestingManager](#2-tokenvestingmanager)
- [3. MonthlyVesting](#3-monthlyvesting)
- [4. 部署指南](#4-部署指南)
- [5. 管理员操作手册](#5-管理员操作手册)
- [6. 接口参考](#6-接口参考)
- [7. 事件参考](#7-事件参考)
- [8. 三种归属模式对比](#8-三种归属模式对比)
- [9. 运维注意事项](#9-运维注意事项)

---

## 1. 概述

| 项目 | TokenVestingManager | MonthlyVesting |
|------|-------------------|----------------|
| 角色 | 工厂合约 + 管理合约 | 子合约（由 Manager 自动部署） |
| Solidity | ^0.8.20 | ^0.8.20 |
| 依赖 | OpenZeppelin v5 (Ownable, ReentrancyGuard, SafeERC20, VestingWallet) | OpenZeppelin v5 (ReentrancyGuard, SafeERC20) |
| 许可证 | MIT | MIT |

**架构关系**：

```
TokenVestingManager (Owner 管理)
  ├── 直接转账（一次性发放，无子合约）
  ├── MonthlyVesting（按月等额释放子合约）
  └── VestingWallet（OZ 线性释放子合约，向后兼容）
```

---

## 2. TokenVestingManager

### 核心功能

- **创建归属计划**：支持三种模式（直接转账 / 按月释放 / 线性释放）
- **记录管理**：维护 `vestings` 数组，记录所有已创建的归属计划
- **记录清理**：已释放完毕的归属可从数组中移除
- **资产救援**：支持提取误转入的非主代币

### 资金来源

创建归属时，Manager 按以下优先级选择资金来源：
1. 优先使用合约自身的代币余额
2. 余额不足时，从 `msg.sender` 通过 `transferFrom` 转入（需提前 approve）

### 不可变参数

| 参数 | 说明 |
|------|------|
| `token` | 归属的 ERC20 代币地址（immutable） |
| `tgeTimestamp` | TGE 时间戳，归属起始时间的基准点（immutable） |

---

## 3. MonthlyVesting

### 核心功能

- **按月等额释放**：将总分配量平均分成 N 个月，每月释放相同数量
- **余数处理**：如果总量不能被月数整除，余数在最后一个月追加释放
- **任何人可触发**：`release()` 函数任何人均可调用，将到期部分发放给受益人
- **累积释放**：如果多月未调用 `release()`，会一次性释放所有到期月份的总额

### 不可变参数

| 参数 | 说明 |
|------|------|
| `token` | ERC20 代币地址 |
| `beneficiary` | 受益人地址 |
| `start` | 第一期可领取的时间戳 |
| `monthSeconds` | 每月的秒数（如 30 天 = 2592000） |
| `months` | 总期数（上限 1200 期 = 100 年） |
| `totalAmount` | 总分配量 |
| `monthlyAmount` | 每月释放量 = totalAmount / months（向下取整） |
| `remainder` | 余数 = totalAmount % months（最后一月追加） |

### 可变状态

| 参数 | 说明 |
|------|------|
| `releasedMonths` | 已释放的月数 |

---

## 4. 部署指南

### 第一步：部署 TokenVestingManager

```solidity
constructor(IERC20 _token, uint256 _tgeTimestamp)
```

| 参数 | 说明 |
|------|------|
| `_token` | PTC 代币合约地址（不可为零地址） |
| `_tgeTimestamp` | TGE 时间戳（传 0 则使用部署时间） |

### 第二步：向 Manager 充值代币

```
ptc.transfer(managerAddress, totalAmountNeeded)
```

或者在每次 `createVesting` 前 approve：

```
ptc.approve(managerAddress, amount)
```

### 第三步：部署后验证

```
token()         → 应返回 PTC 合约地址
tgeTimestamp()  → 应返回正确的 TGE 时间戳
vestingCount()  → 0（初始无归属记录）
owner()         → 部署者地址
```

### 第四步：转移 Owner 至多签钱包

```solidity
transferOwnership(multisigAddress)
```

---

## 5. 管理员操作手册

### 5.1 创建直接转账（一次性发放）

```solidity
createVesting(
    beneficiary,     // 受益人地址
    amount,          // 代币数量
    cliffSeconds,    // 从 TGE 到发放的延迟秒数（通常为 0）
    0,               // durationSeconds = 0 表示直接转账
    false,           // 非按月模式
    0,               // months 无效
    0                // monthSeconds 无效
)
```

代币立即转给受益人，无锁定。

### 5.2 创建按月释放

```solidity
createVesting(
    beneficiary,     // 受益人地址
    amount,          // 代币总量
    cliffSeconds,    // 从 TGE 到首次可领取的延迟秒数
    0,               // durationSeconds = 0
    true,            // 按月模式
    12,              // 分 12 个月释放
    2592000          // 每月 30 天 = 2592000 秒
)
```

Manager 会自动部署一个 MonthlyVesting 子合约，并将代币转入。

### 5.3 批量创建归属

```solidity
createVestingBatch([
    { beneficiary: addr1, amount: 1000e18, cliffSeconds: 0, durationSeconds: 0, monthly: true, months: 12, monthSeconds: 2592000 },
    { beneficiary: addr2, amount: 500e18, cliffSeconds: 0, durationSeconds: 0, monthly: false, months: 0, monthSeconds: 0 },
    // ...
])
```

### 5.4 查看归属记录

```solidity
vestingCount()       // 总记录数
vestingAt(0)         // 查看第 0 条记录
```

返回 `VestingRecord` 结构体：

| 字段 | 说明 |
|------|------|
| `beneficiary` | 受益人地址 |
| `vestingWallet` | 子合约地址（直接转账为 address(0)） |
| `amount` | 分配的代币数量 |
| `start` | 归属开始时间戳 |
| `duration` | 线性释放持续时间（仅 VestingWallet 模式） |
| `monthly` | 是否按月释放 |
| `months` | 月数（仅按月模式） |
| `monthSeconds` | 每月秒数（仅按月模式） |

### 5.5 清理已完成的归属记录

```solidity
canRemoveVesting(idx)  // 检查是否可移除
removeVesting(idx)     // 移除记录
```

移除条件：
- 直接转账类型 → 始终可移除
- 子合约类型 → 子合约代币余额为 0 时可移除

注意：移除使用 swap-and-pop，会改变最后一条记录的索引。

### 5.6 受益人领取（MonthlyVesting）

受益人或任何人调用子合约的 `release()` 函数：

```solidity
MonthlyVesting(vestingWalletAddress).release()
```

---

## 6. 接口参考

### 6.1 TokenVestingManager

#### 管理员接口（仅 Owner）

| 函数 | 说明 |
|------|------|
| `createVesting(...)` | 创建单条归属记录 |
| `createVestingBatch(VestingInput[])` | 批量创建归属记录 |
| `removeVesting(uint256 idx)` | 移除已完成的归属记录 |
| `rescueERC20(address token, address to, uint256 amount)` | 救援误转入的非主代币 |

#### 查询接口

| 函数 | 返回 | 说明 |
|------|------|------|
| `token()` | `IERC20` | 主代币地址 |
| `tgeTimestamp()` | `uint256` | TGE 时间戳 |
| `vestingCount()` | `uint256` | 归属记录总数 |
| `vestingAt(uint256 idx)` | `VestingRecord` | 指定索引的归属记录 |
| `canRemoveVesting(uint256 idx)` | `bool` | 是否可移除该记录 |

### 6.2 MonthlyVesting

#### 操作接口

| 函数 | 说明 |
|------|------|
| `release()` | 释放所有到期的月份给受益人（任何人可调用） |

#### 查询接口

| 函数 | 返回 | 说明 |
|------|------|------|
| `token()` | `IERC20` | 代币地址 |
| `beneficiary()` | `address` | 受益人 |
| `start()` | `uint64` | 首期可领取时间 |
| `monthSeconds()` | `uint64` | 每月秒数 |
| `months()` | `uint32` | 总期数 |
| `totalAmount()` | `uint256` | 总分配量 |
| `monthlyAmount()` | `uint256` | 每月释放量 |
| `remainder()` | `uint256` | 最后一月的追加余数 |
| `releasedMonths()` | `uint32` | 已释放月数 |
| `releasableAmount()` | `uint256` | 当前可领取的代币数量 |
| `availableMonths()` | `uint32` | 当前到期但未释放的月数 |
| `monthsRemaining()` | `uint32` | 剩余未释放的月数 |
| `nextReleasableTimestamp()` | `uint64` | 下一期可领取的时间戳（0 表示已全部释放） |
| `remaining()` | `uint256` | 合约内剩余的代币余额 |
| `payableMonths()` | `uint32` | 当前余额能支付的到期月数 |

---

## 7. 事件参考

### TokenVestingManager

| 事件 | 参数 | 触发时机 |
|------|------|---------|
| `VestingCreated` | `beneficiary(indexed), vestingWallet(indexed), amount, start, duration, monthly, months, monthSeconds` | 创建归属（按月或线性） |
| `DirectTransfer` | `beneficiary(indexed), amount` | 直接转账 |
| `VestingRemoved` | `index(indexed), beneficiary(indexed), vestingWallet, amount` | 移除归属记录 |
| `ERC20Rescued` | `operator(indexed), token, to, amount` | 救援 ERC20 |

### MonthlyVesting

| 事件 | 参数 | 触发时机 |
|------|------|---------|
| `Released` | `to(indexed), amount, monthsReleased` | 释放代币给受益人 |

---

## 8. 三种归属模式对比

| 特性 | 直接转账 | 按月释放 (MonthlyVesting) | 线性释放 (VestingWallet) |
|------|---------|--------------------------|------------------------|
| 子合约 | 无 | 自动部署 | 自动部署 |
| 锁定期 | 无（立即到账） | cliffSeconds 后开始按月释放 | cliffSeconds 后线性释放 |
| 释放方式 | 一次性 | 每月等额 | 按秒连续线性 |
| 领取方式 | 自动到账 | 调用 `release()` | 调用 VestingWallet 的 `release(token)` |
| 余数处理 | 不适用 | 最后一月追加 | 精确线性，无余数 |
| 适用场景 | TGE 解锁、空投 | 团队/顾问/投资者月度释放 | 持续线性释放 |

**释放时间线示例（按月释放，12 月，总量 120 万）**：

```
TGE                    cliff结束
 |------ cliff ---------|-- 月1 --|-- 月2 --|-- ... --|-- 月12 --|
                        ↓         ↓                   ↓
                      10万      10万                 10万
```

---

## 9. 运维注意事项

### 9.1 资金管理

- **先充值后创建**：确保 Manager 合约有足够代币余额后再调用 `createVesting`
- **批量创建前计算总量**：`createVestingBatch` 前确认合约余额 >= 所有归属的代币总和
- **资金来源优先级**：合约余额优先，不足时从 `msg.sender` 的 approve 额度扣除

### 9.2 记录管理

- `removeVesting` 使用 swap-and-pop，移除后最后一条记录的索引会改变
- 链下系统应通过 `vestingWallet` 地址（而非数组索引）来唯一标识归属记录
- `vestingAt(idx).amount` 记录的是创建时的金额，不反映当前剩余余额

### 9.3 MonthlyVesting 特性

- **不可撤销**：一旦部署并注入代币，无法取消、暂停或修改归属计划
- **不可变更受益人**：受益人地址在部署时永久锁定
- **无救援功能**：MonthlyVesting 子合约中误转入的非归属代币无法取回
- **任何人可 release**：`release()` 无权限限制，任何人均可触发释放

### 9.4 代币兼容性

- 仅支持标准 ERC20 代币（1:1 转账，无 fee-on-transfer）
- 如果使用带转账手续费的代币，直接转账模式会 revert（`received >= amount` 检查）
- MonthlyVesting 通过余额检查保护自身，但可能导致部分月份无法释放

### 9.5 救援限制

- Manager 的 `rescueERC20` 禁止救援主代币，防止管理员挪用归属资金
- MonthlyVesting 和 VestingWallet 子合约无救援功能
