// Usage:
// npx hardhat run scripts/check_vestings.js --network <network> <MANAGER_ADDRESS>

const hre = require("hardhat");

async function main() {
  const args = process.argv.slice(2).filter(a => !a.startsWith('--'));
  const managerAddr = args[0];
  if (!managerAddr) {
    console.error("Usage: npx hardhat run scripts/check_vestings.js --network <network> <MANAGER_ADDRESS>");
    process.exit(1);
  }

  const provider = hre.ethers.provider;
  const Manager = await hre.ethers.getContractFactory("TokenVestingManager");
  const manager = Manager.attach(managerAddr);

  const tokenAddr = await manager.token();
  const erc20 = new hre.ethers.Contract(tokenAddr, ["function balanceOf(address) view returns (uint256)"], provider);

  const countBN = await manager.vestingCount();
  const count = countBN.toNumber();
  console.log(`Vesting count: ${count}`);

  for (let i = 0; i < count; i++) {
    const r = await manager.vestingAt(i);
    // ethers preserves named fields when returned from solidity struct in many cases
    const beneficiary = r.beneficiary;
    const vestingWallet = r.vestingWallet;
    const amount = r.amount.toString();
    const start = r.start.toString();
    const duration = r.duration.toString();
    const monthly = r.monthly;
    const months = r.months;
    const monthSeconds = r.monthSeconds;

    console.log(`\n[${i}] beneficiary=${beneficiary}`);
    console.log(`    vestingWallet=${vestingWallet}`);
    // `amount` now reflects the actual balance the vesting contract (or
    // direct transfer) held at creation time; use current tokenBalance to
    // assess if top-up is necessary.
    console.log(`    recordedAmount=${amount}  // actual received at creation`);
    console.log(`    start=${start} duration=${duration} monthly=${monthly} months=${months} monthSeconds=${monthSeconds}`);

    if (vestingWallet === hre.ethers.constants.AddressZero) {
      console.log("    type=direct transfer (no vesting contract)");
      continue;
    }

    const bal = await erc20.balanceOf(vestingWallet);
    console.log(`    tokenBalance=${bal.toString()}`);

    if (monthly) {
      const mv = new hre.ethers.Contract(vestingWallet, [
        "function payableMonths() view returns (uint32)",
        "function monthsRemaining() view returns (uint32)",
        "function remaining() view returns (uint256)"
      ], provider);
      try {
        const pm = await mv.payableMonths();
        const mr = await mv.monthsRemaining();
        const rem = await mv.remaining();
        console.log(`    monthly: payableMonths=${pm.toString()}, monthsRemaining=${mr.toString()}, remainingBalance=${rem.toString()}`);
      } catch (e) {
        console.log(`    monthly: failed to query MonthlyVesting: ${e.message}`);
      }
    } else {
      // linear VestingWallet or other: show balance only
      console.log("    linear/non-monthly vesting - balance shown above");
    }
  }
}

main().catch(err => { console.error(err); process.exitCode = 1; });
