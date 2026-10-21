// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {UsdcAllowance} from "../UsdcAllowance.sol";
import {RejectingPayee, ReentrantPayee, SpenderSmartAccount, ReentrantOwner} from "../test-helpers/AllowanceHelpers.sol";

/// @notice Core unit tests: createAllowance, fund, pay (error ordering), views on unknown ids,
///         withdraw, revoke, pause/unpause, TransferFailed, reentrancy.
contract UsdcAllowanceTest is Test {
    UsdcAllowance internal vault;

    address internal owner  = address(0xA001);
    address internal spender = address(0xA002);
    address internal payee  = address(0xA003);
    address internal other  = address(0xA004);

    uint64  internal EXPIRY;
    uint64  internal PERIOD  = 1 days;
    uint128 internal CAP     = 10 ether;
    uint128 internal PER_CAP = 1 ether;

    function setUp() public {
        vault = new UsdcAllowance();
        vm.deal(owner,  100 ether);
        vm.deal(spender, 10 ether);
        vm.deal(other,   10 ether);
        EXPIRY = uint64(block.timestamp + 30 days);
    }

    /* ─────────────────────────  helpers ───────────────────────── */

    function _rules() internal view returns (UsdcAllowance.Rules memory) {
        return UsdcAllowance.Rules({
            perPaymentCap: PER_CAP,
            periodCap:     CAP,
            periodLength:  PERIOD,
            periodAnchor:  0,
            expiresAt:     EXPIRY,
            loosenDelay:   0,
            useAllowlist:  false
        });
    }

    function _create() internal returns (uint256 id) {
        vm.prank(owner);
        id = vault.createAllowance{value: 5 ether}(spender, _rules(), new address[](0), "test");
    }

    /* ─────────────────────── createAllowance ─────────────────── */

    function test_create_basic() public {
        uint256 id = _create();
        assertEq(id, 1);
        assertEq(vault.allowanceCount(), 1);

        UsdcAllowance.Allowance memory a = vault.getAllowance(id);
        assertEq(a.owner,        owner);
        assertEq(a.spender,      spender);
        assertEq(a.balance,      5 ether);
        assertEq(a.totalFunded,  5 ether);
        assertEq(a.perPaymentCap, PER_CAP);
        assertEq(a.periodCap,    CAP);
        assertEq(a.revoked,      false);
        assertEq(a.paused,       false);
    }

    function test_create_zero_value_allowed() public {
        vm.prank(owner);
        uint256 id = vault.createAllowance(spender, _rules(), new address[](0), "");
        UsdcAllowance.Allowance memory a = vault.getAllowance(id);
        assertEq(a.balance, 0);
    }

    function test_create_revert_zero_spender() public {
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.ZeroAddress.selector);
        vault.createAllowance(address(0), _rules(), new address[](0), "");
    }

    function test_create_revert_self_spender() public {
        UsdcAllowance.Rules memory r = _rules();
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.InvalidRules.selector);
        vault.createAllowance(address(vault), r, new address[](0), "");
    }

    function test_create_revert_zero_perPaymentCap() public {
        UsdcAllowance.Rules memory r = _rules();
        r.perPaymentCap = 0;
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.InvalidRules.selector);
        vault.createAllowance(spender, r, new address[](0), "");
    }

    function test_create_revert_perCap_gt_periodCap() public {
        UsdcAllowance.Rules memory r = _rules();
        r.perPaymentCap = CAP + 1;
        r.periodCap     = CAP;
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.InvalidRules.selector);
        vault.createAllowance(spender, r, new address[](0), "");
    }

    function test_create_revert_expired_expiry() public {
        UsdcAllowance.Rules memory r = _rules();
        r.expiresAt = uint64(block.timestamp);
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.InvalidRules.selector);
        vault.createAllowance(spender, r, new address[](0), "");
    }

    function test_create_revert_too_long_duration() public {
        UsdcAllowance.Rules memory r = _rules();
        r.expiresAt = uint64(block.timestamp + 3650 days + 1);
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.InvalidRules.selector);
        vault.createAllowance(spender, r, new address[](0), "");
    }

    function test_create_revert_period_too_short() public {
        UsdcAllowance.Rules memory r = _rules();
        r.periodLength = 59;
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.InvalidRules.selector);
        vault.createAllowance(spender, r, new address[](0), "");
    }

    function test_create_revert_period_too_long() public {
        UsdcAllowance.Rules memory r = _rules();
        r.periodLength = uint64(365 days + 1);
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.InvalidRules.selector);
        vault.createAllowance(spender, r, new address[](0), "");
    }

    function test_create_revert_future_anchor() public {
        UsdcAllowance.Rules memory r = _rules();
        r.periodAnchor = uint64(block.timestamp + 1);
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.InvalidRules.selector);
        vault.createAllowance(spender, r, new address[](0), "");
    }

    function test_create_revert_payees_without_allowlist() public {
        UsdcAllowance.Rules memory r = _rules();
        // useAllowlist == false but payees given
        address[] memory p = new address[](1);
        p[0] = payee;
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.InvalidRules.selector);
        vault.createAllowance(spender, r, p, "");
    }

    function test_create_revert_label_too_long() public {
        string memory longLabel = "123456789012345678901234567890123"; // 33 bytes
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.LabelTooLong.selector);
        vault.createAllowance(spender, _rules(), new address[](0), longLabel);
    }

    function test_create_revert_invalid_payee_zero() public {
        UsdcAllowance.Rules memory r = _rules();
        r.useAllowlist = true;
        address[] memory p = new address[](1);
        p[0] = address(0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.InvalidPayee.selector, address(0)));
        vault.createAllowance(spender, r, p, "");
    }

    function test_create_revert_invalid_payee_duplicate() public {
        UsdcAllowance.Rules memory r = _rules();
        r.useAllowlist = true;
        address[] memory p = new address[](2);
        p[0] = payee;
        p[1] = payee;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.InvalidPayee.selector, payee));
        vault.createAllowance(spender, r, p, "");
    }

    function test_create_ids_by_owner_and_spender() public {
        uint256 id = _create();
        uint256[] memory oids = vault.idsByOwner(owner);
        uint256[] memory sids = vault.idsBySpender(spender);
        assertEq(oids.length, 1);
        assertEq(oids[0], id);
        assertEq(sids.length, 1);
        assertEq(sids[0], id);
    }

    /* ────────────────────────────  fund  ─────────────────────── */

    function test_fund_basic() public {
        uint256 id = _create();
        vm.prank(owner);
        vault.fund{value: 3 ether}(id);
        UsdcAllowance.Allowance memory a = vault.getAllowance(id);
        assertEq(a.balance,     8 ether);
        assertEq(a.totalFunded, 8 ether);
        assertEq(vault.totalHeld(), 8 ether);
    }

    function test_fund_revert_unknown() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.UnknownAllowance.selector, 99));
        vault.fund{value: 1 ether}(99);
    }

    function test_fund_revert_not_owner() public {
        uint256 id = _create();
        vm.prank(other);
        vm.expectRevert(UsdcAllowance.NotOwner.selector);
        vault.fund{value: 1 ether}(id);
    }

    function test_fund_revert_revoked() public {
        uint256 id = _create();
        vm.prank(owner);
        vault.revoke(id);
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.AllowanceRevoked.selector);
        vault.fund{value: 1 ether}(id);
    }

    function test_fund_revert_zero() public {
        uint256 id = _create();
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.ZeroAmount.selector);
        vault.fund{value: 0}(id);
    }

    /* ──────────────────────────  pay  ────────────────────────── */

    function test_pay_basic() public {
        uint256 id = _create();
        uint256 payeeBefore = payee.balance;
        vm.prank(spender);
        vault.pay(id, payee, 0.5 ether, bytes32(0), "hello");
        assertEq(payee.balance - payeeBefore, 0.5 ether);
        UsdcAllowance.Allowance memory a = vault.getAllowance(id);
        assertEq(a.balance,       4.5 ether);
        assertEq(a.totalPaid,     0.5 ether);
        assertEq(a.spentInPeriod, 0.5 ether);
        assertEq(a.paymentCount,  1);
        assertEq(vault.totalHeld(), 4.5 ether);
    }

    function test_pay_error_order_unknown_first() public {
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.UnknownAllowance.selector, 99));
        vault.pay(99, payee, 1 ether, bytes32(0), "");
    }

    function test_pay_error_order_not_spender() public {
        uint256 id = _create();
        vm.prank(other);
        vm.expectRevert(UsdcAllowance.NotSpender.selector);
        vault.pay(id, payee, 1 ether, bytes32(0), "");
    }

    function test_pay_error_order_memo_too_long() public {
        uint256 id = _create();
        string memory longMemo = new string(141);
        vm.prank(spender);
        vm.expectRevert(UsdcAllowance.MemoTooLong.selector);
        vault.pay(id, payee, 1 ether, bytes32(0), longMemo);
    }

    function test_pay_error_revoked_before_expired() public {
        uint256 id = _create();
        vm.prank(owner);
        vault.revoke(id);
        // revoked takes priority over expiry
        vm.prank(spender);
        vm.expectRevert(UsdcAllowance.AllowanceRevoked.selector);
        vault.pay(id, payee, 1 ether, bytes32(0), "");
    }

    function test_pay_error_expired() public {
        uint256 id = _create();
        vm.warp(EXPIRY + 1);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.AllowanceExpired.selector, EXPIRY));
        vault.pay(id, payee, 1 ether, bytes32(0), "");
    }

    function test_pay_error_paused() public {
        uint256 id = _create();
        vm.prank(owner);
        vault.pause(id);
        vm.prank(spender);
        vm.expectRevert(UsdcAllowance.AllowancePaused.selector);
        vault.pay(id, payee, 1 ether, bytes32(0), "");
    }

    function test_pay_error_invalid_payee_zero() public {
        uint256 id = _create();
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.InvalidPayee.selector, address(0)));
        vault.pay(id, address(0), 1 ether, bytes32(0), "");
    }

    function test_pay_error_invalid_payee_spender() public {
        uint256 id = _create();
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.InvalidPayee.selector, spender));
        vault.pay(id, spender, 1 ether, bytes32(0), "");
    }

    function test_pay_error_zero_amount() public {
        uint256 id = _create();
        vm.prank(spender);
        vm.expectRevert(UsdcAllowance.ZeroAmount.selector);
        vault.pay(id, payee, 0, bytes32(0), "");
    }

    function test_pay_error_exceeds_payment_cap() public {
        uint256 id = _create();
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.ExceedsPaymentCap.selector, PER_CAP + 1, PER_CAP));
        vault.pay(id, payee, PER_CAP + 1, bytes32(0), "");
    }

    function test_pay_error_exceeds_period_cap() public {
        // Create with enough balance to never hit InsufficientBalance (100 ether)
        UsdcAllowance.Rules memory r = _rules();
        vm.prank(owner);
        uint256 id = vault.createAllowance{value: 100 ether}(spender, r, new address[](0), "bigbal");
        // exhaust period cap in 1-ether increments (CAP=10 ether, PER_CAP=1 ether)
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(spender);
            vault.pay(id, payee, 1 ether, bytes32(uint256(i + 1)), "");
        }
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.ExceedsPeriodCap.selector, 1 ether, 0));
        vault.pay(id, payee, 1 ether, bytes32(uint256(11)), "");
    }

    function test_pay_error_insufficient_balance() public {
        // Create with 0.5 ether but cap is 1 ether
        UsdcAllowance.Rules memory r = _rules();
        vm.prank(owner);
        uint256 id = vault.createAllowance{value: 0.5 ether}(spender, r, new address[](0), "");
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.InsufficientBalance.selector, 1 ether, 0.5 ether));
        vault.pay(id, payee, 1 ether, bytes32(0), "");
    }

    function test_pay_error_duplicate_ref() public {
        uint256 id = _create();
        bytes32 ref = keccak256("unique-ref");
        vm.prank(spender);
        vault.pay(id, payee, 0.5 ether, ref, "");
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.DuplicateRef.selector, ref));
        vault.pay(id, payee, 0.5 ether, ref, "");
    }

    function test_pay_zero_ref_not_tracked() public {
        uint256 id = _create();
        // Two payments with zero ref should both succeed
        vm.prank(spender);
        vault.pay(id, payee, 0.5 ether, bytes32(0), "first");
        vm.prank(spender);
        vault.pay(id, payee, 0.5 ether, bytes32(0), "second");
        assertEq(vault.getAllowance(id).paymentCount, 2);
    }

    function test_pay_ref_scoped_per_allowance() public {
        bytes32 ref = keccak256("ref");
        // Same ref in two different allowances should be fine
        uint256 id1 = _create();
        UsdcAllowance.Rules memory r = _rules();
        vm.prank(owner);
        uint256 id2 = vault.createAllowance{value: 5 ether}(spender, r, new address[](0), "two");

        vm.prank(spender);
        vault.pay(id1, payee, 0.5 ether, ref, "");
        vm.prank(spender);
        vault.pay(id2, payee, 0.5 ether, ref, "");
        assertEq(vault.isRefUsed(id1, ref), true);
        assertEq(vault.isRefUsed(id2, ref), true);
    }

    function test_pay_transfer_failed_state_unchanged() public {
        RejectingPayee rp = new RejectingPayee();
        uint256 id = _create();
        bytes32 ref = keccak256("fail-ref");
        uint256 balBefore = vault.getAllowance(id).balance;

        vm.prank(spender);
        vm.expectRevert(UsdcAllowance.TransferFailed.selector);
        vault.pay(id, address(rp), 1 ether, ref, "");

        // State must be unchanged
        assertEq(vault.getAllowance(id).balance, balBefore);
        assertEq(vault.isRefUsed(id, ref), false);
    }

    /* ─────────────────────────  withdraw  ────────────────────── */

    function test_withdraw_basic() public {
        uint256 id = _create();
        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        vault.withdraw(id, 2 ether);
        assertEq(owner.balance - ownerBefore, 2 ether);
        assertEq(vault.getAllowance(id).balance, 3 ether);
        assertEq(vault.getAllowance(id).totalRefunded, 2 ether);
        assertEq(vault.totalHeld(), 3 ether);
    }

    function test_withdraw_revert_unknown() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.UnknownAllowance.selector, 99));
        vault.withdraw(99, 1 ether);
    }

    function test_withdraw_revert_not_owner() public {
        uint256 id = _create();
        vm.prank(other);
        vm.expectRevert(UsdcAllowance.NotOwner.selector);
        vault.withdraw(id, 1 ether);
    }

    function test_withdraw_revert_zero() public {
        uint256 id = _create();
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.ZeroAmount.selector);
        vault.withdraw(id, 0);
    }

    function test_withdraw_revert_insufficient() public {
        uint256 id = _create();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.InsufficientBalance.selector, 6 ether, 5 ether));
        vault.withdraw(id, 6 ether);
    }

    /* ─────────────────────────  revoke  ──────────────────────── */

    function test_revoke_basic() public {
        uint256 id = _create();
        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        vault.revoke(id);
        assertEq(owner.balance - ownerBefore, 5 ether); // refunded
        assertEq(vault.getAllowance(id).revoked, true);
        assertEq(vault.getAllowance(id).balance, 0);
        assertEq(vault.totalHeld(), 0);
    }

    function test_revoke_is_final() public {
        uint256 id = _create();
        vm.prank(owner);
        vault.revoke(id);
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.AllowanceRevoked.selector);
        vault.revoke(id);
    }

    function test_revoke_zero_balance() public {
        UsdcAllowance.Rules memory r = _rules();
        vm.prank(owner);
        uint256 id = vault.createAllowance(spender, r, new address[](0), "empty");
        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        vault.revoke(id);
        assertEq(owner.balance, ownerBefore); // no transfer
        assertEq(vault.getAllowance(id).revoked, true);
    }

    /* ──────────────────────  pause / unpause  ─────────────────── */

    function test_pause_unpause() public {
        uint256 id = _create();
        vm.prank(owner);
        vault.pause(id);
        assertEq(vault.getAllowance(id).paused, true);
        assertEq(vault.status(id), 2);

        vm.prank(owner);
        vault.unpause(id);
        assertEq(vault.getAllowance(id).paused, false);
        assertEq(vault.status(id), 1);
    }

    function test_pause_idempotent() public {
        uint256 id = _create();
        vm.prank(owner);
        vault.pause(id);
        vm.recordLogs();
        vm.prank(owner);
        vault.pause(id); // should be idempotent, no event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
    }

    /* ──────────────────────────  views  ──────────────────────── */

    function test_views_unknown_id() public view {
        UsdcAllowance.Allowance memory a = vault.getAllowance(99);
        assertEq(a.owner, address(0));
        assertEq(vault.labelOf(99), "");
        assertEq(vault.pendingLimits(99).activeAt, 0);
        (uint128 p, uint128 pc, uint64 ex) = vault.effectiveLimits(99);
        assertEq(p, 0); assertEq(pc, 0); assertEq(ex, 0);
        UsdcAllowance.Budget memory b = vault.budget(99);
        assertEq(b.status, 0);
        (bool ok, uint8 reason) = vault.canPay(99, payee, 1, bytes32(0));
        assertFalse(ok);
        assertEq(reason, 1);
        assertEq(vault.status(99), 0);
        (address[] memory ps, uint64[] memory ats) = vault.getPayees(99);
        assertEq(ps.length, 0);
        assertEq(ats.length, 0);
        assertEq(vault.payeeActiveAt(99, payee), 0);
        assertFalse(vault.isRefUsed(99, bytes32(0)));
    }

    function test_status_flow() public {
        uint256 id = _create();
        assertEq(vault.status(id), 1); // Active

        vm.prank(owner);
        vault.pause(id);
        assertEq(vault.status(id), 2); // Paused

        vm.warp(EXPIRY + 1);
        assertEq(vault.status(id), 3); // Expired (precedence over Paused)

        // Create a fresh, non-expired allowance to test revoked status
        EXPIRY = uint64(block.timestamp + 30 days);
        UsdcAllowance.Rules memory r = UsdcAllowance.Rules({
            perPaymentCap: PER_CAP,
            periodCap: CAP,
            periodLength: PERIOD,
            periodAnchor: 0,
            expiresAt: EXPIRY,
            loosenDelay: 0,
            useAllowlist: false
        });
        vm.prank(owner);
        uint256 id2 = vault.createAllowance(spender, r, new address[](0), "fresh");
        assertEq(vault.status(id2), 1); // Active

        vm.prank(owner);
        vault.revoke(id2);
        assertEq(vault.status(id2), 4); // Revoked

        // Also: revoked allowance that is also expired still shows Revoked
        vm.warp(block.timestamp + 60 days);
        assertEq(vault.status(id2), 4); // Revoked takes precedence
    }

    /* ─────────────────────────  reentrancy  ──────────────────── */

    function test_reentrancy_payee_cannot_reenter_pay() public {
        ReentrantPayee rp = new ReentrantPayee(vault);
        address secondPayee_ = address(0xBEEF);
        vm.deal(address(rp), 0);

        // Create allowance where rp is a payee
        vm.prank(owner);
        uint256 id = vault.createAllowance{value: 5 ether}(spender, _rules(), new address[](0), "re");
        rp.setup(id, secondPayee_, 1 ether);

        vm.prank(spender);
        vault.pay(id, address(rp), 1 ether, bytes32(0), "");

        // The reentrant attempt inside receive() must have reverted
        assertTrue(rp.reentryReverted());
    }

    function test_reentrancy_reentrant_owner_cannot_revoke_during_revoke() public {
        ReentrantOwner ro = new ReentrantOwner(vault);
        vm.deal(address(ro), 10 ether);

        // ro is the owner; fund so there is a refund send on revoke
        vm.prank(address(ro));
        uint256 id = vault.createAllowance{value: 2 ether}(spender, _rules(), new address[](0), "ro-test");
        ro.setup(id);

        // revoke from ro — sends ETH to ro, which tries to re-enter revoke
        // The inner call is caught by ro's try/catch, so the outer revoke succeeds
        vm.prank(address(ro));
        vault.revoke(id);

        // The inner revoke should have been blocked by ReentrancyGuard (caught in ro.receive)
        assertTrue(ro.reentryReverted(), "inner revoke should have reverted");
        // allowance is revoked and balance is zero
        assertTrue(vault.getAllowance(id).revoked);
        assertEq(vault.getAllowance(id).balance, 0);
    }

    /* ─────────────────────────  budget() balance-cap tests  ────────────── */

    /// @notice balance (0.12 ether) < cap headroom (0.15 ether) →
    ///         remainingInPeriod == balance, maxPayment == min(balance, perPaymentCap).
    function test_budget_capped_by_balance() public {
        // Fund with 0.12 ether; PER_CAP=1 ether, CAP=10 ether, so cap headroom = 10 ether.
        // remainingInPeriod must be capped to the 0.12 ether balance.
        vm.prank(owner);
        uint256 id = vault.createAllowance{value: 0.12 ether}(spender, _rules(), new address[](0), "bal-cap");

        UsdcAllowance.Budget memory b = vault.budget(id);
        assertEq(b.status, 1, "should be Active");
        assertEq(b.remainingInPeriod, 0.12 ether, "remainingInPeriod must equal balance");
        // maxPayment = min(0.12 ether, 1 ether perPaymentCap) = 0.12 ether
        assertEq(b.maxPayment, 0.12 ether, "maxPayment must equal balance (< perPaymentCap)");
    }

    /// @notice After a withdraw that leaves 0.04 ether, remainingInPeriod drops to 0.04 ether.
    function test_budget_capped_after_partial_withdraw() public {
        vm.prank(owner);
        uint256 id = vault.createAllowance{value: 2 ether}(spender, _rules(), new address[](0), "wd-cap");

        // Withdraw most of the balance, leaving 0.04 ether.
        vm.prank(owner);
        vault.withdraw(id, 1.96 ether);

        UsdcAllowance.Budget memory b = vault.budget(id);
        assertEq(b.status, 1, "should be Active");
        assertEq(b.balance, 0.04 ether, "balance should be 0.04 ether");
        assertEq(b.remainingInPeriod, 0.04 ether, "remainingInPeriod must be capped at 0.04 ether");
        assertEq(b.maxPayment, 0.04 ether, "maxPayment must be capped at 0.04 ether");
    }

    /// @notice Paused and revoked allowances must report remainingInPeriod=0 and maxPayment=0.
    function test_budget_paused_and_revoked_zero() public {
        vm.prank(owner);
        uint256 idPaused = vault.createAllowance{value: 5 ether}(spender, _rules(), new address[](0), "paused");
        vm.prank(owner);
        uint256 idRevoked = vault.createAllowance{value: 5 ether}(spender, _rules(), new address[](0), "revoked");

        vm.prank(owner); vault.pause(idPaused);
        vm.prank(owner); vault.revoke(idRevoked);

        UsdcAllowance.Budget memory bp = vault.budget(idPaused);
        assertEq(bp.status, 2, "paused status");
        assertEq(bp.remainingInPeriod, 0, "paused: remainingInPeriod must be 0");
        assertEq(bp.maxPayment, 0, "paused: maxPayment must be 0");

        UsdcAllowance.Budget memory br = vault.budget(idRevoked);
        assertEq(br.status, 4, "revoked status");
        assertEq(br.remainingInPeriod, 0, "revoked: remainingInPeriod must be 0");
        assertEq(br.maxPayment, 0, "revoked: maxPayment must be 0");
    }
}
