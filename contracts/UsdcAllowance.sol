// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title UsdcAllowance
 * @notice Native-USDC allowance vault on Arc where gas token is 18-decimal USDC (handled via `msg.value`).
 * @dev Rules summary:
 * - Multiple allowances per owner, IDs are 1-based and monotonically increasing.
 * - Funds are native value only (`msg.value` / `call{value: ...}`), never ERC-20 USDC transfers.
 * - Every state-changing function is `nonReentrant` and follows checks-effects-interactions.
 * - Fixed-window spending periods are enforced from `periodAnchor` and `periodLength`.
 * - Pending limit loosening can be delayed; matured pending limits become effective automatically.
 * - Optional payee allowlist supports delayed activation and bounded cardinality.
 * - Payment refs can be marked one-time-use per allowance to prevent duplicates.
 * - Revoked allowances are permanently inactive and can no longer be funded or spent.
 * @custom:security-contact security@example.com
 */
contract UsdcAllowance is ReentrancyGuard {
    struct Rules {
        uint128 perPaymentCap;
        uint128 periodCap;
        uint64 periodLength;
        uint64 periodAnchor;
        uint64 expiresAt;
        uint32 loosenDelay;
        bool useAllowlist;
    }

    struct Allowance {
        address owner;
        address spender;
        uint128 perPaymentCap;
        uint128 periodCap;
        uint128 balance;
        uint128 spentInPeriod;
        uint128 totalFunded;
        uint128 totalPaid;
        uint128 totalRefunded;
        uint64 periodLength;
        uint64 periodAnchor;
        uint64 periodIndex;
        uint64 expiresAt;
        uint64 createdAt;
        uint32 loosenDelay;
        uint32 paymentCount;
        bool useAllowlist;
        bool paused;
        bool revoked;
    }

    struct PendingLimits {
        uint128 perPaymentCap;
        uint128 periodCap;
        uint64 expiresAt;
        uint64 activeAt;
    }

    struct Budget {
        uint8 status;
        uint128 balance;
        uint128 perPaymentCap;
        uint128 periodCap;
        uint64 expiresAt;
        uint64 periodIndex;
        uint64 periodStart;
        uint64 periodEnd;
        uint128 spentInPeriod;
        uint128 remainingInPeriod;
        uint128 maxPayment;
    }

    uint256 public constant MAX_PAYEES = 20;
    uint64 public constant MIN_PERIOD = 60;
    uint64 public constant MAX_PERIOD = 365 days;
    uint64 public constant MAX_DURATION = 3650 days;
    uint32 public constant MAX_LOOSEN_DELAY = 30 days;
    uint256 public constant MAX_LABEL = 32;
    uint256 public constant MAX_MEMO = 140;

    error ZeroAddress();
    error InvalidRules();
    error TooManyPayees();
    error InvalidPayee(address payee);
    error LabelTooLong();
    error AmountTooLarge();
    error UnknownAllowance(uint256 id);
    error NotOwner();
    error NotSpender();
    error AllowanceRevoked();
    error AllowanceExpired(uint64 expiresAt);
    error AllowancePaused();
    error PayeeNotAllowed(address payee);
    error ZeroAmount();
    error ExceedsPaymentCap(uint256 amount, uint256 cap);
    error ExceedsPeriodCap(uint256 amount, uint256 remaining);
    error InsufficientBalance(uint256 amount, uint256 balance);
    error DuplicateRef(bytes32 ref);
    error TransferFailed();
    error MemoTooLong();
    error AllowlistDisabled();

    event AllowanceCreated(
        uint256 indexed id,
        address indexed owner,
        address indexed spender,
        uint64 periodLength,
        uint64 periodAnchor,
        uint32 loosenDelay,
        bool useAllowlist,
        string label
    );
    event Funded(uint256 indexed id, address indexed from, uint256 amount, uint256 balance);
    event Paid(
        uint256 indexed id,
        address indexed payee,
        bytes32 indexed ref,
        address spender,
        uint256 amount,
        uint64 periodIndex,
        uint256 spentInPeriod,
        string memo
    );
    event LimitsChanged(uint256 indexed id, uint128 perPaymentCap, uint128 periodCap, uint64 expiresAt);
    event LimitsPending(uint256 indexed id, uint128 perPaymentCap, uint128 periodCap, uint64 expiresAt, uint64 activeAt);
    event PendingCleared(uint256 indexed id);
    event PayeeAdded(uint256 indexed id, address indexed payee, uint64 activeAt);
    event PayeeRemoved(uint256 indexed id, address indexed payee);
    event PausedSet(uint256 indexed id, bool paused);
    event Withdrawn(uint256 indexed id, address indexed to, uint256 amount, uint256 balance);
    event Revoked(uint256 indexed id, address indexed owner, uint256 refunded);

    mapping(uint256 => Allowance) private _allowances;
    mapping(uint256 => string) private _labels;
    mapping(uint256 => PendingLimits) private _pending;
    mapping(uint256 => address[]) private _payees;
    mapping(uint256 => mapping(address => uint64)) private _payeeActiveAt;
    mapping(uint256 => mapping(address => uint256)) private _payeeIndex;
    mapping(uint256 => mapping(bytes32 => bool)) private _usedRefs;
    mapping(address => uint256[]) private _idsByOwner;
    mapping(address => uint256[]) private _idsBySpender;
    uint256 private _allowanceCount;
    uint128 private _totalHeld;

    /**
     * @notice Creates a new allowance and optionally funds it with native USDC.
     * @param spender Authorized spender for payments.
     * @param rules Initial rule configuration.
     * @param payees Initial allowlisted payees.
     * @param label Free-form label up to 32 bytes.
     * @return id Newly created allowance ID.
     */
    function createAllowance(
        address spender,
        Rules calldata rules,
        address[] calldata payees,
        string calldata label
    ) external payable nonReentrant returns (uint256 id) {
        if (spender == address(0)) revert ZeroAddress();

        if (
            spender == address(this) || rules.perPaymentCap == 0 || rules.perPaymentCap > rules.periodCap
                || rules.expiresAt <= block.timestamp || rules.expiresAt > block.timestamp + MAX_DURATION
                || rules.periodLength < MIN_PERIOD || rules.periodLength > MAX_PERIOD || rules.periodAnchor > block.timestamp
                || rules.loosenDelay > MAX_LOOSEN_DELAY || (payees.length > 0 && !rules.useAllowlist)
        ) revert InvalidRules();

        if (payees.length > MAX_PAYEES) revert TooManyPayees();

        uint256 payeeLen = payees.length;
        for (uint256 i = 0; i < payeeLen; ++i) {
            address payee = payees[i];
            if (payee == address(0) || payee == address(this) || payee == spender) revert InvalidPayee(payee);
            for (uint256 j = 0; j < i; ++j) {
                if (payees[j] == payee) revert InvalidPayee(payee);
            }
        }

        if (bytes(label).length > MAX_LABEL) revert LabelTooLong();
        if (msg.value > type(uint128).max) revert AmountTooLarge();

        unchecked {
            _allowanceCount += 1;
        }
        id = _allowanceCount;

        // slither-disable-next-line divide-before-multiply
        // Intentional: floor(block.timestamp, 1 day) to snap anchor to current UTC-day boundary.
        // The divide-then-multiply is the correct algorithm here — precision loss IS the intent.
        uint64 anchor = rules.periodAnchor == 0 ? uint64((block.timestamp / 1 days) * 1 days) : rules.periodAnchor;
        uint64 currentPeriod = uint64((block.timestamp - anchor) / rules.periodLength);

        Allowance storage a = _allowances[id];
        a.owner = msg.sender;
        a.spender = spender;
        a.perPaymentCap = rules.perPaymentCap;
        a.periodCap = rules.periodCap;
        a.periodLength = rules.periodLength;
        a.periodAnchor = anchor;
        a.periodIndex = currentPeriod;
        a.expiresAt = rules.expiresAt;
        a.createdAt = uint64(block.timestamp);
        a.loosenDelay = rules.loosenDelay;
        a.useAllowlist = rules.useAllowlist;

        _labels[id] = label;
        _idsByOwner[msg.sender].push(id);
        _idsBySpender[spender].push(id);

        emit AllowanceCreated(id, msg.sender, spender, rules.periodLength, anchor, rules.loosenDelay, rules.useAllowlist, label);
        emit LimitsChanged(id, rules.perPaymentCap, rules.periodCap, rules.expiresAt);

        for (uint256 i = 0; i < payeeLen; ++i) {
            address payee = payees[i];
            _payees[id].push(payee);
            _payeeIndex[id][payee] = _payees[id].length;
            _payeeActiveAt[id][payee] = uint64(block.timestamp);
            emit PayeeAdded(id, payee, uint64(block.timestamp));
        }

        if (msg.value > 0) {
            uint128 funded = uint128(msg.value);
            a.balance = funded;
            a.totalFunded = funded;
            _totalHeld += funded;
            emit Funded(id, msg.sender, funded, funded);
        }
    }

    /**
     * @notice Adds native USDC funds to an existing allowance.
     * @param id Allowance ID.
     */
    function fund(uint256 id) external payable nonReentrant {
        if (!_exists(id)) revert UnknownAllowance(id);

        Allowance storage a = _allowances[id];
        if (a.owner != msg.sender) revert NotOwner();
        if (a.revoked) revert AllowanceRevoked();
        if (msg.value == 0) revert ZeroAmount();

        if (msg.value > type(uint128).max) revert AmountTooLarge();
        uint128 amount = uint128(msg.value);
        if (a.balance > type(uint128).max - amount) revert AmountTooLarge();

        a.balance += amount;
        a.totalFunded += amount;
        _totalHeld += amount;

        emit Funded(id, msg.sender, amount, a.balance);
    }

    /**
     * @notice Pays a payee from the allowance if all rules pass.
     * @param id Allowance ID.
     * @param payee Payment recipient.
     * @param amount Native USDC amount (18 decimals).
     * @param ref Optional unique reference (bytes32(0) disables duplicate protection for this payment).
     * @param memo Optional memo up to 140 bytes.
     */
    function pay(uint256 id, address payee, uint256 amount, bytes32 ref, string calldata memo) external nonReentrant {
        if (!_exists(id)) revert UnknownAllowance(id);

        Allowance storage a = _allowances[id];
        if (a.spender != msg.sender) revert NotSpender();
        if (bytes(memo).length > MAX_MEMO) revert MemoTooLong();

        (uint128 effPerPaymentCap, uint128 effPeriodCap, uint64 effExpiresAt) = _effectiveLimits(id);
        _checkRules(a, id, payee, amount, ref, effPerPaymentCap, effPeriodCap, effExpiresAt);

        if (ref != bytes32(0)) {
            _usedRefs[id][ref] = true;
        }

        uint64 currentPeriod = uint64((block.timestamp - a.periodAnchor) / a.periodLength);
        if (currentPeriod > a.periodIndex) {
            a.periodIndex = currentPeriod;
            a.spentInPeriod = 0;
        }

        uint128 amount128 = uint128(amount);
        a.spentInPeriod += amount128;
        a.balance -= amount128;
        a.totalPaid += amount128;
        a.paymentCount += 1;
        _totalHeld -= amount128;

        emit Paid(id, payee, ref, msg.sender, amount, currentPeriod, a.spentInPeriod, memo);

        (bool ok,) = payee.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /**
     * @notice Updates limits for an allowance, applying tighter changes immediately and optionally delaying looser changes.
     * @param id Allowance ID.
     * @param perPaymentCap New per-payment cap.
     * @param periodCap New per-period cap.
     * @param expiresAt New expiry timestamp.
     */
    function setLimits(uint256 id, uint128 perPaymentCap, uint128 periodCap, uint64 expiresAt) external nonReentrant {
        if (!_exists(id)) revert UnknownAllowance(id);
        Allowance storage a = _allowances[id];
        if (a.owner != msg.sender) revert NotOwner();
        if (a.revoked) revert AllowanceRevoked();
        if (
            perPaymentCap == 0 || perPaymentCap > periodCap || expiresAt <= block.timestamp
                || expiresAt > block.timestamp + MAX_DURATION
        ) revert InvalidRules();
        _applySetLimits(id, perPaymentCap, periodCap, expiresAt);
    }

    /**
     * @dev Extracted logic for setLimits to avoid stack-too-deep.
     */
    function _applySetLimits(uint256 id, uint128 perPaymentCap, uint128 periodCap, uint64 expiresAt) internal {
        Allowance storage a = _allowances[id];

        // Fold matured pending into storage
        {
            PendingLimits storage p = _pending[id];
            if (p.activeAt != 0 && block.timestamp >= p.activeAt) {
                a.perPaymentCap = p.perPaymentCap;
                a.periodCap = p.periodCap;
                a.expiresAt = p.expiresAt;
                delete _pending[id];
            }
        }

        (uint128 curPer, uint128 curPc, uint64 curExp) = _effectiveLimits(id);
        bool anyLooser = (perPaymentCap > curPer) || (periodCap > curPc) || (expiresAt > curExp);
        bool hadPending = _pending[id].activeAt != 0;

        if (!anyLooser || a.loosenDelay == 0) {
            a.perPaymentCap = perPaymentCap;
            a.periodCap     = periodCap;
            a.expiresAt     = expiresAt;
            if (hadPending) {
                delete _pending[id];
                emit PendingCleared(id);
            }
            emit LimitsChanged(id, perPaymentCap, periodCap, expiresAt);
            return;
        }

        // Apply tighter fields immediately
        a.perPaymentCap = perPaymentCap < curPer ? perPaymentCap : curPer;
        a.periodCap     = periodCap     < curPc  ? periodCap     : curPc;
        a.expiresAt     = expiresAt     < curExp ? expiresAt     : curExp;

        emit LimitsChanged(id, a.perPaymentCap, a.periodCap, a.expiresAt);

        uint64 activeAt = uint64(block.timestamp + a.loosenDelay);
        _pending[id] = PendingLimits({
            perPaymentCap: perPaymentCap,
            periodCap:     periodCap,
            expiresAt:     expiresAt,
            activeAt:      activeAt
        });
        emit LimitsPending(id, perPaymentCap, periodCap, expiresAt, activeAt);
    }

    /**
     * @notice Adds payees to the allowance allowlist.
     * @param id Allowance ID.
     * @param payees Payees to add.
     */
    function addPayees(uint256 id, address[] calldata payees) external nonReentrant {
        if (!_exists(id)) revert UnknownAllowance(id);

        Allowance storage a = _allowances[id];
        if (a.owner != msg.sender) revert NotOwner();
        if (a.revoked) revert AllowanceRevoked();
        if (!a.useAllowlist) revert AllowlistDisabled();

        if (payees.length > MAX_PAYEES) revert TooManyPayees();

        uint64 activeAt = uint64(block.timestamp + a.loosenDelay);
        uint256 len = payees.length;

        for (uint256 i = 0; i < len; ++i) {
            address payee = payees[i];
            if (payee == address(0) || payee == address(this) || payee == a.spender) revert InvalidPayee(payee);

            if (_payeeIndex[id][payee] != 0) {
                continue;
            }

            if (_payees[id].length >= MAX_PAYEES) revert TooManyPayees();

            _payees[id].push(payee);
            _payeeIndex[id][payee] = _payees[id].length;
            _payeeActiveAt[id][payee] = activeAt;
            emit PayeeAdded(id, payee, activeAt);
        }
    }

    /**
     * @notice Removes payees from the allowance allowlist.
     * @param id Allowance ID.
     * @param payees Payees to remove.
     */
    function removePayees(uint256 id, address[] calldata payees) external nonReentrant {
        if (!_exists(id)) revert UnknownAllowance(id);

        Allowance storage a = _allowances[id];
        if (a.owner != msg.sender) revert NotOwner();
        if (a.revoked) revert AllowanceRevoked();

        uint256 len = payees.length;
        for (uint256 i = 0; i < len; ++i) {
            address payee = payees[i];
            uint256 index = _payeeIndex[id][payee];
            if (index == 0) {
                continue;
            }

            address[] storage arr = _payees[id];
            uint256 removePos = index - 1;
            uint256 lastPos = arr.length - 1;

            if (removePos != lastPos) {
                address lastPayee = arr[lastPos];
                arr[removePos] = lastPayee;
                _payeeIndex[id][lastPayee] = index;
            }

            arr.pop();
            delete _payeeIndex[id][payee];
            delete _payeeActiveAt[id][payee];

            emit PayeeRemoved(id, payee);
        }
    }

    /**
     * @notice Pauses spending for an allowance.
     * @param id Allowance ID.
     */
    function pause(uint256 id) external nonReentrant {
        if (!_exists(id)) revert UnknownAllowance(id);

        Allowance storage a = _allowances[id];
        if (a.owner != msg.sender) revert NotOwner();
        if (a.revoked) revert AllowanceRevoked();

        if (!a.paused) {
            a.paused = true;
            emit PausedSet(id, true);
        }
    }

    /**
     * @notice Unpauses spending for an allowance.
     * @param id Allowance ID.
     */
    function unpause(uint256 id) external nonReentrant {
        if (!_exists(id)) revert UnknownAllowance(id);

        Allowance storage a = _allowances[id];
        if (a.owner != msg.sender) revert NotOwner();
        if (a.revoked) revert AllowanceRevoked();

        if (a.paused) {
            a.paused = false;
            emit PausedSet(id, false);
        }
    }

    /**
     * @notice Withdraws native USDC from an allowance back to its owner.
     * @param id Allowance ID.
     * @param amount Amount to withdraw.
     */
    function withdraw(uint256 id, uint256 amount) external nonReentrant {
        if (!_exists(id)) revert UnknownAllowance(id);

        Allowance storage a = _allowances[id];
        if (a.owner != msg.sender) revert NotOwner();
        if (a.revoked) revert AllowanceRevoked();

        if (amount == 0) revert ZeroAmount();
        if (amount > a.balance) revert InsufficientBalance(amount, a.balance);

        uint128 amount128 = uint128(amount);
        a.balance -= amount128;
        a.totalRefunded += amount128;
        _totalHeld -= amount128;

        emit Withdrawn(id, a.owner, amount, a.balance);

        (bool ok,) = a.owner.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /**
     * @notice Revokes an allowance permanently and refunds remaining balance to owner.
     * @param id Allowance ID.
     */
    function revoke(uint256 id) external nonReentrant {
        if (!_exists(id)) revert UnknownAllowance(id);

        Allowance storage a = _allowances[id];
        if (a.owner != msg.sender) revert NotOwner();
        if (a.revoked) revert AllowanceRevoked();

        uint128 refund = a.balance;

        a.revoked = true;
        a.balance = 0;
        a.totalRefunded += refund;
        _totalHeld -= refund;
        delete _pending[id];

        emit Revoked(id, a.owner, refund);

        if (refund > 0) {
            (bool ok,) = a.owner.call{value: refund}("");
            if (!ok) revert TransferFailed();
        }
    }

    /**
     * @notice Returns stored allowance data by ID.
     * @param id Allowance ID.
     * @return Stored allowance struct, or zeroed struct for unknown ID.
     */
    function getAllowance(uint256 id) external view returns (Allowance memory) {
        if (!_exists(id)) {
            return Allowance({
                owner: address(0),
                spender: address(0),
                perPaymentCap: 0,
                periodCap: 0,
                balance: 0,
                spentInPeriod: 0,
                totalFunded: 0,
                totalPaid: 0,
                totalRefunded: 0,
                periodLength: 0,
                periodAnchor: 0,
                periodIndex: 0,
                expiresAt: 0,
                createdAt: 0,
                loosenDelay: 0,
                paymentCount: 0,
                useAllowlist: false,
                paused: false,
                revoked: false
            });
        }
        return _allowances[id];
    }

    /**
     * @notice Returns the label for an allowance.
     * @param id Allowance ID.
     * @return label Label string, or empty string for unknown ID.
     */
    function labelOf(uint256 id) external view returns (string memory label) {
        if (!_exists(id)) {
            return "";
        }
        return _labels[id];
    }

    /**
     * @notice Returns pending limit change for an allowance.
     * @param id Allowance ID.
     * @return Pending limits, or zeroed struct for unknown ID.
     */
    function pendingLimits(uint256 id) external view returns (PendingLimits memory) {
        if (!_exists(id)) {
            return PendingLimits({perPaymentCap: 0, periodCap: 0, expiresAt: 0, activeAt: 0});
        }
        return _pending[id];
    }

    /**
     * @notice Returns currently effective limits (auto-applying matured pending limits in view logic).
     * @param id Allowance ID.
     * @return perPaymentCap Effective per-payment cap.
     * @return periodCap Effective period cap.
     * @return expiresAt Effective expiry timestamp.
     */
    function effectiveLimits(uint256 id)
        external
        view
        returns (uint128 perPaymentCap, uint128 periodCap, uint64 expiresAt)
    {
        return _effectiveLimits(id);
    }

    /**
     * @notice Returns computed budget information for the current period.
     * @param id Allowance ID.
     * @return b Budget snapshot (zeroed where not applicable).
     */
    function budget(uint256 id) external view returns (Budget memory b) {
        if (!_exists(id)) {
            return b;
        }

        Allowance storage a = _allowances[id];
        (uint128 effPerPaymentCap, uint128 effPeriodCap, uint64 effExpiresAt) = _effectiveLimits(id);

        b.status = status(id);
        b.balance = a.balance;
        b.perPaymentCap = effPerPaymentCap;
        b.periodCap = effPeriodCap;
        b.expiresAt = effExpiresAt;

        uint64 currentPeriod = uint64((block.timestamp - a.periodAnchor) / a.periodLength);
        b.periodIndex = currentPeriod;

        uint256 periodStart256 = uint256(a.periodAnchor) + uint256(currentPeriod) * uint256(a.periodLength);
        b.periodStart = uint64(periodStart256);
        b.periodEnd = uint64(periodStart256 + a.periodLength);

        if (currentPeriod > a.periodIndex) {
            b.spentInPeriod = 0;
        } else {
            b.spentInPeriod = a.spentInPeriod;
        }

        // slither-disable-next-line incorrect-equality
        // Safe: b.status is a discrete uint8 enum (0-4 values from status()); not timestamp-derived.
        if (b.status == uint8(1)) {
            // Cap headroom by the period cap, then further cap by the actual balance so that
            // remainingInPeriod and maxPayment never exceed what pay() would actually send.
            uint128 capHeadroom;
            if (b.spentInPeriod >= effPeriodCap) {
                capHeadroom = 0;
            } else {
                capHeadroom = effPeriodCap - b.spentInPeriod;
            }
            uint128 remaining = capHeadroom < a.balance ? capHeadroom : a.balance;
            b.remainingInPeriod = remaining;
            b.maxPayment = remaining < effPerPaymentCap ? remaining : effPerPaymentCap;
        }
    }

    /**
     * @notice Simulates payment rule checks and returns a reason code instead of reverting.
     * @param id Allowance ID.
     * @param payee Payment recipient.
     * @param amount Payment amount.
     * @param ref Optional payment reference.
     * @return ok True if payment is currently allowed.
     * @return reason Reason code (0=OK, 1=Unknown, 2=Revoked, 3=Expired, 4=Paused, 5=InvalidPayee,
     * 6=PayeeNotAllowed, 7=ZeroAmount, 8=ExceedsPaymentCap, 9=ExceedsPeriodCap, 10=InsufficientBalance, 11=DuplicateRef).
     */
    function canPay(uint256 id, address payee, uint256 amount, bytes32 ref) external view returns (bool ok, uint8 reason) {
        if (!_exists(id)) return (false, 1);

        Allowance storage a = _allowances[id];
        (uint128 effPerPaymentCap, uint128 effPeriodCap, uint64 effExpiresAt) = _effectiveLimits(id);

        if (a.revoked) return (false, 2);
        if (effExpiresAt <= block.timestamp) return (false, 3);
        if (a.paused) return (false, 4);
        if (payee == address(0) || payee == address(this) || payee == a.spender) return (false, 5);

        if (a.useAllowlist) {
            uint64 activeAt = _payeeActiveAt[id][payee];
            if (_payeeIndex[id][payee] == 0 || activeAt > block.timestamp) {
                return (false, 6);
            }
        }

        if (amount == 0) return (false, 7);
        if (amount > effPerPaymentCap) return (false, 8);

        uint64 currentPeriod = uint64((block.timestamp - a.periodAnchor) / a.periodLength);
        uint128 spent = currentPeriod > a.periodIndex ? 0 : a.spentInPeriod;
        uint128 remaining = spent >= effPeriodCap ? 0 : (effPeriodCap - spent);

        if (amount > remaining) return (false, 9);
        if (amount > a.balance) return (false, 10);

        if (ref != bytes32(0) && _usedRefs[id][ref]) return (false, 11);

        return (true, 0);
    }

    /**
     * @notice Returns allowance status code.
     * @param id Allowance ID.
     * @return code Status code: 0=None, 1=Active, 2=Paused, 3=Expired, 4=Revoked.
     */
    function status(uint256 id) public view returns (uint8 code) {
        if (!_exists(id)) return 0;

        Allowance storage a = _allowances[id];
        if (a.revoked) return 4;

        (, , uint64 effExpiresAt) = _effectiveLimits(id);
        if (effExpiresAt <= block.timestamp) return 3;
        if (a.paused) return 2;
        return 1;
    }

    /**
     * @notice Returns payees and activation timestamps for an allowance.
     * @param id Allowance ID.
     * @return payees Payee list.
     * @return activeAts Activation timestamp per payee.
     */
    function getPayees(uint256 id) external view returns (address[] memory payees, uint64[] memory activeAts) {
        if (!_exists(id)) {
            return (new address[](0), new uint64[](0));
        }

        address[] storage stored = _payees[id];
        uint256 len = stored.length;

        payees = new address[](len);
        activeAts = new uint64[](len);

        for (uint256 i = 0; i < len; ++i) {
            address p = stored[i];
            payees[i] = p;
            activeAts[i] = _payeeActiveAt[id][p];
        }
    }

    /**
     * @notice Returns allowlist activation timestamp for a payee.
     * @param id Allowance ID.
     * @param payee Payee address.
     * @return Active-at timestamp, or zero if unknown/not listed.
     */
    function payeeActiveAt(uint256 id, address payee) external view returns (uint64) {
        if (!_exists(id)) return 0;
        return _payeeActiveAt[id][payee];
    }

    /**
     * @notice Returns whether a reference is already used for an allowance.
     * @param id Allowance ID.
     * @param ref Reference.
     * @return True if used, false otherwise.
     */
    function isRefUsed(uint256 id, bytes32 ref) external view returns (bool) {
        if (!_exists(id)) return false;
        return _usedRefs[id][ref];
    }

    /**
     * @notice Returns all allowance IDs created by an owner.
     * @param owner Owner address.
     * @return IDs created by owner.
     */
    function idsByOwner(address owner) external view returns (uint256[] memory) {
        return _idsByOwner[owner];
    }

    /**
     * @notice Returns all allowance IDs assigned to a spender.
     * @param spender Spender address.
     * @return IDs assigned to spender.
     */
    function idsBySpender(address spender) external view returns (uint256[] memory) {
        return _idsBySpender[spender];
    }

    /**
     * @notice Returns total number of allowances ever created.
     * @return Number of created allowances.
     */
    function allowanceCount() external view returns (uint256) {
        return _allowanceCount;
    }

    /**
     * @notice Returns total native USDC held across all non-revoked allowance balances.
     * @return Total held amount.
     */
    function totalHeld() external view returns (uint128) {
        return _totalHeld;
    }

    /**
     * @notice Returns whether an allowance ID exists.
     * @param id Allowance ID.
     * @return True if created and owner is set.
     */
    function _exists(uint256 id) internal view returns (bool) {
        return id > 0 && id <= _allowanceCount && _allowances[id].owner != address(0);
    }

    /**
     * @notice Returns effective limits, applying matured pending limits in read logic.
     * @param id Allowance ID.
     * @return perPaymentCap Effective per-payment cap.
     * @return periodCap Effective period cap.
     * @return expiresAt Effective expiry.
     */
    function _effectiveLimits(uint256 id)
        internal
        view
        returns (uint128 perPaymentCap, uint128 periodCap, uint64 expiresAt)
    {
        if (!_exists(id)) {
            return (0, 0, 0);
        }

        PendingLimits storage p = _pending[id];
        if (p.activeAt != 0 && block.timestamp >= p.activeAt) {
            return (p.perPaymentCap, p.periodCap, p.expiresAt);
        }

        Allowance storage a = _allowances[id];
        return (a.perPaymentCap, a.periodCap, a.expiresAt);
    }

    /**
     * @notice Computes current fixed-window period index for an allowance.
     * @param id Allowance ID.
     * @return Current period index.
     */
    function _currentPeriodIndex(uint256 id) internal view returns (uint64) {
        Allowance storage a = _allowances[id];
        return uint64((block.timestamp - a.periodAnchor) / a.periodLength);
    }

    /**
     * @notice Internal non-mutating rule checks for payments.
     * @param a Allowance storage pointer.
     * @param id Allowance ID.
     * @param payee Payment recipient.
     * @param amount Payment amount.
     * @param ref Optional payment reference.
     * @param effPerPaymentCap Effective per-payment cap.
     * @param effPeriodCap Effective period cap.
     * @param effExpiresAt Effective expiry.
     */
    function _checkRules(
        Allowance storage a,
        uint256 id,
        address payee,
        uint256 amount,
        bytes32 ref,
        uint128 effPerPaymentCap,
        uint128 effPeriodCap,
        uint64 effExpiresAt
    ) internal view {
        if (a.revoked) revert AllowanceRevoked();
        if (effExpiresAt <= block.timestamp) revert AllowanceExpired(effExpiresAt);
        if (a.paused) revert AllowancePaused();
        if (payee == address(0) || payee == address(this) || payee == a.spender) revert InvalidPayee(payee);

        if (a.useAllowlist) {
            uint64 activeAt = _payeeActiveAt[id][payee];
            if (_payeeIndex[id][payee] == 0 || activeAt > block.timestamp) revert PayeeNotAllowed(payee);
        }

        if (amount == 0) revert ZeroAmount();
        if (amount > effPerPaymentCap) revert ExceedsPaymentCap(amount, effPerPaymentCap);

        uint64 currentPeriod = _currentPeriodIndex(id);
        uint128 spent = currentPeriod > a.periodIndex ? 0 : a.spentInPeriod;
        uint128 remaining = spent >= effPeriodCap ? 0 : (effPeriodCap - spent);

        if (amount > remaining) revert ExceedsPeriodCap(amount, remaining);
        if (amount > a.balance) revert InsufficientBalance(amount, a.balance);
        if (ref != bytes32(0) && _usedRefs[id][ref]) revert DuplicateRef(ref);
    }
}
