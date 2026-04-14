# TheBook (Prompt NFT) — 合约说明文档

## 1. 合约概述

| 项目 | 内容 |
|------|------|
| 合约名 | `TheBook` |
| 标准 | ERC721A（批量铸造优化版 ERC721） |
| Solidity | ^0.8.4 |
| 最大供应量 | 290,109 个 NFT |
| 权限模型 | 自定义 `minter` 角色 |
| 许可证 | MIT |

## 2. 核心特性

- **ERC721A 批量铸造优化**：支持高效批量铸造，gas 成本远低于逐个铸造
- **固定供应上限**：最大 290,109 个 NFT，铸造时强制检查
- **Minter 角色**：所有管理操作由 `minter` 控制（非 Ownable 模式）
- **批量转账**：内置 `batchTransferFrom` 支持批量 NFT 转账
- **查询扩展**：内置 `tokensOfOwner`、`explicitOwnershipOf` 等查询函数
- **资产救援**：支持提取误转入的 ETH、ERC20、ERC721

## 3. 部署

### 构造函数

```solidity
constructor(string memory name_, string memory symbol_)
```

| 参数 | 说明 |
|------|------|
| `name_` | NFT 集合名称 |
| `symbol_` | NFT 集合符号 |

部署者自动成为 `minter`。

### 部署后验证

```
name()      → 部署时设置的名称
symbol()    → 部署时设置的符号
getMinter() → 部署者地址
totalSupply() → 0（初始无铸造）
```

## 4. 接口参考

### 4.1 铸造（仅 Minter）

| 函数 | 说明 |
|------|------|
| `mint(address to, uint256 quantity)` | 向指定地址铸造 quantity 个 NFT |

- 前置条件：`totalSupply() + quantity <= 290109`
- 权限：仅 `minter` 可调用

### 4.2 转账

| 函数 | 说明 |
|------|------|
| `transferFrom(address from, address to, uint256 tokenId)` | 标准 ERC721 单个转账 |
| `safeTransferFrom(address from, address to, uint256 tokenId)` | 安全转账（检查接收合约） |
| `batchTransferFrom(address from, address to, uint256[] tokenIds)` | 批量转账（tokenIds 需升序） |

### 4.3 URI 管理（仅 Minter）

| 函数 | 说明 |
|------|------|
| `setBaseURI(string memory uri)` | 设置 NFT 元数据的 baseURI |
| `tokenURI(uint256 tokenId)` | 返回 `{baseURI}{tokenId}.json` |

### 4.4 资产救援（仅 Minter）

| 函数 | 说明 |
|------|------|
| `withdraw()` | 提取合约中的全部 ETH |
| `withdrawTokens(IERC20 token)` | 提取合约中的 ERC20 代币 |
| `withdrawNFT(address nft, uint256 tokenId)` | 提取合约中的 ERC721 NFT |

### 4.5 Minter 管理

| 函数 | 说明 |
|------|------|
| `getMinter()` | 查询当前 minter 地址 |
| `transfermintership(address newminter)` | 转移 minter 权限 |
| `renouncemintership()` | 放弃 minter 权限（不可逆） |

### 4.6 查询函数

| 函数 | 说明 |
|------|------|
| `tokensOfOwner(address owner)` | 返回某地址持有的全部 tokenId 数组 |
| `tokensOfOwnerIn(address owner, uint256 start, uint256 stop)` | 分页查询持有的 tokenId |
| `explicitOwnershipOf(uint256 tokenId)` | 查询 tokenId 的详细所有权信息 |
| `explicitOwnershipsOf(uint256[] tokenIds)` | 批量查询所有权信息 |
| `totalSupply()` | 当前已铸造总数 |
| `balanceOf(address owner)` | 某地址持有的 NFT 数量 |
| `ownerOf(uint256 tokenId)` | 某 tokenId 的当前持有者 |

## 5. 事件

| 事件 | 说明 |
|------|------|
| `Transfer(address from, address to, uint256 tokenId)` | NFT 转账（ERC721 标准） |
| `Approval(address owner, address approved, uint256 tokenId)` | NFT 授权（ERC721 标准） |
| `ApprovalForAll(address owner, address operator, bool approved)` | 全量授权（ERC721 标准） |
| `mintershipTransferred(address previousminter, address newminter)` | Minter 角色转移 |

## 6. 与其他合约的关系

| 合约 | TheBook 的角色 |
|------|---------------|
| PromptStaking | 作为质押的 NFT 资产。用户将 TheBook NFT 质押到 Staking 合约以获取 PTC 奖励 |
| PromptStaking 销售比例 | Staking 合约通过 `balanceOf(salesAddress)` 查询 TheBook 合约来计算销售比例 |

## 7. 运维注意事项

- **Minter 安全**：`minter` 拥有铸造、设置 URI、提款等全部管理权限，建议为 EOA 地址或确认合约钱包兼容性
- **`withdraw()` 限制**：使用 `transfer()` 发送 ETH，gas 固定 2300。如果 minter 是合约钱包（如 Gnosis Safe），可能因 gas 不足而失败
- **`withdrawTokens()` 限制**：未使用 SafeERC20，某些非标准 ERC20（如 USDT）可能无法通过此函数提取
- **`batchTransferFrom` tokenIds 顺序**：tokenIds 数组必须严格升序排列
- **`renouncemintership` 不可逆**：放弃后无法铸造新 NFT、无法设置 URI、无法提款
