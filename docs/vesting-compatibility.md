# Vesting Token Compatibility（兼容性说明）

> 重要提示：本项目中用于锁仓与分发的合约（`TokenVestingManager`, `MonthlyVesting` 等）**假定代币为非手续费/非燃烧的 ERC20**（即转账发生时不会被扣除额外费用或在转账过程中燃烧）。

## 推荐策略

- **生产环境请优先使用 non-deflationary ERC20。** 这能避免会计不一致、创建失败或永久卡死（DoS）场景。

## 已采取的保护与当前行为

- `TokenVestingManager`：
  - 直接转账路径会在转账后检查受益人的余额变化；若受益人收到的净额小于请求金额，会 `revert`（错误信息：`recipient received insufficient amount`），从而避免错误上链记账。
  - 在为子合约（`MonthlyVesting` / `VestingWallet`）充值后，管理合约会读取子合约的**实际余额**并将该实际余额记录在 `VestingRecord.amount` 中（并在 `VestingCreated` 事件中报告实际到账金额）。这种做法可以保证在代币为费率型/燃烧型时，链上记录反映**实际可用的资金**，便于运维决策。注意：子合约的内部 `totalAmount`（例如 `MonthlyVesting` 的构造参数）仍旧由创建时的预期参数决定，因此建议通过 `remaining()` / `payableMonths()` 与 `VestingRecord.amount` 一并监控以了解真实支付能力。

- `MonthlyVesting`：
  - 在 `releasableAmount()` 与 `release()` 中只计算并释放那些**可以被完整支付**的月份，当合约余额不足以支付任何完整月份时，`release()` 会 `revert`（错误信息：`insufficient funds for any month`）。
  - 提供 `payableMonths()` 视图以便外部监控当前能被完整支付的月数。

## 选择与权衡

- 若你必须支持带手续费的代币，可考虑：
  - 在创建时做明确的兼容性声明，并在前端/文档中告知用户；
  - 将直接转账路径改为不 `revert`，而是记录**实际到账**（当前实现会 `revert` 以避免错误上链）；
  - 或在合约外部采用一个中间“桥接”合约来吸收手续费并确保子合约或受益人能收到预期金额。

## 运维建议

- 监控 `payableMonths()` 与合约余额，管理员应在余额不足时补资或对受益人做出通知。若某个 vesting 合约余额为 0，可使用管理合约中的清理接口（`removeVesting`）。

### 快速检查脚本（运维示例）

仓库包含一个示例脚本 `scripts/check_vestings.js`：

用法（Hardhat）：

```bash
npx hardhat run scripts/check_vestings.js --network <network> <MANAGER_ADDRESS>
```

脚本输出每个 vesting 的基本信息（受益人/子合约地址/期望金额/余额），并对 `MonthlyVesting` 合约打印 `payableMonths()` / `monthsRemaining()` / 当前余额，便于运维和补资决策。
注意：`VestingRecord.amount` 现在反映**创建时子合约的实际收到余额**（而非创建请求的原始期望值），因此脚本将报告更准确的“已到账”金额以便运维参考。

---

如需我把这些说明同步到项目的其他文档或在 README 中做更突出展示，我可以继续执行。