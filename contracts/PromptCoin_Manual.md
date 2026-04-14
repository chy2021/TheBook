# PromptCoin (PTC) — 合约说明文档

## 1. 合约概述

| 项目 | 内容 |
|------|------|
| 合约名 | `PromptCoin` |
| 代币名称 | PromptCoin |
| 代币符号 | PTC |
| 精度 | 18 位小数（ERC20 默认） |
| 总供应量 | 10,000,000,000 PTC（100 亿） |
| Solidity | ^0.8.20 |
| 依赖 | OpenZeppelin v5 (ERC20, Ownable) |
| 许可证 | MIT |

## 2. 核心特性

- **一次性铸造**：部署时将全部 100 亿 PTC 铸造给部署者（deployer），此后无法增发
- **标准 ERC20**：完全兼容 ERC20 标准，无任何自定义转账逻辑
- **无手续费**：转账 1:1，无 fee-on-transfer、无 burn-on-transfer
- **无黑名单**：任何地址均可自由持有和转账
- **无暂停机制**：合约无法被暂停

## 3. 部署

### 构造函数

```solidity
constructor() ERC20("PromptCoin", "PTC") Ownable(msg.sender)
```

无参数。部署即完成，部署者自动获得全部 100 亿 PTC。

### 部署后验证

```
name()        → "PromptCoin"
symbol()      → "PTC"
decimals()    → 18
totalSupply() → 10000000000000000000000000000 (10^28 = 100亿 * 10^18)
balanceOf(deployer) → 等于 totalSupply()
```

## 4. 接口参考

PTC 仅包含标准 ERC20 接口，无自定义函数：

| 函数 | 说明 |
|------|------|
| `name()` | 返回 "PromptCoin" |
| `symbol()` | 返回 "PTC" |
| `decimals()` | 返回 18 |
| `totalSupply()` | 返回总供应量 100 亿（含 18 位精度） |
| `balanceOf(address)` | 查询余额 |
| `transfer(address to, uint256 amount)` | 转账 |
| `approve(address spender, uint256 amount)` | 授权 |
| `allowance(address owner, address spender)` | 查询授权额度 |
| `transferFrom(address from, address to, uint256 amount)` | 授权转账 |

## 5. 与其他合约的关系

| 合约 | PTC 的角色 |
|------|-----------|
| PromptStaking | 作为质押奖励代币，需预先向 Staking 合约转入足够的 PTC |
| TokenVestingManager | 作为归属释放的代币，需预先向 Manager 合约转入或 approve |

## 6. 安全说明

- 合约继承了 `Ownable`，但没有定义任何 `onlyOwner` 函数，Owner 角色实际上不具备任何特殊权限
- 没有 `mint`、`burn`、`pause`、`blacklist` 等管理函数
- 一旦部署，代币总量永久固定，无人可以修改任何合约参数
