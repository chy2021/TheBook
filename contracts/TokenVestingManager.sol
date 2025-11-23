// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/finance/VestingWallet.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./MonthlyVesting.sol";

/**
 * @title TokenVestingManager
 * @notice Factory and administration contract to create token vestings for beneficiaries.
 *         Owner is expected to fund the manager (or approve transfers) prior to creating
 *         vestings. This manager supports direct one-time transfers and monthly equal
 *         vestings (MonthlyVesting). Linear OZ VestingWallet usage is retained for
 *         backward compatibility but can be deprecated if desired.
 */
contract TokenVestingManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    uint256 public immutable tgeTimestamp;

    struct VestingRecord {
        address beneficiary;
        address vestingWallet; // address(0) => direct transfer (no vesting contract)
        uint256 amount;
        uint64 start;
        uint64 duration; // linear VestingWallet duration in seconds, 0 for direct/monthly
        bool monthly;    // true if this record points to a MonthlyVesting
        uint32 months;   // valid when monthly == true
        uint64 monthSeconds; // valid when monthly == true
    }

    VestingRecord[] public vestings;

    event VestingCreated(
        address indexed beneficiary,
        address indexed vestingWallet,
        uint256 amount,
        uint256 start,
        uint256 duration,
        bool monthly,
        uint32 months,
        uint64 monthSeconds
    );
    event ERC20Rescued(address indexed operator, address token, address to, uint256 amount);
    event DirectTransfer(address indexed beneficiary, uint256 amount);

    /**
     * @param _token ERC20 token used for vesting
     * @param _tgeTimestamp timestamp of TGE (seconds). If zero, uses deployment time.
     */
    constructor(IERC20 _token, uint256 _tgeTimestamp) Ownable(msg.sender) {
        require(address(_token) != address(0), "token address is zero");
        token = _token;
        // If caller passes 0, default to deployment time. This avoids start==0 pitfalls.
        tgeTimestamp = _tgeTimestamp == 0 ? block.timestamp : _tgeTimestamp;
    }

    /**
     * @dev Internal core creation logic. This function intentionally does not use
     *      the reentrancy guard so it can be called safely from batch routines.
     * @param beneficiary recipient address
     * @param amount tokens to allocate
     * @param cliffSeconds delay from TGE to vesting start
     * @param durationSeconds duration for linear VestingWallet (0 => direct or monthly)
     * @param monthly whether to deploy a MonthlyVesting contract
     * @param months number of months (for monthly mode)
     * @param monthSeconds seconds per month (for monthly mode)
     */
    function _createVesting(
        address beneficiary,
        uint256 amount,
        uint64 cliffSeconds,
        uint64 durationSeconds,
        bool monthly,
        uint32 months,
        uint64 monthSeconds
    ) internal {
        require(beneficiary != address(0), "beneficiary is zero");
        require(amount > 0, "amount is zero");

        uint256 start256 = tgeTimestamp + cliffSeconds;
        uint64 start = uint64(start256);

        if (monthly) {
            require(months > 0, "months is zero");
            require(monthSeconds > 0, "monthSeconds is zero");
            // Deploy MonthlyVesting and record the vesting first (checks -> effects)
            MonthlyVesting mv = new MonthlyVesting(token, beneficiary, start, monthSeconds, months, amount);
            vestings.push(VestingRecord({ beneficiary: beneficiary, vestingWallet: address(mv), amount: amount, start: start, duration: 0, monthly: true, months: months, monthSeconds: monthSeconds }));
            emit VestingCreated(beneficiary, address(mv), amount, start, 0, true, months, monthSeconds);

            // Transfer funds to the new vesting contract (interactions)
            if (token.balanceOf(address(this)) >= amount) {
                token.safeTransfer(address(mv), amount);
            } else {
                token.safeTransferFrom(msg.sender, address(mv), amount);
            }

            // Strict check to detect fee-on-transfer tokens.
            require(token.balanceOf(address(mv)) == amount, "vesting received incorrect amount");
            return;
        }

        if (durationSeconds == 0) {
            // Direct one-time transfer: record first, then transfer.
            vestings.push(VestingRecord({ beneficiary: beneficiary, vestingWallet: address(0), amount: amount, start: start, duration: 0, monthly: false, months: 0, monthSeconds: 0 }));
            emit DirectTransfer(beneficiary, amount);
            if (token.balanceOf(address(this)) >= amount) {
                token.safeTransfer(beneficiary, amount);
            } else {
                token.safeTransferFrom(msg.sender, beneficiary, amount);
            }
            return;
        }

        // Linear vesting path (uses OZ VestingWallet). Retained for backward compatibility.
        VestingWallet vw = new VestingWallet(beneficiary, start, uint64(durationSeconds));

        vestings.push(VestingRecord({ beneficiary: beneficiary, vestingWallet: address(vw), amount: amount, start: start, duration: uint64(durationSeconds), monthly: false, months: 0, monthSeconds: 0 }));
        emit VestingCreated(beneficiary, address(vw), amount, start256, durationSeconds, false, 0, 0);

        if (token.balanceOf(address(this)) >= amount) {
            token.safeTransfer(address(vw), amount);
        } else {
            token.safeTransferFrom(msg.sender, address(vw), amount);
        }

        require(token.balanceOf(address(vw)) == amount, "vesting received incorrect amount");
    }

    /// @notice Create a single vesting entry (only callable by owner).
    function createVesting(
        address beneficiary,
        uint256 amount,
        uint64 cliffSeconds,
        uint64 durationSeconds,
        bool monthly,
        uint32 months,
        uint64 monthSeconds
    ) public onlyOwner nonReentrant {
        _createVesting(beneficiary, amount, cliffSeconds, durationSeconds, monthly, months, monthSeconds);
    }

    struct VestingInput {
        address beneficiary;
        uint256 amount;
        uint64 cliffSeconds;
        uint64 durationSeconds;
        bool monthly;
        uint32 months;
        uint64 monthSeconds;
    }

    function createVestingBatch(VestingInput[] calldata inputs) external onlyOwner nonReentrant {
        uint256 n = inputs.length;
        require(n > 0, "empty input");
        for (uint256 i = 0; i < n; i++) {
            VestingInput calldata it = inputs[i];
            _createVesting(it.beneficiary, it.amount, it.cliffSeconds, it.durationSeconds, it.monthly, it.months, it.monthSeconds);
        }
    }

    /// @notice Number of vestings recorded.
    function vestingCount() external view returns (uint256) {
        return vestings.length;
    }

    /// @notice Return vesting record at index.
    function vestingAt(uint256 idx) external view returns (VestingRecord memory) {
        require(idx < vestings.length, "index out of range");
        return vestings[idx];
    }

    /**
     * @notice Rescue ERC20 tokens accidentally sent to this contract (cannot rescue the primary token).
     */
    function rescueERC20(address tokenAddr, address to, uint256 amount) external onlyOwner nonReentrant {
        require(tokenAddr != address(token), "cannot rescue main token");
        require(to != address(0), "recipient is zero");
        IERC20(tokenAddr).safeTransfer(to, amount);
        emit ERC20Rescued(msg.sender, tokenAddr, to, amount);
    }
}