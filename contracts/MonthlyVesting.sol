    // SPDX-License-Identifier: MIT
    pragma solidity ^0.8.20;

    import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
    import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
    import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

    /**
     * @title MonthlyVesting
     * @notice Simple monthly vesting: splits a total allocation into N equal monthly
     *         portions and allows anyone to trigger distribution to the beneficiary.
     *
     * Design notes:
     *  - `start` is the timestamp when the first month's portion becomes claimable.
     *  - Each call to `release()` transfers the accumulated, currently claimable
     *    portions (may be multiple months if no one called earlier).
     */
    contract MonthlyVesting is ReentrancyGuard {
        using SafeERC20 for IERC20;

        IERC20 public immutable token;
        address public immutable beneficiary;
        uint64 public immutable start;        // timestamp when first portion unlocks
        uint64 public immutable monthSeconds; // seconds per month (e.g. 30 days)
        uint32 public immutable months;       // total number of months
        uint256 public immutable totalAmount; // total allocation
        uint256 public immutable monthlyAmount; // floor(totalAmount / months)
        uint256 public immutable remainder;     // totalAmount - monthlyAmount * months

        // How many monthly portions have been released already.
        uint32 public releasedMonths;

        /// Emitted when tokens are released to the beneficiary.
        event Released(address indexed to, uint256 amount, uint32 monthsReleased);

        /**
         * @param _token ERC20 token used for vesting
         * @param _beneficiary recipient of vested funds
         * @param _start timestamp when first portion becomes claimable
         * @param _monthSeconds length of a month in seconds (e.g. 30 days)
         * @param _months total number of monthly portions
         * @param _totalAmount total tokens allocated to this vesting
         */
        constructor(
            IERC20 _token,
            address _beneficiary,
            uint64 _start,
            uint64 _monthSeconds,
            uint32 _months,
            uint256 _totalAmount
        ) {
            require(address(_token) != address(0), "token address is zero");
            require(_start > 0, "start must be > 0");
            require(_beneficiary != address(0), "beneficiary is zero");
            require(_monthSeconds > 0, "monthSeconds is zero");
            require(_months > 0, "months is zero");
            require(_totalAmount > 0, "amount is zero");

            token = _token;
            beneficiary = _beneficiary;
            start = _start;
            monthSeconds = _monthSeconds;
            months = _months;
            totalAmount = _totalAmount;

            monthlyAmount = _totalAmount / _months;
            remainder = _totalAmount - (monthlyAmount * _months);
            releasedMonths = 0;
        }

        /// @dev Number of months currently available for release (may be >1).
        function _availableMonths() internal view returns (uint32) {
            if (block.timestamp < start) return 0;
            // First month is available exactly at `start`.
            uint256 elapsed = (block.timestamp - start) / monthSeconds + 1;
            if (elapsed > months) elapsed = months;
            if (elapsed <= releasedMonths) return 0;
            return uint32(elapsed - releasedMonths);
        }

        /// @notice Amount currently claimable (aggregated across available months).
        function releasableAmount() public view returns (uint256) {
            uint32 avail = _availableMonths();
            if (avail == 0) return 0;
            uint256 amount = uint256(avail) * monthlyAmount;
            uint32 willBeReleased = releasedMonths + avail;
            // If this release includes the final month, include the remainder.
            if (willBeReleased == months && remainder > 0) {
                amount += remainder;
            }
            return amount;
        }

        /// @notice Public helper returning the number of months currently available.
        function availableMonths() external view returns (uint32) {
            return _availableMonths();
        }

        /// @notice How many monthly portions remain locked.
        function monthsRemaining() external view returns (uint32) {
            if (releasedMonths >= months) return 0;
            return months - releasedMonths;
        }

        /// @notice Timestamp when the next (not-yet-released) portion becomes available, or 0.
        function nextReleasableTimestamp() external view returns (uint64) {
            if (releasedMonths >= months) return 0;
            uint256 next = uint256(start) + uint256(releasedMonths) * uint256(monthSeconds);
            return uint64(next);
        }

        /**
         * @notice Release all currently available portions to the beneficiary.
         * @return amount Amount actually transferred to the beneficiary.
         */
        function release() external nonReentrant returns (uint256) {
            uint32 avail = _availableMonths();
            require(avail > 0, "nothing releasable");
            uint256 amount = uint256(avail) * monthlyAmount;
            uint32 willBeReleased = releasedMonths + avail;
            if (willBeReleased == months && remainder > 0) {
                amount += remainder;
            }

            // Effects: update bookkeeping before external transfer.
            releasedMonths = willBeReleased;

            // Interactions: transfer tokens to beneficiary.
            token.safeTransfer(beneficiary, amount);

            emit Released(beneficiary, amount, releasedMonths);
            return amount;
        }

        /// @notice Balance remaining in this vesting contract.
        function remaining() external view returns (uint256) {
            return token.balanceOf(address(this));
        }
    }
                
