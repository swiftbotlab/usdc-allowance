// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {UsdcAllowance} from "../src/UsdcAllowance.sol";
import {RejectingReceiver} from "./Helpers.sol";

/// @dev Stateful handler with an independent model of every rule. Each call predicts success or the exact revert data
///      (selector + parameters) and compares it with what the contract did; any difference counts as a mismatch.
///      Ghost sums per (allowance, period) are kept WITHOUT the contract's reset logic, to check "spent in period <= cap".
contract AllowanceHandler is Test {
    UsdcAllowance public immutable c;
    address[2] internal owners;
    address[2] internal spenders;
    address[3] internal payees; // payees[2] cannot receive native USDC
    address internal outsider;

    uint256 internal constant MAX_ALLOWANCES = 8;
    bytes32 internal constant R1 = keccak256("invoice-1");
    bytes32 internal constant R2 = keccak256("invoice-2");

    struct M {
        address owner;
        address spender;
        uint128 ppc;
        uint128 pc;
        uint64 exp;
        uint128 qppc;
        uint128 qpc;
        uint64 qexp;
        uint64 qAt;
        uint64 len;
        uint64 anchor;
        uint32 delay;
        bool allowlist;
        bool paused;
        bool revoked;
        uint256 balance;
        uint256 funded;
        uint256 paid;
        uint256 refunded;
        uint64 idx;
        uint256 spent;
        uint256 payments;
    }

    mapping(uint256 => M) internal m;
    uint256 public count;
    mapping(uint256 => mapping(address => uint64)) public payeeAt;
    mapping(uint256 => uint256) public listed;
    mapping(uint256 => mapping(bytes32 => bool)) public refUsed;
    uint256 internal refSeq;

    // ghosts
    mapping(uint256 => mapping(uint256 => uint256)) public ghostPeriodPaid;
    uint256 public mismatches;
    uint256 public capViolations;
    uint256 public perPaymentViolations;
    uint256 public forbiddenPayouts;
    string public lastMismatch;
    mapping(string => uint256) public calls;
    string[] internal callNames;

    constructor(UsdcAllowance c_) {
        c = c_;
        owners = [makeAddr("ownerA"), makeAddr("ownerB")];
        spenders = [makeAddr("agentA"), makeAddr("agentB")];
        payees = [makeAddr("dataApi"), makeAddr("searchApi"), address(new RejectingReceiver())];
        outsider = makeAddr("outsider");
        for (uint256 i = 0; i < 2; i++) {
            vm.deal(owners[i], 1_000 ether);
            vm.deal(spenders[i], 1 ether);
        }
        vm.deal(outsider, 1_000 ether);
        callNames.push("create");
        callNames.push("fund");
        callNames.push("pay_ok");
        callNames.push("pay_rejected");
        callNames.push("setLimits");
        callNames.push("addPayees");
        callNames.push("removePayees");
        callNames.push("pause");
        callNames.push("withdraw");
        callNames.push("revoke");
        callNames.push("warp");
        callNames.push("mismatch");
        string[14] memory rej = ["rej_unknown", "rej_notSpender", "rej_revoked", "rej_expired", "rej_paused",
            "rej_invalidPayee", "rej_payeeNotAllowed", "rej_zero", "rej_paymentCap", "rej_periodCap", "rej_balance",
            "rej_duplicateRef", "rej_transferFailed", "rej_other"];
        for (uint256 i = 0; i < rej.length; i++) callNames.push(rej[i]);
    }

    // ------------------------------------------------------------------ model helpers
    function _count(string memory k) internal {
        calls[k] += 1;
    }

    function _eff(uint256 id) internal view returns (uint128, uint128, uint64) {
        M storage x = m[id];
        if (x.qAt != 0 && block.timestamp >= x.qAt) return (x.qppc, x.qpc, x.qexp);
        return (x.ppc, x.pc, x.exp);
    }

    function _h(uint256 x, string memory tag) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(x, tag))); // spreads the fuzzer's edge values (0, 1, max) evenly
    }

    function _pick(uint256 seed) internal view returns (uint256) {
        if (count == 0) return 0;
        seed = _h(seed, "id");
        if (seed % 25 == 0) return count + 1; // unknown id now and then
        return 1 + (seed % count);
    }

    function _ownedLiveErr(uint256 id, address caller) internal view returns (bytes memory) {
        if (id == 0 || id > count) return abi.encodeWithSelector(UsdcAllowance.UnknownAllowance.selector, id);
        if (caller != m[id].owner) return abi.encodeWithSelector(UsdcAllowance.NotOwner.selector);
        if (m[id].revoked) return abi.encodeWithSelector(UsdcAllowance.AllowanceRevoked.selector);
        return "";
    }

    function _compare(bool ok, bytes memory got, bytes memory expected, string memory what) internal returns (bool) {
        bool same = expected.length == 0 ? ok : (!ok && keccak256(got) == keccak256(expected));
        if (!same) {
            mismatches += 1;
            lastMismatch = what;
            _count("mismatch");
            emit log_named_string("MISMATCH", what);
            emit log_named_bytes("expected", expected);
            emit log_named_bytes("got", got);
        }
        return same && ok;
    }

    function _owner(uint256 id, uint256 sel) internal view returns (address) {
        if (_h(sel, "owner") % 10 == 0 || id == 0 || id > count) return outsider;
        return m[id].owner;
    }

    // ------------------------------------------------------------------ actions
    function create(uint256 seed) external {
        if (count >= MAX_ALLOWANCES) return;
        address o = owners[seed % 2];
        address s = spenders[(seed >> 1) % 2];
        UsdcAllowance.Rules memory r;
        r.perPaymentCap = uint128(bound(seed >> 8, 1e15, 0.05e18));
        r.periodCap = uint128(bound(seed >> 72, r.perPaymentCap, 3 * uint256(r.perPaymentCap))); // caps bind often
        uint64[3] memory lens = [uint64(60), 300, 3600];
        r.periodLength = lens[(seed >> 136) % 3];
        uint256 mode = (seed >> 140) % 3;
        r.periodAnchor = mode == 0 ? uint64(block.timestamp) : mode == 1 ? 0 : uint64(block.timestamp - ((seed >> 144) % (3 * r.periodLength)));
        r.expiresAt = uint64(block.timestamp + bound(uint256(keccak256(abi.encode(seed, "exp"))), 1 hours, 3 days));
        uint32[3] memory delays = [uint32(0), 120, 600];
        r.loosenDelay = delays[(seed >> 200) % 3];
        r.useAllowlist = (seed >> 210) % 2 == 0;
        uint256 n = 0;
        address[] memory ps = new address[](3);
        if (r.useAllowlist) {
            uint256 bits = _h(seed, "payees");
            for (uint256 i = 0; i < 3; i++) {
                if (i == 0 ? bits % 5 != 0 : (bits >> (8 + i)) & 1 == 1) ps[n++] = payees[i];
            }
        }
        assembly {
            mstore(ps, n)
        }
        uint256 value = bound(uint256(keccak256(abi.encode(seed, "value"))), 0, 1e18);
        vm.prank(o);
        uint256 id = c.createAllowance{value: value}(s, r, ps, "handler");
        require(id == count + 1, "id sequence");
        count = id;
        M storage x = m[id];
        x.owner = o;
        x.spender = s;
        x.ppc = r.perPaymentCap;
        x.pc = r.periodCap;
        x.exp = r.expiresAt;
        x.len = r.periodLength;
        x.anchor = r.periodAnchor;
        x.delay = r.loosenDelay;
        x.allowlist = r.useAllowlist;
        x.balance = value;
        x.funded = value;
        x.idx = uint64((block.timestamp - r.periodAnchor) / r.periodLength);
        for (uint256 i = 0; i < n; i++) {
            payeeAt[id][ps[i]] = uint64(block.timestamp);
        }
        listed[id] = n;
        _count("create");
    }

    function fund(uint256 idSeed, uint256 amount, uint256 sel) external {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        address caller = _owner(id, sel);
        amount = bound(amount, 0, 0.3e18);
        bytes memory exp = _ownedLiveErr(id, caller);
        if (exp.length == 0 && amount == 0) exp = abi.encodeWithSelector(UsdcAllowance.ZeroAmount.selector);
        vm.prank(caller);
        (bool ok, bytes memory got) = address(c).call{value: amount}(abi.encodeCall(UsdcAllowance.fund, (id)));
        if (_compare(ok, got, exp, "fund")) {
            m[id].balance += amount;
            m[id].funded += amount;
            _count("fund");
        }
    }

    function _expectPay(uint256 id, address caller, address payee, uint256 amount, bytes32 ref)
        internal
        view
        returns (bytes memory)
    {
        if (id == 0 || id > count) return abi.encodeWithSelector(UsdcAllowance.UnknownAllowance.selector, id);
        M storage x = m[id];
        if (caller != x.spender) return abi.encodeWithSelector(UsdcAllowance.NotSpender.selector);
        (uint128 ppc, uint128 pc, uint64 exp) = _eff(id);
        if (x.revoked) return abi.encodeWithSelector(UsdcAllowance.AllowanceRevoked.selector);
        if (block.timestamp >= exp) return abi.encodeWithSelector(UsdcAllowance.AllowanceExpired.selector, exp);
        if (x.paused) return abi.encodeWithSelector(UsdcAllowance.AllowancePaused.selector);
        if (payee == address(0) || payee == address(c) || payee == x.spender) {
            return abi.encodeWithSelector(UsdcAllowance.InvalidPayee.selector, payee);
        }
        if (x.allowlist) {
            uint64 at = payeeAt[id][payee];
            if (at == 0 || block.timestamp < at) return abi.encodeWithSelector(UsdcAllowance.PayeeNotAllowed.selector, payee);
        }
        if (amount == 0) return abi.encodeWithSelector(UsdcAllowance.ZeroAmount.selector);
        if (amount > ppc) return abi.encodeWithSelector(UsdcAllowance.ExceedsPaymentCap.selector, amount, uint256(ppc));
        uint64 k = uint64((block.timestamp - x.anchor) / x.len);
        uint256 spent = k == x.idx ? x.spent : 0;
        uint256 left = pc > spent ? pc - spent : 0;
        if (amount > left) return abi.encodeWithSelector(UsdcAllowance.ExceedsPeriodCap.selector, amount, left);
        if (amount > x.balance) {
            return abi.encodeWithSelector(UsdcAllowance.InsufficientBalance.selector, amount, x.balance);
        }
        if (ref != bytes32(0) && refUsed[id][ref]) return abi.encodeWithSelector(UsdcAllowance.DuplicateRef.selector, ref);
        if (payee == payees[2]) return abi.encodeWithSelector(UsdcAllowance.TransferFailed.selector);
        return "";
    }

    function pay(uint256 idSeed, uint256 payeeSel, uint256 amount, uint256 refSel, uint256 callerSel) external {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        address caller;
        callerSel = _h(callerSel, "caller");
        if (callerSel % 10 == 0) caller = callerSel % 20 == 0 ? outsider : owners[(callerSel >> 8) % 2];
        else caller = id <= count ? m[id].spender : spenders[0];
        uint256 ps = _h(payeeSel, "payee") % 12;
        address payee = ps < 5 ? payees[0] : ps < 8 ? payees[1] : ps < 10 ? payees[2] : ps == 10 ? address(0)
            : (id <= count ? m[id].spender : payees[0]);
        uint256 rs = _h(refSel, "ref") % 5;
        bytes32 ref = rs == 0 ? bytes32(0) : rs == 1 ? R1 : rs == 2 ? R2 : keccak256(abi.encode("unique", ++refSeq));
        uint256 hi = id <= count ? uint256(m[id].ppc) * 13 / 10 + 1 : 0.07e18; // mostly within the per-payment cap
        uint256 amt = bound(amount, 0, hi);
        if (id <= count && _h(amount, "exact") % 4 == 0) {
            // pay exactly what is left in this period (hits the cap boundary; the next payment must fail)
            (uint128 ppc, uint128 pc,) = _eff(id);
            M storage x = m[id];
            uint256 spentNow = uint64((block.timestamp - x.anchor) / x.len) == x.idx ? x.spent : 0;
            amt = pc > spentNow ? pc - spentNow : 1;
            if (amt > ppc) amt = ppc;
        }
        _doPay(id, caller, payee, amt, ref);
    }

    function _doPay(uint256 id, address caller, address payee, uint256 amount, bytes32 ref) internal {
        bytes memory exp = _expectPay(id, caller, payee, amount, ref);
        uint256 payeeBefore = payee.balance;
        (bool canOk, uint8 reason) = c.canPay(id, payee, amount, ref);
        vm.prank(caller);
        (bool ok, bytes memory got) =
            address(c).call(abi.encodeCall(UsdcAllowance.pay, (id, payee, amount, ref, "invariant")));
        if (!_compare(ok, got, exp, "pay")) {
            _count("pay_rejected");
            _countReason(got);
            return;
        }
        // success: canPay must have agreed; the payee got exactly `amount`
        if (!canOk || reason != 0) {
            mismatches += 1;
            lastMismatch = "canPay said no but pay succeeded";
        }
        if (payee.balance - payeeBefore != amount) forbiddenPayouts += 1;
        _afterPay(id, payee, amount, ref);
    }

    function _countReason(bytes memory got) internal {
        bytes4 sel = got.length >= 4 ? bytes4(got) : bytes4(0);
        if (sel == UsdcAllowance.UnknownAllowance.selector) _count("rej_unknown");
        else if (sel == UsdcAllowance.NotSpender.selector) _count("rej_notSpender");
        else if (sel == UsdcAllowance.AllowanceRevoked.selector) _count("rej_revoked");
        else if (sel == UsdcAllowance.AllowanceExpired.selector) _count("rej_expired");
        else if (sel == UsdcAllowance.AllowancePaused.selector) _count("rej_paused");
        else if (sel == UsdcAllowance.InvalidPayee.selector) _count("rej_invalidPayee");
        else if (sel == UsdcAllowance.PayeeNotAllowed.selector) _count("rej_payeeNotAllowed");
        else if (sel == UsdcAllowance.ZeroAmount.selector) _count("rej_zero");
        else if (sel == UsdcAllowance.ExceedsPaymentCap.selector) _count("rej_paymentCap");
        else if (sel == UsdcAllowance.ExceedsPeriodCap.selector) _count("rej_periodCap");
        else if (sel == UsdcAllowance.InsufficientBalance.selector) _count("rej_balance");
        else if (sel == UsdcAllowance.DuplicateRef.selector) _count("rej_duplicateRef");
        else if (sel == UsdcAllowance.TransferFailed.selector) _count("rej_transferFailed");
        else _count("rej_other");
    }

    function _afterPay(uint256 id, address payee, uint256 amount, bytes32 ref) internal {
        M storage x = m[id];
        if (x.allowlist && (payeeAt[id][payee] == 0 || block.timestamp < payeeAt[id][payee])) forbiddenPayouts += 1;
        (uint128 ppc, uint128 pc,) = _eff(id);
        uint64 k = uint64((block.timestamp - x.anchor) / x.len);
        uint256 spent = k == x.idx ? x.spent : 0;
        x.idx = k;
        x.spent = spent + amount;
        x.balance -= amount;
        x.paid += amount;
        x.payments += 1;
        if (ref != bytes32(0)) refUsed[id][ref] = true;
        ghostPeriodPaid[id][k] += amount;
        if (ghostPeriodPaid[id][k] > pc) capViolations += 1;
        if (amount > ppc) perPaymentViolations += 1;
        _count("pay_ok");
    }

    function setLimits(uint256 idSeed, uint256 a, uint256 b, uint256 e, uint256 sel) external {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        address caller = _owner(id, sel);
        uint128 ppc = uint128(bound(a, 0, 0.06e18));
        uint128 pc = uint128(bound(b, 0, 0.25e18));
        uint64 exp = uint64(block.timestamp + bound(e, 0, 4 days));
        bytes memory err = _ownedLiveErr(id, caller);
        if (err.length == 0 && (ppc == 0 || ppc > pc || exp <= block.timestamp)) {
            err = abi.encodeWithSelector(UsdcAllowance.InvalidRules.selector);
        }
        vm.prank(caller);
        (bool ok, bytes memory got) = address(c).call(abi.encodeCall(UsdcAllowance.setLimits, (id, ppc, pc, exp)));
        if (!_compare(ok, got, err, "setLimits")) return;
        M storage x = m[id];
        if (x.qAt != 0 && block.timestamp >= x.qAt) {
            (x.ppc, x.pc, x.exp, x.qAt) = (x.qppc, x.qpc, x.qexp, 0);
        }
        bool loosens = ppc > x.ppc || pc > x.pc || exp > x.exp;
        if (!loosens || x.delay == 0) {
            (x.ppc, x.pc, x.exp, x.qAt) = (ppc, pc, exp, 0);
        } else {
            if (ppc < x.ppc) x.ppc = ppc;
            if (pc < x.pc) x.pc = pc;
            if (exp < x.exp) x.exp = exp;
            (x.qppc, x.qpc, x.qexp, x.qAt) = (ppc, pc, exp, uint64(block.timestamp) + x.delay);
        }
        _count("setLimits");
    }

    function addPayees(uint256 idSeed, uint256 bits, uint256 sel) external {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        address caller = _owner(id, sel);
        address[4] memory cand = [payees[0], payees[1], payees[2], id <= count ? m[id].spender : address(0)];
        address[] memory list = new address[](4);
        uint256 n = 0;
        for (uint256 i = 0; i < 4; i++) {
            if ((bits >> i) & 1 == 1 && (i < 3 || bits % 7 == 0)) list[n++] = cand[i];
        }
        assembly {
            mstore(list, n)
        }
        bytes memory err = _ownedLiveErr(id, caller);
        if (err.length == 0 && !m[id].allowlist) err = abi.encodeWithSelector(UsdcAllowance.AllowlistDisabled.selector);
        if (err.length == 0) {
            for (uint256 i = 0; i < n; i++) {
                address p = list[i];
                if (p == address(0) || p == address(c) || p == m[id].spender) {
                    err = abi.encodeWithSelector(UsdcAllowance.InvalidPayee.selector, p);
                    break;
                }
            }
        }
        vm.prank(caller);
        (bool ok, bytes memory got) = address(c).call(abi.encodeCall(UsdcAllowance.addPayees, (id, list)));
        if (!_compare(ok, got, err, "addPayees")) return;
        for (uint256 i = 0; i < n; i++) {
            if (payeeAt[id][list[i]] == 0) {
                payeeAt[id][list[i]] = uint64(block.timestamp) + m[id].delay;
                listed[id] += 1;
            }
        }
        _count("addPayees");
    }

    function removePayees(uint256 idSeed, uint256 bits, uint256 sel) external {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        address caller = _owner(id, sel);
        address[] memory list = new address[](3);
        uint256 n = 0;
        for (uint256 i = 0; i < 3; i++) {
            if ((bits >> i) & 1 == 1) list[n++] = payees[i];
        }
        assembly {
            mstore(list, n)
        }
        bytes memory err = _ownedLiveErr(id, caller);
        vm.prank(caller);
        (bool ok, bytes memory got) = address(c).call(abi.encodeCall(UsdcAllowance.removePayees, (id, list)));
        if (!_compare(ok, got, err, "removePayees")) return;
        for (uint256 i = 0; i < n; i++) {
            if (payeeAt[id][list[i]] != 0) {
                payeeAt[id][list[i]] = 0;
                listed[id] -= 1;
            }
        }
        _count("removePayees");
    }

    function setPaused(uint256 idSeed, uint256 pSel, uint256 sel) external {
        bool p = _h(pSel, "pause") % 3 == 0; // pause 1/3, unpause 2/3
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        address caller = _owner(id, sel);
        bytes memory err = _ownedLiveErr(id, caller);
        vm.prank(caller);
        (bool ok, bytes memory got) =
            address(c).call(p ? abi.encodeCall(UsdcAllowance.pause, (id)) : abi.encodeCall(UsdcAllowance.unpause, (id)));
        if (!_compare(ok, got, err, "pause")) return;
        m[id].paused = p;
        _count("pause");
    }

    function withdraw(uint256 idSeed, uint256 amount, uint256 sel) external {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        address caller = _owner(id, sel);
        amount = bound(amount, 0, 0.4e18);
        bytes memory err = _ownedLiveErr(id, caller);
        if (err.length == 0 && amount == 0) err = abi.encodeWithSelector(UsdcAllowance.ZeroAmount.selector);
        if (err.length == 0 && amount > m[id].balance) {
            err = abi.encodeWithSelector(UsdcAllowance.InsufficientBalance.selector, amount, m[id].balance);
        }
        uint256 before = caller.balance;
        vm.prank(caller);
        (bool ok, bytes memory got) = address(c).call(abi.encodeCall(UsdcAllowance.withdraw, (id, amount)));
        if (!_compare(ok, got, err, "withdraw")) return;
        if (caller.balance - before != amount) forbiddenPayouts += 1;
        m[id].balance -= amount;
        m[id].refunded += amount;
        _count("withdraw");
    }

    function revoke(uint256 idSeed, uint256 sel) external {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        if (_h(sel, "revoke") % 16 != 0 && id <= count) return; // keep most allowances alive for longer runs
        address caller = _owner(id, sel);
        bytes memory err = _ownedLiveErr(id, caller);
        uint256 before = caller.balance;
        vm.prank(caller);
        (bool ok, bytes memory got) = address(c).call(abi.encodeCall(UsdcAllowance.revoke, (id)));
        if (!_compare(ok, got, err, "revoke")) return;
        M storage x = m[id];
        if (caller.balance - before != x.balance) forbiddenPayouts += 1;
        x.refunded += x.balance;
        x.balance = 0;
        x.revoked = true;
        x.qAt = 0;
        _count("revoke");
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 1, 600);
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + 1);
        _count("warp");
    }

    // ------------------------------------------------------------------ read helpers for the invariants
    function modelEff(uint256 id) external view returns (uint128, uint128, uint64) {
        return _eff(id);
    }

    function modelPending(uint256 id) external view returns (uint128, uint128, uint64, uint64) {
        M storage x = m[id];
        return (x.qppc, x.qpc, x.qexp, x.qAt);
    }

    function modelSpentNow(uint256 id) external view returns (uint256) {
        M storage x = m[id];
        uint64 k = uint64((block.timestamp - x.anchor) / x.len);
        return k == x.idx ? x.spent : 0;
    }

    function modelMoney(uint256 id) external view returns (uint256 balance, uint256 funded, uint256 paid, uint256 refunded) {
        M storage x = m[id];
        return (x.balance, x.funded, x.paid, x.refunded);
    }

    function payeeAddr(uint256 i) external view returns (address) {
        return payees[i];
    }

    function summary() external view {
        for (uint256 i = 0; i < callNames.length; i++) {
            console.log(callNames[i], calls[callNames[i]]);
        }
    }
}

contract UsdcAllowanceInvariants is StdInvariant, Test {
    UsdcAllowance internal c;
    AllowanceHandler internal h;

    function setUp() public {
        vm.warp(1_760_000_000);
        c = new UsdcAllowance();
        h = new AllowanceHandler(c);
        bytes4[] memory sels = new bytes4[](14);
        sels[0] = AllowanceHandler.create.selector;
        sels[1] = AllowanceHandler.fund.selector;
        sels[2] = AllowanceHandler.pay.selector;
        sels[3] = AllowanceHandler.pay.selector; // payments weighted x3
        sels[4] = AllowanceHandler.pay.selector;
        sels[5] = AllowanceHandler.setLimits.selector;
        sels[6] = AllowanceHandler.addPayees.selector;
        sels[7] = AllowanceHandler.removePayees.selector;
        sels[8] = AllowanceHandler.setPaused.selector;
        sels[9] = AllowanceHandler.withdraw.selector;
        sels[10] = AllowanceHandler.warp.selector;
        sels[11] = AllowanceHandler.revoke.selector; // revoke() itself only acts on 1 call in 16
        sels[12] = AllowanceHandler.pay.selector; // payments weighted x5 in total
        sels[13] = AllowanceHandler.pay.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sels}));
        targetContract(address(h));
    }

    /// I0: the contract did exactly what the model predicted (same success, same revert data) on every call.
    function invariant_matchesModel() public view {
        assertEq(h.mismatches(), 0, h.lastMismatch());
    }

    /// I1 solvency: contract balance == totalHeld == sum of allowance balances (== model).
    function invariant_solvency() public view {
        uint256 sum;
        for (uint256 id = 1; id <= h.count(); id++) {
            uint256 bal = c.getAllowance(id).balance;
            (uint256 mbal,,,) = h.modelMoney(id);
            assertEq(bal, mbal, "balance == model");
            sum += bal;
        }
        assertEq(c.totalHeld(), sum, "totalHeld == sum of balances");
        assertEq(address(c).balance, sum, "USDC held == sum of balances");
    }

    /// I2 conservation per allowance: totalFunded == balance + totalPaid + totalRefunded.
    function invariant_conservation() public view {
        for (uint256 id = 1; id <= h.count(); id++) {
            UsdcAllowance.Allowance memory a = c.getAllowance(id);
            assertEq(uint256(a.totalFunded), uint256(a.balance) + a.totalPaid + a.totalRefunded, "funded == bal + paid + refunded");
            (, uint256 funded, uint256 paid, uint256 refunded) = h.modelMoney(id);
            assertEq(a.totalFunded, funded);
            assertEq(a.totalPaid, paid);
            assertEq(a.totalRefunded, refunded);
        }
    }

    /// I3/I4: every successful payment kept the period total (ghost sum, independent of the contract's reset logic)
    ///        within the period cap in force at that moment, and its amount within the per-payment cap; nobody but
    ///        an active allowed payee (or the owner on withdraw/revoke) ever received USDC.
    function invariant_capsHold() public view {
        assertEq(h.capViolations(), 0, "spent in period <= cap");
        assertEq(h.perPaymentViolations(), 0, "amount <= perPaymentCap");
        assertEq(h.forbiddenPayouts(), 0, "only allowed recipients, exact amounts");
    }

    /// I5: views agree with the model (effective limits, status, period spend, remaining budget, payee list).
    function invariant_viewsMatchModel() public view {
        for (uint256 id = 1; id <= h.count(); id++) {
            _checkLimits(id);
            _checkBudget(id);
            _checkPayees(id);
        }
    }

    function _checkLimits(uint256 id) internal view {
        (uint128 ppc, uint128 pc, uint64 exp) = c.effectiveLimits(id);
        (uint128 mppc, uint128 mpc, uint64 mexp) = h.modelEff(id);
        assertEq(ppc, mppc, "effective perPaymentCap");
        assertEq(pc, mpc, "effective periodCap");
        assertEq(exp, mexp, "effective expiresAt");
        UsdcAllowance.PendingLimits memory p = c.pendingLimits(id);
        (uint128 qppc, uint128 qpc, uint64 qexp, uint64 qAt) = h.modelPending(id);
        assertEq(p.activeAt, qAt, "pending activeAt");
        if (qAt != 0) {
            assertEq(p.perPaymentCap, qppc, "pending perPaymentCap");
            assertEq(p.periodCap, qpc, "pending periodCap");
            assertEq(p.expiresAt, qexp, "pending expiresAt");
        }
    }

    function _checkBudget(uint256 id) internal view {
        UsdcAllowance.Budget memory b = c.budget(id);
        UsdcAllowance.Allowance memory a = c.getAllowance(id);
        (uint128 ppc, uint128 pc, uint64 exp) = h.modelEff(id);
        assertEq(b.spentInPeriod, h.modelSpentNow(id), "spent in current period");
        uint8 st = a.revoked ? 4 : block.timestamp >= exp ? 3 : a.paused ? 2 : 1;
        assertEq(b.status, st);
        assertEq(c.status(id), st);
        if (st == 1) {
            uint256 left = pc > b.spentInPeriod ? pc - b.spentInPeriod : 0;
            uint256 rem = left < a.balance ? left : a.balance;
            assertEq(b.remainingInPeriod, rem, "budget remaining in period");
            assertEq(b.maxPayment, rem < ppc ? rem : ppc);
        } else {
            assertEq(b.remainingInPeriod, 0);
        }
        assertLe(b.periodStart, block.timestamp);
        assertGt(b.periodEnd, block.timestamp);
    }

    function _checkPayees(uint256 id) internal view {
        (address[] memory ps, uint64[] memory at) = c.getPayees(id);
        assertEq(ps.length, h.listed(id), "payee count");
        assertLe(ps.length, c.MAX_PAYEES());
        for (uint256 i = 0; i < ps.length; i++) {
            assertEq(at[i], h.payeeAt(id, ps[i]), "payee activeAt");
            for (uint256 j = i + 1; j < ps.length; j++) {
                assertTrue(ps[i] != ps[j], "no duplicate payees");
            }
        }
    }

    /// I6: revoked is terminal: balance 0, no pending change, status Revoked.
    function invariant_revokedIsTerminal() public view {
        for (uint256 id = 1; id <= h.count(); id++) {
            UsdcAllowance.Allowance memory a = c.getAllowance(id);
            if (a.revoked) {
                assertEq(a.balance, 0);
                assertEq(c.pendingLimits(id).activeAt, 0);
                assertEq(c.status(id), 4);
                (bool ok,) = c.canPay(id, h.payeeAddr(0), 1, 0);
                assertFalse(ok);
            }
        }
    }

    function afterInvariant() external view {
        h.summary();
    }
}
