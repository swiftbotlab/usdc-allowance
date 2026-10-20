// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UsdcAllowance} from "../src/UsdcAllowance.sol";
import {RejectingReceiver, ReentrantOwner, SpenderAccount, GreedyPayee} from "./Helpers.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract UsdcAllowanceTest is Test {
    UsdcAllowance internal c;
    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("researchAgent");
    address internal api = makeAddr("dataApi");
    address internal api2 = makeAddr("otherApi");
    address internal stranger = makeAddr("stranger");

    uint128 internal constant PPC = 0.10e18; // per-payment cap
    uint128 internal constant PC = 0.15e18; // per-period cap
    uint64 internal constant L = 300; // 5-minute periods
    uint256 internal constant T0 = 1_760_000_000;

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

    function setUp() public {
        vm.warp(T0);
        c = new UsdcAllowance();
        vm.deal(owner, 100 ether);
        vm.deal(agent, 1 ether);
        vm.deal(stranger, 1 ether);
    }

    // ------------------------------------------------------------------ helpers
    function _rules(uint32 delay, bool allowlist) internal view returns (UsdcAllowance.Rules memory) {
        return UsdcAllowance.Rules({
            perPaymentCap: PPC,
            periodCap: PC,
            periodLength: L,
            periodAnchor: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 30 days),
            loosenDelay: delay,
            useAllowlist: allowlist
        });
    }

    function _one(address a) internal pure returns (address[] memory x) {
        x = new address[](1);
        x[0] = a;
    }

    function _none() internal pure returns (address[] memory x) {
        x = new address[](0);
    }

    function _create(uint256 value, uint32 delay) internal returns (uint256 id) {
        vm.prank(owner);
        id = c.createAllowance{value: value}(agent, _rules(delay, true), _one(api), "research-agent");
    }

    function _createOpen(uint256 value) internal returns (uint256 id) {
        vm.prank(owner);
        id = c.createAllowance{value: value}(agent, _rules(0, false), _none(), "open");
    }

    function _pay(uint256 id, address payee, uint256 amount, bytes32 ref) internal {
        vm.prank(agent);
        c.pay(id, payee, amount, ref, "GET /v1/prices");
    }

    function _expectCreateRevert(UsdcAllowance.Rules memory r, address[] memory payees, bytes memory err) internal {
        vm.prank(owner);
        vm.expectRevert(err);
        c.createAllowance{value: 1e17}(agent, r, payees, "x");
    }

    function _conserved(uint256 id) internal view {
        UsdcAllowance.Allowance memory a = c.getAllowance(id);
        assertEq(uint256(a.totalFunded), uint256(a.balance) + a.totalPaid + a.totalRefunded, "funded == balance + paid + refunded");
    }

    // ------------------------------------------------------------------ create / fund
    function test_create_storesEverything() public {
        vm.expectEmit(true, true, true, true, address(c));
        emit AllowanceCreated(1, owner, agent, L, uint64(T0), 120, true, "research-agent");
        vm.expectEmit(true, true, true, true, address(c));
        emit LimitsChanged(1, PPC, PC, uint64(T0 + 30 days));
        vm.expectEmit(true, true, true, true, address(c));
        emit PayeeAdded(1, api, uint64(T0)); // initial payees are active at once, even with a loosen delay
        vm.expectEmit(true, true, true, true, address(c));
        emit Funded(1, owner, 0.30e18, 0.30e18);
        uint256 id = _create(0.30e18, 120);
        assertEq(id, 1);
        UsdcAllowance.Allowance memory a = c.getAllowance(id);
        assertEq(a.owner, owner);
        assertEq(a.spender, agent);
        assertEq(a.perPaymentCap, PPC);
        assertEq(a.periodCap, PC);
        assertEq(a.balance, 0.30e18);
        assertEq(a.totalFunded, 0.30e18);
        assertEq(a.periodLength, L);
        assertEq(a.periodAnchor, T0);
        assertEq(a.periodIndex, 0);
        assertEq(a.expiresAt, T0 + 30 days);
        assertEq(a.createdAt, T0);
        assertEq(a.loosenDelay, 120);
        assertTrue(a.useAllowlist);
        assertFalse(a.paused);
        assertFalse(a.revoked);
        assertEq(c.labelOf(id), "research-agent");
        assertEq(c.allowanceCount(), 1);
        assertEq(c.totalHeld(), 0.30e18);
        assertEq(address(c).balance, 0.30e18);
        assertEq(c.idsByOwner(owner).length, 1);
        assertEq(c.idsBySpender(agent)[0], 1);
        assertEq(c.payeeActiveAt(id, api), T0);
        assertEq(c.status(id), 1);
        (address[] memory ps, uint64[] memory at) = c.getPayees(id);
        assertEq(ps.length, 1);
        assertEq(ps[0], api);
        assertEq(at[0], T0);
    }

    function test_create_unfundedThenFund() public {
        vm.prank(owner);
        uint256 id = c.createAllowance(agent, _rules(0, true), _one(api), "");
        assertEq(c.getAllowance(id).balance, 0);
        assertEq(c.labelOf(id), "");
        (bool ok, uint8 reason) = c.canPay(id, api, 1e16, 0);
        assertFalse(ok);
        assertEq(reason, 10); // InsufficientBalance
        vm.expectEmit(true, true, true, true, address(c));
        emit Funded(id, owner, 0.2e18, 0.2e18);
        vm.prank(owner);
        c.fund{value: 0.2e18}(id);
        vm.prank(owner);
        c.fund{value: 0.1e18}(id);
        assertEq(c.getAllowance(id).balance, 0.3e18);
        assertEq(c.getAllowance(id).totalFunded, 0.3e18);
        assertEq(c.totalHeld(), 0.3e18);
    }

    function test_create_multiplePerOwnerAndSpender() public {
        uint256 a = _create(0.1e18, 0);
        uint256 b = _createOpen(0.1e18);
        vm.prank(stranger);
        uint256 x = c.createAllowance{value: 0.1e18}(agent, _rules(0, false), _none(), "other owner");
        assertEq(c.idsByOwner(owner).length, 2);
        assertEq(c.idsByOwner(owner)[0], a);
        assertEq(c.idsByOwner(owner)[1], b);
        assertEq(c.idsByOwner(stranger)[0], x);
        assertEq(c.idsBySpender(agent).length, 3);
        assertEq(c.totalHeld(), 0.3e18);
    }

    function test_create_reverts() public {
        UsdcAllowance.Rules memory r = _rules(0, true);
        address[] memory p = _one(api);
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.ZeroAddress.selector);
        c.createAllowance(address(0), r, p, "");
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.InvalidRules.selector);
        c.createAllowance(address(c), r, p, "");
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.LabelTooLong.selector);
        c.createAllowance(agent, r, p, "123456789012345678901234567890123"); // 33 bytes

        bytes memory bad = abi.encodeWithSelector(UsdcAllowance.InvalidRules.selector);
        r = _rules(0, true);
        r.perPaymentCap = 0;
        _expectCreateRevert(r, p, bad);
        r = _rules(0, true);
        r.perPaymentCap = PC + 1;
        _expectCreateRevert(r, p, bad);
        r = _rules(0, true);
        r.expiresAt = uint64(block.timestamp);
        _expectCreateRevert(r, p, bad);
        r = _rules(0, true);
        r.expiresAt = uint64(block.timestamp + 3650 days + 1);
        _expectCreateRevert(r, p, bad);
        r = _rules(0, true);
        r.periodLength = 59;
        _expectCreateRevert(r, p, bad);
        r = _rules(0, true);
        r.periodLength = 365 days + 1;
        _expectCreateRevert(r, p, bad);
        r = _rules(0, true);
        r.periodAnchor = uint64(block.timestamp + 1);
        _expectCreateRevert(r, p, bad);
        r = _rules(0, true);
        r.loosenDelay = 30 days + 1;
        _expectCreateRevert(r, p, bad);
        r = _rules(0, false);
        _expectCreateRevert(r, p, bad); // payees given without an allowlist

        r = _rules(0, true);
        address[] memory many = new address[](21);
        for (uint256 i = 0; i < 21; i++) many[i] = address(uint160(0x1000 + i));
        _expectCreateRevert(r, many, abi.encodeWithSelector(UsdcAllowance.TooManyPayees.selector));
        _expectCreateRevert(r, _one(address(0)), abi.encodeWithSelector(UsdcAllowance.InvalidPayee.selector, address(0)));
        _expectCreateRevert(r, _one(address(c)), abi.encodeWithSelector(UsdcAllowance.InvalidPayee.selector, address(c)));
        _expectCreateRevert(r, _one(agent), abi.encodeWithSelector(UsdcAllowance.InvalidPayee.selector, agent));
        address[] memory dup = new address[](2);
        dup[0] = api;
        dup[1] = api;
        _expectCreateRevert(r, dup, abi.encodeWithSelector(UsdcAllowance.InvalidPayee.selector, api));

        vm.deal(owner, uint256(type(uint128).max) + 2);
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.AmountTooLarge.selector);
        c.createAllowance{value: uint256(type(uint128).max) + 1}(agent, r, p, "");
        assertEq(c.allowanceCount(), 0);
    }

    function test_create_boundaryValuesAccepted() public {
        UsdcAllowance.Rules memory r = _rules(30 days, true);
        r.periodLength = 60;
        r.perPaymentCap = PC; // == periodCap is allowed
        r.expiresAt = uint64(block.timestamp + 3650 days);
        address[] memory twenty = new address[](20);
        for (uint256 i = 0; i < 20; i++) twenty[i] = address(uint160(0x1000 + i));
        vm.prank(owner);
        uint256 id = c.createAllowance(agent, r, twenty, "12345678901234567890123456789012"); // 32 bytes
        (address[] memory ps,) = c.getPayees(id);
        assertEq(ps.length, 20);
        r.periodLength = 365 days;
        r.periodAnchor = 0;
        vm.prank(owner);
        c.createAllowance(agent, r, _none(), "");
        assertEq(c.allowanceCount(), 2);
    }

    function test_create_anchorZeroGivesUtcDays() public {
        vm.warp(1_760_054_400 + 13 hours); // 2025-10-10 13:00 UTC (1_760_054_400 is a UTC midnight)
        UsdcAllowance.Rules memory r = _rules(0, false);
        r.periodLength = 1 days;
        r.periodAnchor = 0;
        vm.prank(owner);
        uint256 id = c.createAllowance{value: 1e18}(agent, r, _none(), "daily");
        UsdcAllowance.Budget memory b = c.budget(id);
        assertEq(b.periodStart, 1_760_054_400, "period starts at UTC midnight");
        assertEq(b.periodEnd, 1_760_054_400 + 1 days, "resets at the next UTC midnight");
        assertEq(b.periodIndex, 1_760_054_400 / 1 days);
    }

    function test_fund_reverts() public {
        uint256 id = _create(0.1e18, 0);
        vm.prank(stranger);
        vm.expectRevert(UsdcAllowance.NotOwner.selector);
        c.fund{value: 1}(id);
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.ZeroAmount.selector);
        c.fund(id);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.UnknownAllowance.selector, 2));
        c.fund{value: 1}(2);
        vm.prank(owner);
        c.revoke(id);
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.AllowanceRevoked.selector);
        c.fund{value: 1}(id);
    }

    function test_noReceive() public {
        vm.prank(owner);
        (bool ok,) = address(c).call{value: 1}("");
        assertFalse(ok, "plain transfers are refused");
        vm.prank(owner);
        (ok,) = address(c).call{value: 1}(hex"deadbeef");
        assertFalse(ok);
    }

    // ------------------------------------------------------------------ pay: the demo story
    function test_pay_demoStory_threePaidFourthRejected() public {
        uint256 id = _create(0.30e18, 0);
        uint256 apiBefore = api.balance;
        for (uint256 i = 1; i <= 3; i++) {
            vm.expectEmit(true, true, true, true, address(c));
            emit Paid(id, api, bytes32(i), agent, 0.05e18, 0, 0.05e18 * i, "GET /v1/prices");
            _pay(id, api, 0.05e18, bytes32(i));
        }
        assertEq(api.balance - apiBefore, 0.15e18);
        UsdcAllowance.Allowance memory a = c.getAllowance(id);
        assertEq(a.balance, 0.15e18);
        assertEq(a.totalPaid, 0.15e18);
        assertEq(a.spentInPeriod, 0.15e18);
        assertEq(a.paymentCount, 3);
        UsdcAllowance.Budget memory b = c.budget(id);
        assertEq(b.remainingInPeriod, 0);
        assertEq(b.maxPayment, 0);
        assertEq(b.periodEnd, T0 + L);
        (bool ok, uint8 reason) = c.canPay(id, api, 0.05e18, bytes32(uint256(4)));
        assertFalse(ok);
        assertEq(reason, 9);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.ExceedsPeriodCap.selector, 0.05e18, 0));
        c.pay(id, api, 0.05e18, bytes32(uint256(4)), "GET /v1/prices");
        // the next period: spending resets exactly at the boundary
        vm.warp(T0 + L);
        assertEq(c.budget(id).remainingInPeriod, 0.15e18);
        _pay(id, api, 0.05e18, bytes32(uint256(4)));
        assertEq(c.budget(id).spentInPeriod, 0.05e18);
        assertEq(c.getAllowance(id).periodIndex, 1);
        // owner revokes: the rest goes back
        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        c.revoke(id);
        assertEq(owner.balance - ownerBefore, 0.10e18);
        _conserved(id);
        assertEq(c.totalHeld(), 0);
        assertEq(address(c).balance, 0);
    }

    function test_pay_perPaymentCap() public {
        uint256 id = _create(1e18, 0);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.ExceedsPaymentCap.selector, PPC + 1, PPC));
        c.pay(id, api, PPC + 1, 0, "");
        _pay(id, api, PPC, 0); // exactly the cap is fine
        assertEq(c.getAllowance(id).totalPaid, PPC);
    }

    function test_pay_insufficientBalance() public {
        uint256 id = _create(0.04e18, 0);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.InsufficientBalance.selector, 0.05e18, 0.04e18));
        c.pay(id, api, 0.05e18, 0, "");
        assertEq(c.budget(id).remainingInPeriod, 0.04e18, "remaining is capped by the balance");
        _pay(id, api, 0.04e18, 0);
        assertEq(c.getAllowance(id).balance, 0);
    }

    function test_pay_onlySpender() public {
        uint256 id = _create(0.3e18, 0);
        address[3] memory others = [owner, stranger, api];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(others[i]);
            vm.expectRevert(UsdcAllowance.NotSpender.selector);
            c.pay(id, api, 1e16, 0, "");
        }
    }

    function test_pay_unknownId() public {
        _create(0.3e18, 0);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.UnknownAllowance.selector, 0));
        c.pay(0, api, 1, 0, "");
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.UnknownAllowance.selector, 2));
        c.pay(2, api, 1, 0, "");
    }

    function test_pay_payeeRules() public {
        uint256 id = _create(0.3e18, 0);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.PayeeNotAllowed.selector, api2));
        c.pay(id, api2, 1e16, 0, "");
        address[3] memory invalid = [address(0), address(c), agent];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(agent);
            vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.InvalidPayee.selector, invalid[i]));
            c.pay(id, invalid[i], 1e16, 0, "");
        }
        // the owner may be a payee if listed
        address[] memory o = _one(owner);
        vm.prank(owner);
        c.addPayees(id, o);
        _pay(id, owner, 1e16, 0);
    }

    function test_pay_openAllowanceAnyPayee() public {
        uint256 id = _createOpen(0.3e18);
        _pay(id, api, 1e16, 0);
        _pay(id, api2, 1e16, 0);
        _pay(id, stranger, 1e16, 0);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.InvalidPayee.selector, agent));
        c.pay(id, agent, 1e16, 0, "");
        assertEq(c.getAllowance(id).paymentCount, 3);
    }

    function test_pay_zeroAmountAndMemo() public {
        uint256 id = _create(0.3e18, 0);
        vm.prank(agent);
        vm.expectRevert(UsdcAllowance.ZeroAmount.selector);
        c.pay(id, api, 0, 0, "");
        bytes memory m140 = new bytes(140);
        bytes memory m141 = new bytes(141);
        vm.prank(agent);
        vm.expectRevert(UsdcAllowance.MemoTooLong.selector);
        c.pay(id, api, 1e16, 0, string(m141));
        vm.prank(agent);
        c.pay(id, api, 1e16, 0, string(m140));
    }

    function test_pay_refsAreIdempotentPerAllowance() public {
        uint256 id = _create(0.3e18, 0);
        uint256 id2 = _create(0.3e18, 0);
        bytes32 ref = keccak256("invoice-42");
        _pay(id, api, 1e16, ref);
        assertTrue(c.isRefUsed(id, ref));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.DuplicateRef.selector, ref));
        c.pay(id, api, 1e16, ref, "retry");
        _pay(id2, api, 1e16, ref); // another allowance: independent
        _pay(id, api, 1e16, 0); // zero ref: never deduplicated
        _pay(id, api, 1e16, 0);
        assertEq(c.getAllowance(id).paymentCount, 3);
        // a failed payment does not burn its ref
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.ExceedsPaymentCap.selector, PPC + 1, PPC));
        c.pay(id, api, PPC + 1, keccak256("invoice-43"), "");
        assertFalse(c.isRefUsed(id, keccak256("invoice-43")));
    }

    function test_pay_pausedAndUnpaused() public {
        uint256 id = _create(0.3e18, 600);
        vm.expectEmit(true, true, true, true, address(c));
        emit PausedSet(id, true);
        vm.prank(owner);
        c.pause(id);
        assertEq(c.status(id), 2);
        assertEq(c.budget(id).remainingInPeriod, 0);
        vm.prank(agent);
        vm.expectRevert(UsdcAllowance.AllowancePaused.selector);
        c.pay(id, api, 1e16, 0, "");
        vm.recordLogs();
        vm.prank(owner);
        c.pause(id); // idempotent, no event
        assertEq(vm.getRecordedLogs().length, 0);
        vm.prank(owner);
        c.unpause(id); // immediate even with a loosen delay
        assertEq(c.status(id), 1);
        _pay(id, api, 1e16, 0);
        vm.prank(stranger);
        vm.expectRevert(UsdcAllowance.NotOwner.selector);
        c.pause(id);
    }

    function test_pay_expiryBoundary() public {
        uint256 id = _create(0.3e18, 0);
        uint64 exp = c.getAllowance(id).expiresAt;
        vm.warp(exp - 1);
        _pay(id, api, 1e16, 0);
        vm.warp(exp);
        assertEq(c.status(id), 3);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.AllowanceExpired.selector, exp));
        c.pay(id, api, 1e16, 0, "");
        // the owner can still take the money back after expiry
        vm.prank(owner);
        c.revoke(id);
        assertEq(c.status(id), 4);
        _conserved(id);
    }

    function test_pay_checkOrder() public {
        uint256 id = _create(0.3e18, 0);
        vm.prank(owner);
        c.pause(id);
        // paused + payee not allowed + over the cap -> Paused (4) comes first
        (, uint8 r) = c.canPay(id, api2, 1e18, 0);
        assertEq(r, 4);
        vm.warp(block.timestamp + 31 days); // expired AND paused -> Expired (3)
        (, r) = c.canPay(id, api2, 1e18, 0);
        assertEq(r, 3);
        assertEq(c.status(id), 3);
        vm.prank(owner);
        c.revoke(id); // revoked beats everything
        (, r) = c.canPay(id, api2, 1e18, 0);
        assertEq(r, 2);
        (, r) = c.canPay(99, api, 1, 0);
        assertEq(r, 1);
        uint256 id2 = _create(0.01e18, 0);
        (, r) = c.canPay(id2, api, 0, 0);
        assertEq(r, 7);
        (, r) = c.canPay(id2, api, PPC + 1, 0); // over per-payment before over-balance
        assertEq(r, 8);
        (, r) = c.canPay(id2, api, PPC, 0); // within caps, over balance
        assertEq(r, 10);
    }

    // ------------------------------------------------------------------ periods
    function test_period_boundaryIsExact() public {
        uint256 id = _create(1e18, 0);
        vm.warp(T0 + L - 1);
        _pay(id, api, 0.10e18, 0);
        _pay(id, api, 0.05e18, 0);
        assertEq(c.budget(id).remainingInPeriod, 0);
        assertEq(c.budget(id).periodIndex, 0);
        vm.warp(T0 + L); // first second of period 1
        UsdcAllowance.Budget memory b = c.budget(id);
        assertEq(b.periodIndex, 1);
        assertEq(b.periodStart, T0 + L);
        assertEq(b.periodEnd, T0 + 2 * L);
        assertEq(b.spentInPeriod, 0);
        assertEq(b.remainingInPeriod, PC);
        // documented property of fixed windows: up to 2x periodCap within any periodLength across a boundary
        _pay(id, api, 0.10e18, 0);
        _pay(id, api, 0.05e18, 0);
        assertEq(c.getAllowance(id).totalPaid, 2 * uint256(PC));
    }

    function test_period_skipsIdlePeriods() public {
        uint256 id = _create(1e18, 0);
        _pay(id, api, 0.10e18, 0);
        _pay(id, api, 0.05e18, 0);
        vm.warp(T0 + 10 * L + 17);
        UsdcAllowance.Budget memory b = c.budget(id);
        assertEq(b.periodIndex, 10);
        assertEq(b.periodStart, T0 + 10 * L);
        assertEq(b.spentInPeriod, 0);
        _pay(id, api, 0.07e18, 0);
        assertEq(c.getAllowance(id).periodIndex, 10);
        assertEq(c.getAllowance(id).spentInPeriod, 0.07e18);
    }

    function test_period_pastAnchor() public {
        UsdcAllowance.Rules memory r = _rules(0, false);
        r.periodAnchor = uint64(T0 - 250); // created 250 s into a period: it resets 50 s later
        vm.prank(owner);
        uint256 id = c.createAllowance{value: 1e18}(agent, r, _none(), "");
        assertEq(c.budget(id).periodEnd, T0 + 50);
        _pay(id, api, 0.10e18, 0);
        _pay(id, api, 0.05e18, 0);
        vm.warp(T0 + 49);
        assertEq(c.budget(id).remainingInPeriod, 0);
        vm.warp(T0 + 50);
        _pay(id, api, 0.10e18, 0);
        _pay(id, api, 0.05e18, 0);
    }

    function testFuzz_period_indexMath(uint64 anchorBack, uint64 len, uint64 later) public {
        len = uint64(bound(len, 60, 365 days));
        anchorBack = uint64(bound(anchorBack, 0, T0));
        later = uint64(bound(later, 0, 20 * 365 days));
        UsdcAllowance.Rules memory r = _rules(0, false);
        r.periodLength = len;
        r.periodAnchor = uint64(T0) - anchorBack;
        r.expiresAt = uint64(T0 + 3650 days);
        vm.prank(owner);
        uint256 id = c.createAllowance(agent, r, _none(), "");
        vm.warp(T0 + later);
        UsdcAllowance.Budget memory b = c.budget(id);
        uint256 t = T0 + later;
        assertEq(b.periodIndex, (t - r.periodAnchor) / len);
        assertLe(b.periodStart, t);
        assertGt(b.periodEnd, t);
        assertEq(b.periodEnd - b.periodStart, len);
        assertEq((b.periodStart - r.periodAnchor) % len, 0);
    }

    function testFuzz_period_spendNeverExceedsCap(uint256 seed) public {
        uint256 id = _createOpen(5e18);
        uint256 curIdx = 0;
        uint256 spentHere = 0;
        for (uint256 i = 0; i < 40; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(block.timestamp + (seed % 200));
            uint256 amt = 1 + ((seed >> 16) % uint256(PPC));
            uint256 idx = (block.timestamp - T0) / L;
            if (idx != curIdx) {
                curIdx = idx;
                spentHere = 0;
            }
            (bool ok, uint8 r) = c.canPay(id, api, amt, 0);
            vm.prank(agent);
            try c.pay(id, api, amt, 0, "") {
                assertTrue(ok, "canPay agreed");
                spentHere += amt;
            } catch (bytes memory err) {
                assertFalse(ok);
                assertEq(r, 9, "only the period cap can stop these payments");
                assertEq(err, abi.encodeWithSelector(UsdcAllowance.ExceedsPeriodCap.selector, amt, uint256(PC) - spentHere));
            }
            assertLe(spentHere, PC, "spent in period <= cap");
            assertEq(c.budget(id).spentInPeriod, spentHere);
        }
        _conserved(id);
    }

    // ------------------------------------------------------------------ limits: tighten now, loosen later
    function test_setLimits_tightenIsImmediate() public {
        uint256 id = _create(1e18, 600);
        vm.expectEmit(true, true, true, true, address(c));
        emit LimitsChanged(id, 0.02e18, 0.05e18, uint64(T0 + 1 days));
        vm.prank(owner);
        c.setLimits(id, 0.02e18, 0.05e18, uint64(T0 + 1 days));
        (uint128 ppc, uint128 pc, uint64 exp) = c.effectiveLimits(id);
        assertEq(ppc, 0.02e18);
        assertEq(pc, 0.05e18);
        assertEq(exp, T0 + 1 days);
        assertEq(c.pendingLimits(id).activeAt, 0);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.ExceedsPaymentCap.selector, 0.03e18, 0.02e18));
        c.pay(id, api, 0.03e18, 0, "");
    }

    function test_setLimits_loosenWaitsForDelay() public {
        uint256 id = _create(1e18, 600);
        _pay(id, api, 0.10e18, 0);
        vm.expectEmit(true, true, true, true, address(c));
        emit LimitsChanged(id, PPC, PC, uint64(T0 + 30 days));
        vm.expectEmit(true, true, true, true, address(c));
        emit LimitsPending(id, 0.20e18, 0.40e18, uint64(T0 + 60 days), uint64(T0 + 600));
        vm.prank(owner);
        c.setLimits(id, 0.20e18, 0.40e18, uint64(T0 + 60 days));
        // before activeAt the old limits apply
        vm.warp(T0 + 599);
        (uint128 ppc, uint128 pc,) = c.effectiveLimits(id);
        assertEq(ppc, PPC);
        assertEq(pc, PC);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.ExceedsPaymentCap.selector, 0.15e18, PPC));
        c.pay(id, api, 0.15e18, 0, "");
        // from activeAt the new limits apply, without any further transaction
        vm.warp(T0 + 600); // also a new period (L = 300)
        (ppc, pc,) = c.effectiveLimits(id);
        assertEq(ppc, 0.20e18);
        assertEq(pc, 0.40e18);
        assertEq(c.budget(id).expiresAt, T0 + 60 days);
        _pay(id, api, 0.20e18, 0);
        _pay(id, api, 0.20e18, 0);
        assertEq(c.budget(id).remainingInPeriod, 0);
    }

    function test_setLimits_mixedTightensNowLoosensLater() public {
        uint256 id = _create(1e18, 600);
        vm.prank(owner);
        c.setLimits(id, 0.05e18, 0.40e18, uint64(T0 + 30 days)); // ppc down (now), pc up (later)
        (uint128 ppc, uint128 pc,) = c.effectiveLimits(id);
        assertEq(ppc, 0.05e18, "tightened part applies now");
        assertEq(pc, PC, "loosened part waits");
        UsdcAllowance.PendingLimits memory p = c.pendingLimits(id);
        assertEq(p.perPaymentCap, 0.05e18);
        assertEq(p.periodCap, 0.40e18);
        assertEq(p.activeAt, T0 + 600);
        vm.warp(T0 + 600);
        (ppc, pc,) = c.effectiveLimits(id);
        assertEq(ppc, 0.05e18);
        assertEq(pc, 0.40e18);
    }

    function test_setLimits_currentValuesCancelPending() public {
        uint256 id = _create(1e18, 600);
        vm.prank(owner);
        c.setLimits(id, PPC, 0.40e18, uint64(T0 + 30 days));
        assertEq(c.pendingLimits(id).activeAt, T0 + 600);
        vm.expectEmit(true, true, true, true, address(c));
        emit PendingCleared(id);
        vm.prank(owner);
        c.setLimits(id, PPC, PC, uint64(T0 + 30 days));
        assertEq(c.pendingLimits(id).activeAt, 0);
        vm.warp(T0 + 10_000);
        (, uint128 pc,) = c.effectiveLimits(id);
        assertEq(pc, PC);
    }

    function test_setLimits_newCallRestartsDelay() public {
        uint256 id = _create(1e18, 600);
        vm.prank(owner);
        c.setLimits(id, PPC, 0.40e18, uint64(T0 + 30 days));
        vm.warp(T0 + 500);
        vm.prank(owner);
        c.setLimits(id, PPC, 0.50e18, uint64(T0 + 30 days)); // replaces the pending change, new clock
        assertEq(c.pendingLimits(id).activeAt, T0 + 1100);
        vm.warp(T0 + 600);
        (, uint128 pc,) = c.effectiveLimits(id);
        assertEq(pc, PC, "the replaced change never applies");
        vm.warp(T0 + 1100);
        (, pc,) = c.effectiveLimits(id);
        assertEq(pc, 0.50e18);
    }

    function test_setLimits_maturedPendingIsFolded() public {
        uint256 id = _create(1e18, 600);
        vm.prank(owner);
        c.setLimits(id, PPC, 0.40e18, uint64(T0 + 30 days));
        vm.warp(T0 + 700);
        vm.prank(owner);
        c.setLimits(id, PPC, 0.30e18, uint64(T0 + 30 days)); // 0.40 is in force, 0.30 is a tightening -> now
        UsdcAllowance.Allowance memory a = c.getAllowance(id);
        assertEq(a.periodCap, 0.30e18);
        assertEq(c.pendingLimits(id).activeAt, 0);
        (, uint128 pc,) = c.effectiveLimits(id);
        assertEq(pc, 0.30e18);
    }

    function test_setLimits_zeroDelayIsImmediate() public {
        uint256 id = _create(1e18, 0);
        vm.prank(owner);
        c.setLimits(id, 0.5e18, 0.9e18, uint64(T0 + 90 days));
        (uint128 ppc, uint128 pc, uint64 exp) = c.effectiveLimits(id);
        assertEq(ppc, 0.5e18);
        assertEq(pc, 0.9e18);
        assertEq(exp, T0 + 90 days);
        _pay(id, api, 0.5e18, 0);
    }

    function test_setLimits_extendExpiredAllowance() public {
        uint256 id = _create(1e18, 120);
        vm.warp(T0 + 30 days + 1);
        assertEq(c.status(id), 3);
        vm.prank(owner);
        c.setLimits(id, PPC, PC, uint64(block.timestamp + 7 days));
        assertEq(c.status(id), 3, "an extension is a loosening: still expired during the delay");
        vm.warp(block.timestamp + 120);
        assertEq(c.status(id), 1);
        _pay(id, api, 1e16, 0);
    }

    function test_setLimits_tightenBelowSpent() public {
        uint256 id = _create(1e18, 0);
        _pay(id, api, 0.10e18, 0);
        vm.prank(owner);
        c.setLimits(id, 0.05e18, 0.06e18, uint64(T0 + 1 days));
        UsdcAllowance.Budget memory b = c.budget(id);
        assertEq(b.spentInPeriod, 0.10e18);
        assertEq(b.remainingInPeriod, 0, "no underflow when spent > new cap");
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.ExceedsPeriodCap.selector, 1, 0));
        c.pay(id, api, 1, 0, "");
    }

    function test_setLimits_reverts() public {
        uint256 id = _create(1e18, 0);
        vm.prank(stranger);
        vm.expectRevert(UsdcAllowance.NotOwner.selector);
        c.setLimits(id, PPC, PC, uint64(T0 + 1 days));
        vm.startPrank(owner);
        vm.expectRevert(UsdcAllowance.InvalidRules.selector);
        c.setLimits(id, 0, PC, uint64(T0 + 1 days));
        vm.expectRevert(UsdcAllowance.InvalidRules.selector);
        c.setLimits(id, PC + 1, PC, uint64(T0 + 1 days));
        vm.expectRevert(UsdcAllowance.InvalidRules.selector);
        c.setLimits(id, PPC, PC, uint64(T0));
        vm.expectRevert(UsdcAllowance.InvalidRules.selector);
        c.setLimits(id, PPC, PC, uint64(T0 + 3650 days + 1));
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.UnknownAllowance.selector, 7));
        c.setLimits(7, PPC, PC, uint64(T0 + 1 days));
        c.revoke(id);
        vm.expectRevert(UsdcAllowance.AllowanceRevoked.selector);
        c.setLimits(id, PPC, PC, uint64(T0 + 1 days));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ payees
    function test_addPayees_waitForDelay() public {
        uint256 id = _create(1e18, 120);
        vm.expectEmit(true, true, true, true, address(c));
        emit PayeeAdded(id, api2, uint64(T0 + 120));
        vm.prank(owner);
        c.addPayees(id, _one(api2));
        assertEq(c.payeeActiveAt(id, api2), T0 + 120);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.PayeeNotAllowed.selector, api2));
        c.pay(id, api2, 1e16, 0, "");
        vm.warp(T0 + 120);
        _pay(id, api2, 1e16, 0);
    }

    function test_addPayees_existingUnchangedAndLimits() public {
        uint256 id = _create(1e18, 120);
        vm.recordLogs();
        vm.prank(owner);
        c.addPayees(id, _one(api)); // already active: no change, no event
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(c.payeeActiveAt(id, api), T0);
        address[] memory p = new address[](19);
        for (uint256 i = 0; i < 19; i++) p[i] = address(uint160(0x2000 + i));
        vm.prank(owner);
        c.addPayees(id, p); // 20 listed now
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.TooManyPayees.selector);
        c.addPayees(id, _one(api2));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.InvalidPayee.selector, agent));
        c.addPayees(id, _one(agent));
        address[] memory tooMany = new address[](21);
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.TooManyPayees.selector);
        c.addPayees(id, tooMany);
        uint256 open = _createOpen(1e18);
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.AllowlistDisabled.selector);
        c.addPayees(open, _one(api2));
    }

    function test_removePayees_immediateSwapAndPop() public {
        address[] memory three = new address[](3);
        three[0] = api;
        three[1] = api2;
        three[2] = stranger;
        vm.prank(owner);
        uint256 id = c.createAllowance{value: 1e18}(agent, _rules(600, true), three, "");
        vm.expectEmit(true, true, true, true, address(c));
        emit PayeeRemoved(id, api);
        vm.prank(owner);
        c.removePayees(id, _one(api));
        (address[] memory ps,) = c.getPayees(id);
        assertEq(ps.length, 2);
        assertEq(ps[0], stranger, "last moved into the hole");
        assertEq(ps[1], api2);
        assertEq(c.payeeActiveAt(id, api), 0);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.PayeeNotAllowed.selector, api));
        c.pay(id, api, 1e16, 0, "");
        // removing an unlisted address is ignored; removing the rest works in any order
        address[] memory rest = new address[](3);
        rest[0] = api;
        rest[1] = api2;
        rest[2] = stranger;
        vm.prank(owner);
        c.removePayees(id, rest);
        (ps,) = c.getPayees(id);
        assertEq(ps.length, 0);
        // re-adding starts a new delay
        vm.prank(owner);
        c.addPayees(id, _one(api));
        assertEq(c.payeeActiveAt(id, api), T0 + 600);
    }

    function test_pendingPayeeRemovedBeforeActive() public {
        uint256 id = _create(1e18, 120);
        vm.prank(owner);
        c.addPayees(id, _one(api2));
        vm.prank(owner);
        c.removePayees(id, _one(api2));
        vm.warp(T0 + 500);
        (bool ok, uint8 r) = c.canPay(id, api2, 1e16, 0);
        assertFalse(ok);
        assertEq(r, 6);
    }

    // ------------------------------------------------------------------ withdraw / revoke
    function test_withdraw_partial() public {
        uint256 id = _create(0.30e18, 0);
        uint256 before = owner.balance;
        vm.expectEmit(true, true, true, true, address(c));
        emit Withdrawn(id, owner, 0.12e18, 0.18e18);
        vm.prank(owner);
        c.withdraw(id, 0.12e18);
        assertEq(owner.balance - before, 0.12e18);
        assertEq(c.getAllowance(id).balance, 0.18e18);
        assertEq(c.getAllowance(id).totalRefunded, 0.12e18);
        _pay(id, api, 0.05e18, 0); // still usable
        _conserved(id);
        assertEq(c.totalHeld(), 0.13e18);
    }

    function test_withdraw_reverts() public {
        uint256 id = _create(0.30e18, 0);
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.ZeroAmount.selector);
        c.withdraw(id, 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.InsufficientBalance.selector, 0.31e18, 0.30e18));
        c.withdraw(id, 0.31e18);
        vm.prank(agent);
        vm.expectRevert(UsdcAllowance.NotOwner.selector);
        c.withdraw(id, 1);
    }

    function test_revoke_isFinal() public {
        uint256 id = _create(0.30e18, 600);
        _pay(id, api, 0.05e18, 0);
        vm.prank(owner);
        c.setLimits(id, PPC, 0.30e18, uint64(T0 + 30 days)); // a pending loosening
        uint256 before = owner.balance;
        vm.expectEmit(true, true, true, true, address(c));
        emit Revoked(id, owner, 0.25e18);
        vm.prank(owner);
        c.revoke(id);
        assertEq(owner.balance - before, 0.25e18);
        assertEq(c.status(id), 4);
        assertEq(c.pendingLimits(id).activeAt, 0, "pending dropped");
        UsdcAllowance.Allowance memory a = c.getAllowance(id);
        assertTrue(a.revoked);
        assertEq(a.balance, 0);
        assertEq(a.totalRefunded, 0.25e18);
        _conserved(id);
        UsdcAllowance.Budget memory b = c.budget(id);
        assertEq(b.status, 4);
        assertEq(b.remainingInPeriod, 0);
        vm.prank(agent);
        vm.expectRevert(UsdcAllowance.AllowanceRevoked.selector);
        c.pay(id, api, 1, 0, "");
        vm.startPrank(owner);
        vm.expectRevert(UsdcAllowance.AllowanceRevoked.selector);
        c.revoke(id);
        vm.expectRevert(UsdcAllowance.AllowanceRevoked.selector);
        c.withdraw(id, 1);
        vm.expectRevert(UsdcAllowance.AllowanceRevoked.selector);
        c.unpause(id);
        vm.expectRevert(UsdcAllowance.AllowanceRevoked.selector);
        c.addPayees(id, _one(api2));
        vm.expectRevert(UsdcAllowance.AllowanceRevoked.selector);
        c.removePayees(id, _one(api));
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(UsdcAllowance.NotOwner.selector);
        c.revoke(id);
    }

    function test_revoke_emptyAllowance() public {
        vm.prank(owner);
        uint256 id = c.createAllowance(agent, _rules(0, true), _one(api), "");
        uint256 before = owner.balance;
        vm.prank(owner);
        c.revoke(id);
        assertEq(owner.balance, before);
        assertEq(c.status(id), 4);
    }

    // ------------------------------------------------------------------ transfers and reentrancy
    function test_pay_rejectingPayeeLeavesStateUnchanged() public {
        RejectingReceiver bad = new RejectingReceiver();
        uint256 id = _createOpen(0.30e18);
        bytes32 ref = keccak256("r1");
        vm.prank(agent);
        vm.expectRevert(UsdcAllowance.TransferFailed.selector);
        c.pay(id, address(bad), 0.05e18, ref, "");
        UsdcAllowance.Allowance memory a = c.getAllowance(id);
        assertEq(a.balance, 0.30e18);
        assertEq(a.spentInPeriod, 0);
        assertEq(a.paymentCount, 0);
        assertFalse(c.isRefUsed(id, ref));
        _pay(id, api, 0.05e18, ref); // the ref is still usable
    }

    function test_revoke_rejectingOwner() public {
        RejectingReceiver bad = new RejectingReceiver();
        vm.deal(address(bad), 1e18);
        vm.prank(address(bad));
        uint256 id = c.createAllowance{value: 0.2e18}(agent, _rules(0, true), _one(api), "");
        vm.prank(address(bad));
        vm.expectRevert(UsdcAllowance.TransferFailed.selector);
        c.revoke(id);
        assertFalse(c.getAllowance(id).revoked);
        _pay(id, api, 0.05e18, 0); // the spender is unaffected
    }

    function test_reentrancy_ownerRevokeDuringPayment() public {
        ReentrantOwner ro = new ReentrantOwner(c);
        vm.deal(address(ro), 1e18);
        address[] memory payees = _one(address(ro));
        vm.prank(address(ro));
        uint256 id = ro.create{value: 0.3e18}(agent, _rules(0, true), payees);
        // bubbling: the inner revoke hits the guard, the payment reverts as a whole
        ro.setBubble(true);
        vm.prank(agent);
        vm.expectRevert(UsdcAllowance.TransferFailed.selector);
        c.pay(id, address(ro), 0.05e18, 0, "");
        assertEq(c.getAllowance(id).balance, 0.3e18);
        // swallowing: the payment completes, the revoke did not happen
        ro.setBubble(false);
        _pay(id, address(ro), 0.05e18, 0);
        assertTrue(ro.innerFailed());
        assertFalse(c.getAllowance(id).revoked);
        assertEq(c.getAllowance(id).balance, 0.25e18);
        _conserved(id);
        assertEq(address(c).balance, c.totalHeld());
    }

    function test_reentrancy_payeeTriggersSecondPayment() public {
        SpenderAccount acct = new SpenderAccount(c);
        GreedyPayee greedy = new GreedyPayee();
        vm.prank(owner);
        uint256 id = c.createAllowance{value: 0.3e18}(address(acct), _rules(0, false), _none(), "smart account");
        greedy.setAccount(acct, false);
        vm.expectRevert(UsdcAllowance.TransferFailed.selector);
        acct.pay(id, address(greedy), 0.05e18, 0);
        assertEq(c.getAllowance(id).totalPaid, 0);
        greedy.setAccount(acct, true);
        acct.pay(id, address(greedy), 0.05e18, 0);
        assertTrue(greedy.innerFailed(), "the second payment hit the reentrancy guard");
        assertEq(greedy.received(), 0.05e18);
        assertEq(c.getAllowance(id).paymentCount, 1);
    }

    function test_spenderCanBeAContract() public {
        SpenderAccount acct = new SpenderAccount(c);
        vm.prank(owner);
        uint256 id = c.createAllowance{value: 0.3e18}(address(acct), _rules(0, false), _none(), "");
        // a direct reentrant call outside a payment is fine (guard only blocks nesting)
        acct.pay(id, api, 0.01e18, 0);
        assertEq(c.getAllowance(id).paymentCount, 1);
        assertEq(ReentrancyGuard.ReentrancyGuardReentrantCall.selector, bytes4(keccak256("ReentrancyGuardReentrantCall()")));
    }

    // ------------------------------------------------------------------ views
    function test_views_unknownIdsNeverRevert() public view {
        UsdcAllowance.Allowance memory a = c.getAllowance(0);
        assertEq(a.owner, address(0));
        assertEq(c.status(0), 0);
        assertEq(c.status(5), 0);
        UsdcAllowance.Budget memory b = c.budget(5);
        assertEq(b.status, 0);
        assertEq(b.periodEnd, 0);
        (bool ok, uint8 r) = c.canPay(5, api, 1, 0);
        assertFalse(ok);
        assertEq(r, 1);
        (uint128 ppc, uint128 pc, uint64 exp) = c.effectiveLimits(5);
        assertEq(ppc + pc + exp, 0);
        (address[] memory ps, uint64[] memory at) = c.getPayees(5);
        assertEq(ps.length + at.length, 0);
        assertEq(c.labelOf(5), "");
        assertEq(c.idsByOwner(owner).length, 0);
    }

    function test_budget_view() public {
        uint256 id = _create(0.12e18, 0);
        UsdcAllowance.Budget memory b = c.budget(id);
        assertEq(b.status, 1);
        assertEq(b.balance, 0.12e18);
        assertEq(b.remainingInPeriod, 0.12e18, "min(cap left 0.15, balance 0.12)");
        assertEq(b.maxPayment, PPC, "min(remaining, perPaymentCap)");
        _pay(id, api, 0.08e18, 0);
        b = c.budget(id);
        assertEq(b.spentInPeriod, 0.08e18);
        assertEq(b.remainingInPeriod, 0.04e18);
        assertEq(b.maxPayment, 0.04e18);
    }

    function testFuzz_canPayMatchesPay(uint256 amount, uint8 payeeSel, bytes32 ref, uint16 dt, bool pauseIt) public {
        uint256 id = _create(0.30e18, 0);
        _pay(id, api, 0.05e18, keccak256("used"));
        vm.warp(block.timestamp + dt);
        if (pauseIt) {
            vm.prank(owner);
            c.pause(id);
        }
        amount = bound(amount, 0, 0.4e18);
        address[4] memory ps = [api, api2, address(0), agent];
        address payee = ps[payeeSel % 4];
        if (uint256(ref) % 3 == 0) ref = keccak256("used");
        (bool ok, uint8 r) = c.canPay(id, payee, amount, ref);
        vm.prank(agent);
        try c.pay(id, payee, amount, ref, "fuzz") {
            assertTrue(ok, "pay succeeded so canPay must say OK");
        } catch {
            assertFalse(ok, "pay failed so canPay must say why");
            assertGt(r, 0);
        }
    }

    function testFuzz_conservation(uint256 seed) public {
        uint256 id = _create(1e18, 0);
        for (uint256 i = 0; i < 25; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = seed % 5;
            uint256 amt = 1 + ((seed >> 8) % 0.12e18);
            if (op == 0) {
                vm.prank(owner);
                c.fund{value: amt}(id);
            } else if (op == 1) {
                vm.prank(agent);
                try c.pay(id, api, amt, 0, "") {} catch {}
            } else if (op == 2) {
                vm.prank(owner);
                try c.withdraw(id, amt) {} catch {}
            } else {
                vm.warp(block.timestamp + (seed >> 40) % 400);
            }
            _conserved(id);
            assertEq(address(c).balance, c.totalHeld());
            assertEq(c.totalHeld(), c.getAllowance(id).balance);
        }
    }
}
