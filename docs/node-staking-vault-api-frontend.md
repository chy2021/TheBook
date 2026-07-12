# NodeStaking / Vault 前端与后端接入文档

## 1. 目标

本文档面向前端、后端或脚本调用者，说明如何接入以下两个合约：

- NodeStaking：质押 NFT、查询状态、赎回 NFT
- Vault：存入 PTC、使用签名提币

---

## 2. 需要准备的内容

### 2.1 合约地址

部署后需要拿到以下地址：

- NodeStaking 合约地址
- Vault 合约地址
- PTC token 合约地址
- NFT 合约地址

### 2.2 依赖信息

- 需要支持 EVM 的钱包或 RPC
- 需要具备 ERC20 / ERC721 授权能力
- 需要后端或前端生成 Vault 提币签名

---

## 3. NodeStaking 接入说明

### 3.1 质押 NFT

调用方法：

- `stake(uint256 tokenId)`

前置条件：
- 用户已拥有该 NFT
- 用户已授权 NFT 合约对 NodeStaking 合约进行转移
- 如果 tokenId 不在白名单中，用户还需要授权 PTC 转账给 Vault

调用步骤：
1. 调用 NFT 合约的 `setApprovalForAll` 或单独授权。
2. 调用 PTC 的 `approve`，授权 NodeStaking / Vault 进行转账。
3. 调用 NodeStaking 的 `stake(tokenId)`。

### 3.2 批量质押 NFT

调用方法：

- `stakeBatch(uint256[] tokenIds)`

适用场景：
- 一次质押多个 NFT。

### 3.3 查询质押状态

调用方法：

- `getActiveStakes(address user)`
- `isStakedMarked(uint256 tokenId)`
- `nftOwner(uint256 tokenId)`
- `stakeUnlockTime(uint256 tokenId)`

### 3.4 赎回 NFT

调用方法：

- `unstake(uint256 tokenId)`

前置条件：
- 当前时间必须大于等于解锁时间。

---

## 4. Vault 接入说明

### 4.1 存入 PTC

调用方法：

- `deposit(uint256 amount)`

前置条件：
- 用户先调用 PTC 的 `approve`，授权 Vault 合约转账。

### 4.2 提币

调用方法：

- `withdraw(uint256 amount, uint256 nonce, uint256 deadline, bytes signature)`

前置条件：
- 需要由后端或服务端使用私钥生成 EIP-712 签名。
- 签名内容包含：
  - 用户地址
  - 提币金额
  - nonce
  - deadline

签名流程：
1. 生成 `WithdrawRequest` 结构体数据。
2. 使用 EIP-712 格式签名。
3. 前端将签名和参数一起传给 Vault 合约。

注意事项：
- `nonce` 不能重复使用。
- `deadline` 不能过期。
- 提币会收取 15% 手续费。

---

## 5. 推荐调用顺序

### 5.1 质押流程

1. 授权 NFT 转移
2. 授权 PTC 转账
3. 调用 `stake(tokenId)`

### 5.2 提币流程

1. 后端生成签名
2. 前端调用 `withdraw(...)`
3. Vault 校验签名并完成转账

---

## 6. 常见问题

### 6.1 为什么质押失败？

常见原因：
- NFT 未授权
- PTC 未授权
- tokenId 已经被质押
- tokenId 已被标记为已质押

### 6.2 为什么提币失败？

常见原因：
- 签名无效
- nonce 已使用
- 签名已过期
- Vault 余额不足

---

## 7. 备注

- 当前锁仓期为 365 天。
- 当前提币手续费为 15%。
- 当前白名单控制粒度为 tokenId 级别。

## 8. 代码示例（ethers.js）

下面给出一个简化的前端/后端接入示例，适用于 ethers v5。

### 8.1 质押 NFT

```js
const { ethers } = require("ethers");

async function stakeNode() {
  const provider = new ethers.providers.JsonRpcProvider(process.env.RPC_URL);
  const signer = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

  const ptcAddress = process.env.PTC_ADDRESS;
  const nftAddress = process.env.NFT_ADDRESS;
  const nodeStakingAddress = process.env.NODE_STAKING_ADDRESS;

  const ptc = new ethers.Contract(ptcAddress, [
    "function approve(address spender, uint256 amount) external returns (bool)"
  ], signer);

  const nft = new ethers.Contract(nftAddress, [
    "function setApprovalForAll(address operator, bool approved) external"
  ], signer);

  const nodeStaking = new ethers.Contract(nodeStakingAddress, [
    "function stake(uint256 tokenId) external"
  ], signer);

  await nft.setApprovalForAll(nodeStakingAddress, true);
  await ptc.approve(nodeStakingAddress, ethers.constants.MaxUint256);

  const tx = await nodeStaking.stake(101);
  await tx.wait();
  console.log("Stake succeeded");
}
```

### 8.2 生成 Vault 提币签名

```js
async function createWithdrawSignature() {
  const provider = new ethers.providers.JsonRpcProvider(process.env.RPC_URL);
  const signer = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

  const vaultAddress = process.env.VAULT_ADDRESS;
  const chainId = await provider.getNetwork().then((n) => n.chainId);
  const amount = ethers.utils.parseUnits("100", 18);
  const nonce = 1;
  const deadline = Math.floor(Date.now() / 1000) + 3600;

  const domain = {
    name: "PromptVault",
    version: "1",
    chainId,
    verifyingContract: vaultAddress,
  };

  const types = {
    WithdrawRequest: [
      { name: "user", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  };

  const value = {
    user: signer.address,
    amount,
    nonce,
    deadline,
  };

  return signer._signTypedData(domain, types, value);
}
```

### 8.3 调用 Vault 提币

```js
async function withdrawFromVault() {
  const provider = new ethers.providers.JsonRpcProvider(process.env.RPC_URL);
  const signer = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

  const vault = new ethers.Contract(process.env.VAULT_ADDRESS, [
    "function withdraw(uint256 amount, uint256 nonce, uint256 deadline, bytes calldata signature) external"
  ], signer);

  const amount = ethers.utils.parseUnits("100", 18);
  const nonce = 1;
  const deadline = Math.floor(Date.now() / 1000) + 3600;
  const signature = await createWithdrawSignature();

  const tx = await vault.withdraw(amount, nonce, deadline, signature);
  await tx.wait();
  console.log("Withdraw succeeded");
}
```

## 9. 部署前建议检查

- 确认 PTC、NFT、Vault 和 NodeStaking 的地址已经正确配置。
- 确认签名服务私钥安全存储，避免在前端直接暴露。
- 确认 `nonce` 在服务端持久化，避免重复使用。
- 确认手续费接收地址和 Vault 地址都已设置正确。
