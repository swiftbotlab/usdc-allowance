// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {UsdcAllowance} from "../UsdcAllowance.sol";

/// @notice setLimits tests: tighten/loosen/mixed, loosenDelay, pending folding,
///         replaced pending restarts clock, extending expired stays expired, no underflow.
contract UsdcAllowanceLimitsTest is Test {
    UsdcAllowance internal vault;

    address internal owner   = address(0xA001);
    address internal spender = address(0xA002);
    address internal payee   = address(0xA003);

    uint128 internal PER_CAP   = 1 ether;
    uint128 internal PERIOD_CAP = 10 ether;
    uint64  internal PERIOD    = 1 days;
    uint32  internal DELAY     = 1 hours;
    uint64  internal EXPIRY;
    uint256 internal refNonce;

    function setUp() public {
        vault = new UsdcAllowance();
        vm.deal(owner,  200 ether);
        vm.deal(spender, 10 ether);
        EXPIRY = uint64(block.timestamp + 60 days);
    }

    /* ─── helpers ─── */

    function _createWithDelay(uint32 delay) internal returns (uint256 id) {
        UsdcAllowance.Rules memory r = UsdcAllowance.Rules({
            perPaymentCap: PER_CAP,
            periodCap:     PERIOD_CAP,
            periodLength:  PERIOD,
            periodAnchor:  0,
            expiresAt:     EXPIRY,
            loosenDelay:   delay,
            useAllowlist:  false
        });
        vm.prank(owner);
        id = vault.createAllowance{value: 20 ether}(spender, r, new address[](0), "");
    }

    function _pay(uint256 id, uint256 amt) internal {
        vm.prank(spender);
        vault.pay(id, payee, amt, bytes32(++refNonce), "");
    }

    /* ─── tighten only (delay=0) → immediate, no pending ─── */

    function test_setLimits_tighten_immediate_no_delay() public {
        uint256 id = _createWithDelay(0);
        vm.prank(owner);
        vault.setLimits(id, 0.5 ether, 5 ether, EXPIRY);
        (uint128 pp, uint128 pc, uint64 ex) = vault.effectiveLimits(id);
        assertEq(pp, 0.5 ether);
        assertEq(pc, 5 ether);
        assertEq(ex, EXPIRY);
        assertEq(vault.pendingLimits(id).activeAt, 0);
    }

    /* ─── tighten only (delay>0) → still immediate ─── */

    function test_setLimits_tighten_with_delay_still_immediate() public {
        uint256 id = _createWithDelay(DELAY);
        vm.prank(owner);
        vault.setLimits(id, 0.5 ether, 5 ether, EXPIRY);
        (uint128 pp, uint128 pc,) = vault.effectiveLimits(id);
        assertEq(pp, 0.5 ether);
        assertEq(pc, 5 ether);
        // No pending because nothing was looser
        assertEq(vault.pendingLimits(id).activeAt, 0);
    }

    /* ─── loosen only → creates pending ─── */

    function test_setLimits_loosen_creates_pending() public {
        uint256 id = _createWithDelay(DELAY);
        uint128 newPer = PER_CAP + 1 ether;
        uint128 newPc  = PERIOD_CAP + 5 ether;
        vm.prank(owner);
        vault.setLimits(id, newPer, newPc, EXPIRY);

        // Stored values unchanged (nothing tighter)
        (uint128 pp, uint128 pc,) = vault.effectiveLimits(id);
        assertEq(pp, PER_CAP);    // not yet applied
        assertEq(pc, PERIOD_CAP);

        UsdcAllowance.PendingLimits memory p = vault.pendingLimits(id);
        assertEq(p.perPaymentCap, newPer);
        assertEq(p.periodCap,     newPc);
        assertEq(p.expiresAt,     EXPIRY);
        assertGt(p.activeAt,      block.timestamp);
    }

    /* ─── loosen matures → applies without tx ─── */

    function test_setLimits_loosen_matures_in_view() public {
        uint256 id = _createWithDelay(DELAY);
        uint128 newPer = PER_CAP + 1 ether;
        vm.prank(owner);
        vault.setLimits(id, newPer, PERIOD_CAP, EXPIRY);

        // before maturity — still old value
        (uint128 pp,,) = vault.effectiveLimits(id);
        assertEq(pp, PER_CAP);

        // warp past delay
        vm.warp(block.timestamp + DELAY + 1);
        (pp,,) = vault.effectiveLimits(id);
        assertEq(pp, newPer);

        // canPay should also use the new cap
        (bool ok,) = vault.canPay(id, payee, newPer, bytes32(0));
        assertTrue(ok);
    }

    /* ─── mixed: some tighter, some looser ─── */

    function test_setLimits_mixed_change() public {
        uint256 id = _createWithDelay(DELAY);
        // tighten periodCap, loosen perPaymentCap
        uint128 newPer = PER_CAP * 2; // looser
        uint128 newPc  = PERIOD_CAP / 2; // tighter
        vm.prank(owner);
        vault.setLimits(id, newPer, newPc, EXPIRY);

        // periodCap tightened immediately
        (uint128 pp, uint128 pc,) = vault.effectiveLimits(id);
        assertEq(pc, newPc);        // tighter applied now
        assertEq(pp, PER_CAP);      // looser not yet applied

        // pending stores BOTH
        UsdcAllowance.PendingLimits memory p = vault.pendingLimits(id);
        assertEq(p.perPaymentCap, newPer);
        assertEq(p.periodCap, newPc);
    }

    /* ─── replacing pending restarts the clock ─── */

    function test_setLimits_replace_pending_restarts_clock() public {
        uint256 id = _createWithDelay(DELAY);
        uint128 firstPer = PER_CAP + 1 ether;
        vm.prank(owner);
        vault.setLimits(id, firstPer, PERIOD_CAP, EXPIRY);

        uint64 firstActiveAt = vault.pendingLimits(id).activeAt;

        // warp halfway through the delay, then replace
        vm.warp(block.timestamp + DELAY / 2);
        uint128 secondPer = PER_CAP + 2 ether;
        vm.prank(owner);
        vault.setLimits(id, secondPer, PERIOD_CAP, EXPIRY);

        uint64 secondActiveAt = vault.pendingLimits(id).activeAt;
        // new activeAt must be in the future, after first
        assertGt(secondActiveAt, firstActiveAt);

        // still not matured
        (uint128 pp,,) = vault.effectiveLimits(id);
        assertEq(pp, PER_CAP);

        // warp to new maturity
        vm.warp(secondActiveAt + 1);
        (pp,,) = vault.effectiveLimits(id);
        assertEq(pp, secondPer);
    }

    /* ─── pending cleared when all-tighter call happens ─── */

    function test_setLimits_pending_cleared_by_tighter_call() public {
        uint256 id = _createWithDelay(DELAY);
        // create a pending loosen
        vm.prank(owner);
        vault.setLimits(id, PER_CAP + 1 ether, PERIOD_CAP, EXPIRY);

        // now tighten everything
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit UsdcAllowance.PendingCleared(id);
        vault.setLimits(id, 0.5 ether, 5 ether, EXPIRY);

        assertEq(vault.pendingLimits(id).activeAt, 0);
    }

    /* ─── matured pending folded into storage on next setLimits ─── */

    function test_setLimits_folds_matured_pending() public {
        uint256 id = _createWithDelay(DELAY);
        uint128 looserPer = PER_CAP + 1 ether;
        vm.prank(owner);
        vault.setLimits(id, looserPer, PERIOD_CAP, EXPIRY);

        // Let it mature
        vm.warp(block.timestamp + DELAY + 1);

        // Another call folds the pending into storage first, then processes new limits
        uint128 tighterPer = 0.5 ether;
        vm.prank(owner);
        vault.setLimits(id, tighterPer, PERIOD_CAP, EXPIRY);

        // pending should be cleared, stored perPaymentCap is tighterPer
        assertEq(vault.pendingLimits(id).activeAt, 0);
        (uint128 pp,,) = vault.effectiveLimits(id);
        assertEq(pp, tighterPer);
    }

    /* ─── tighten below already-spent (no underflow in period cap) ─── */

    function test_setLimits_tighten_below_spent_no_underflow() public {
        uint256 id = _createWithDelay(0);
        // spend 5 ether in current period
        for (uint256 i = 0; i < 5; i++) {
            _pay(id, 1 ether);
        }
        assertEq(vault.getAllowance(id).spentInPeriod, 5 ether);

        // tighten period cap to 3 ether (less than spent)
        vm.prank(owner);
        vault.setLimits(id, 0.5 ether, 3 ether, EXPIRY);

        // canPay should return ExceedsPeriodCap with remaining=0 (no underflow)
        (bool ok, uint8 reason) = vault.canPay(id, payee, 0.5 ether, bytes32(0));
        assertFalse(ok);
        assertEq(reason, 9); // ExceedsPeriodCap

        // Next period should be fine again
        vm.warp(block.timestamp + PERIOD);
        (ok,) = vault.canPay(id, payee, 0.5 ether, bytes32(0));
        assertTrue(ok);
    }

    /* ─── extending expired allowance stays expired during delay ─── */

    function test_setLimits_extending_expired_stays_expired_during_delay() public {
        uint64 shortExpiry = uint64(block.timestamp + 100);
        UsdcAllowance.Rules memory r = UsdcAllowance.Rules({
            perPaymentCap: PER_CAP,
            periodCap:     PERIOD_CAP,
            periodLength:  PERIOD,
            periodAnchor:  0,
            expiresAt:     shortExpiry,
            loosenDelay:   DELAY,
            useAllowlist:  false
        });
        vm.prank(owner);
        uint256 id = vault.createAllowance{value: 10 ether}(spender, r, new address[](0), "");

        // warp past expiry
        vm.warp(shortExpiry + 1);
        assertEq(vault.status(id), 3); // Expired

        // Extend expiry (loosening)
        uint64 newExpiry = uint64(block.timestamp + 60 days);
        vm.prank(owner);
        vault.setLimits(id, PER_CAP, PERIOD_CAP, newExpiry);

        // Pending exists but allowance is still expired now
        assertEq(vault.status(id), 3);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.AllowanceExpired.selector, shortExpiry));
        vault.pay(id, payee, 1 ether, bytes32(0), "");

        // After delay, pending applies and allowance should be active
        vm.warp(block.timestamp + DELAY + 1);
        assertEq(vault.status(id), 1); // Active
        vm.prank(spender);
        vault.pay(id, payee, 1 ether, bytes32(0), "after-extension");
    }

    /* ─── loosenDelay=0 always immediate even for loosen ─── */

    function test_setLimits_zero_loosen_delay_always_immediate() public {
        uint256 id = _createWithDelay(0);
        uint128 newPer = PER_CAP * 10;
        vm.prank(owner);
        vault.setLimits(id, newPer, PERIOD_CAP * 10, EXPIRY);
        (uint128 pp,,) = vault.effectiveLimits(id);
        assertEq(pp, newPer);
        assertEq(vault.pendingLimits(id).activeAt, 0);
    }

    /* ─── InvalidRules checks ─── */

    function test_setLimits_revert_invalid_rules() public {
        uint256 id = _createWithDelay(0);
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.InvalidRules.selector);
        vault.setLimits(id, 0, PERIOD_CAP, EXPIRY); // perPaymentCap=0

        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.InvalidRules.selector);
        vault.setLimits(id, PER_CAP + 1, PER_CAP, EXPIRY); // per > period

        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.InvalidRules.selector);
        vault.setLimits(id, PER_CAP, PERIOD_CAP, uint64(block.timestamp)); // expiresAt <= now
    }

    /* ─── events emitted correctly ─── */

    function test_setLimits_events_tighten() public {
        uint256 id = _createWithDelay(0);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit UsdcAllowance.LimitsChanged(id, 0.5 ether, 5 ether, EXPIRY);
        vault.setLimits(id, 0.5 ether, 5 ether, EXPIRY);
    }

    function test_setLimits_events_loosen() public {
        uint256 id = _createWithDelay(DELAY);
        uint128 newPer = PER_CAP + 1 ether;
        vm.prank(owner);
        vault.setLimits(id, newPer, PERIOD_CAP, EXPIRY);

        UsdcAllowance.PendingLimits memory p = vault.pendingLimits(id);
        assertEq(p.perPaymentCap, newPer);
        assertGt(p.activeAt, 0);
    }
}
