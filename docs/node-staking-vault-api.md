# NodeStaking / Vault 接口文档

## 1. 说明

本文档描述了当前实现中的两个核心合约接口：

- NodeStaking：负责 NFT 质押、锁仓、赎回以及白名单控制。
- Vault：负责 PTC 的存款与签名提币。

---

## 2. NodeStaking 合约接口

### 2.1 状态变量

#### 只读变量

- `ptc() -> address`
  - 返回 PTC token 合约地址。

- `nft() -> address`
  - 返回 NFT 合约地址。

- `vault() -> address`
  - 返回当前 Vault 地址。

- `feeRecipient() -> address`
  - 返回手续费接收地址。

- `STAKE_AMOUNT() -> uint256`
  - 质押所需 PTC 数量，当前为 `10_000 * 1e18`。

- `STAKE_DURATION() -> uint256`
  - 锁仓时长，当前为 `365 days`。

- `nftOwner(uint256 tokenId) -> address`
  - 返回某个 NFT 当前的质押归属者。

- `stakeUnlockTime(uint256 tokenId) -> uint256`
  - 返回某个 NFT 的解锁时间。

- `hasBeenStaked(uint256 tokenId) -> bool`
  - 返回某个 NFT 是否已经被标记为已质押。

- `whitelistedTokenIds(uint256 tokenId) -> bool`
  - 返回某个 tokenId 是否在白名单中。

#### 公开视图函数

- `getActiveStakes(address user) -> (uint256[] tokenIds, uint256[] unlockTimes)`
  - 查询用户当前所有活跃质押信息。

- `isStakedMarked(uint256 tokenId) -> bool`
  - 查询某个 NFT 是否已经被标记为已质押。

---

### 2.2 管理员函数

- `setWhitelistedTokenId(uint256 tokenId, bool enabled)`
  - 仅 owner 可调用。
  - 设置某个 tokenId 是否免除 PTC 质押要求。

- `setVault(address _vault)`
  - 仅 owner 可调用。
  - 设置当前使用的 Vault 地址。

---

### 2.3 用户函数

- `stake(uint256 tokenId)`
  - 用户质押单个 NFT。
  - 逻辑：
    - 检查 NFT 是否已被质押；
    - 检查该 tokenId 是否已被标记为已质押；
    - 如果 tokenId 不在白名单中，则将 `STAKE_AMOUNT` 的 PTC 从用户转入 Vault；
    - 将 NFT 转入当前合约；
    - 记录解锁时间，创建质押记录。

- `stakeBatch(uint256[] tokenIds)`
  - 批量质押多个 NFT。
  - 每个 tokenId 会按单个质押逻辑处理。

- `unstake(uint256 tokenId)`
  - 用户在锁仓期结束后赎回 NFT。
  - 只有在当前区块时间大于等于解锁时间时才能成功。

---

### 2.4 事件

- `NodeStaked(address user, uint256 tokenId, uint256 startTime, uint256 endTime)`
  - 质押成功时触发。

- `NodeUnstaked(address user, uint256 tokenId, uint256 timestamp)`
  - 赎回成功时触发。

- `WhitelistSet(uint256 tokenId, bool enabled)`
  - 白名单状态变更时触发。

- `VaultUpdated(address oldVault, address newVault)`
  - Vault 地址变更时触发。

---

## 3. Vault 合约接口

### 3.1 状态变量

#### 只读变量

- `ptc() -> address`
  - 返回 PTC token 合约地址。

- `feeRecipient() -> address`
  - 返回手续费接收地址。

- `signer() -> address`
  - 返回签名授权地址。

- `FEE_BPS() -> uint256`
  - 手续费基准点，当前为 `1500`，即 `15%`。

- `BPS_DENOMINATOR() -> uint256`
  - 基准点分母，当前为 `10000`。

- `usedNonces(address user, uint256 nonce) -> bool`
  - 返回某个用户某个 nonce 是否已经被使用。

---

### 3.2 用户函数

- `deposit(uint256 amount)`
  - 向 Vault 存入 PTC。
  - 用户需要先授权 Vault 合约转移 PTC。

- `withdraw(uint256 amount, uint256 nonce, uint256 deadline, bytes signature)`
  - 使用 EIP-712 签名进行提币。
  - 逻辑：
    - 检查金额非零；
    - 检查签名未过期；
    - 检查 nonce 未被使用；
    - 检查 Vault 中余额足够；
    - 验证签名是否由授权 signer 签发；
    - 计算手续费；
    - 将实际到账金额转给用户，手续费转给 feeRecipient。

---

### 3.3 事件

- `PTCDeposited(address sender, uint256 amount, uint256 timestamp)`
  - 存款成功时触发。

- `PTCWithdrawn(address user, uint256 totalAmount, uint256 userReceived, uint256 feeAmount, uint256 timestamp)`
  - 提币成功时触发。

---

## 4. 典型调用流程

### 4.1 质押 NFT

1. 用户先授权 NodeStaking 合约转移 NFT。
2. 用户调用 `stake(tokenId)`。
3. 若 tokenId 未被白名单放行，则同时转入 `STAKE_AMOUNT` 的 PTC 到 Vault。
4. NFT 被转入 NodeStaking 合约。
5. 记录解锁时间与质押状态。

### 4.2 赎回 NFT

1. 用户等待超过 `STAKE_DURATION`。
2. 调用 `unstake(tokenId)`。
3. 合约将 NFT 转回用户地址。

### 4.3 存入 Vault

1. 用户先授权 Vault 合约转移 PTC。
2. 调用 `deposit(amount)`。
3. Vault 收到 PTC。

### 4.4 从 Vault 提币

1. 后端或签名服务生成 EIP-712 签名。
2. 用户调用 `withdraw(amount, nonce, deadline, signature)`。
3. Vault 校验签名并执行提币。

---

## 5. 备注

- 当前实现中，质押锁仓期固定为 365 天。
- 当前提币手续费固定为 15%。
- 当前白名单粒度为 tokenId 级别，允许针对特定 NFT 做免押处理。
