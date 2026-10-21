// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {UsdcAllowance} from "../UsdcAllowance.sol";

/// @notice Period boundary tests: fixed windows, idle periods, past anchor, UTC-day anchor.
contract UsdcAllowancePeriodsTest is Test {
    UsdcAllowance internal vault;

    address internal owner   = address(0xA001);
    address internal spender = address(0xA002);
    address internal payee   = address(0xA003);

    uint64  internal PERIOD  = 1 days;
    uint128 internal CAP     = 10 ether;
    uint128 internal PER_CAP = 1 ether;
    uint64  internal EXPIRY;
    uint256 internal refNonce;

    function setUp() public {
        // Ensure block.timestamp is large enough to avoid underflow in anchor arithmetic
        vm.warp(7 days + 1);
        vault = new UsdcAllowance();
        vm.deal(owner,  200 ether);
        vm.deal(spender, 10 ether);
        EXPIRY = uint64(block.timestamp + 365 days);
    }

    /* ─── helpers ─── */

    function _rules(uint64 anchor) internal view returns (UsdcAllowance.Rules memory) {
        return UsdcAllowance.Rules({
            perPaymentCap: PER_CAP,
            periodCap:     CAP,
            periodLength:  PERIOD,
            periodAnchor:  anchor,
            expiresAt:     EXPIRY,
            loosenDelay:   0,
            useAllowlist:  false
        });
    }

    function _pay(uint256 id, uint256 amt) internal {
        vm.prank(spender);
        vault.pay(id, payee, amt, bytes32(++refNonce), "");
    }

    /* ─── exact boundary ─── */

    function test_period_boundary_exact() public {
        // anchor = 0 → resolved to current UTC day boundary
        uint64 anchor = uint64((block.timestamp / 1 days) * 1 days);
        vm.prank(owner);
        uint256 id = vault.createAllowance{value: 50 ether}(spender, _rules(0), new address[](0), "");

        // period 0: timestamp is anchor+0 … anchor+PERIOD-1
        _pay(id, 1 ether); // spend 1 ether in period 0

        // warp to last second of period 0
        vm.warp(anchor + PERIOD - 1);
        _pay(id, 1 ether); // still period 0, cap is 10 so fine

        // Check spent reflects two payments
        UsdcAllowance.Allowance memory a = vault.getAllowance(id);
        assertEq(a.spentInPeriod, 2 ether);

        // warp to first second of period 1
        vm.warp(anchor + PERIOD);
        _pay(id, 1 ether); // now period 1, fresh counter
        a = vault.getAllowance(id);
        assertEq(a.spentInPeriod, 1 ether); // reset
        assertEq(a.periodIndex, 1);
    }

    function test_idle_period_resets_spend() public {
        uint64 anchor = uint64((block.timestamp / 1 days) * 1 days);
        vm.prank(owner);
        uint256 id = vault.createAllowance{value: 50 ether}(spender, _rules(0), new address[](0), "");

        // exhaust period 0
        for (uint256 i = 0; i < 10; i++) {
            _pay(id, 1 ether);
        }
        assertEq(vault.getAllowance(id).spentInPeriod, 10 ether);

        // skip 3 periods (periods 1 and 2 are idle)
        vm.warp(anchor + 3 * PERIOD);

        // now in period 3 — cap should reset
        _pay(id, 1 ether);
        UsdcAllowance.Allowance memory a = vault.getAllowance(id);
        assertEq(a.spentInPeriod, 1 ether);
        assertEq(a.periodIndex, 3);
    }

    /* ─── past anchor ─── */

    function test_past_anchor_computes_correct_period() public {
        // anchor = yesterday, so we are already in period 1
        uint64 anchor = uint64(block.timestamp - 2 days - 3600);
        vm.prank(owner);
        uint256 id = vault.createAllowance{value: 20 ether}(spender, _rules(anchor), new address[](0), "");

        UsdcAllowance.Allowance memory a = vault.getAllowance(id);
        // Expected period: (now - anchor) / PERIOD = (2 days + 3600) / 1 days = 2
        assertEq(a.periodIndex, 2);

        // Pay in period 2
        _pay(id, 1 ether);
        assertEq(vault.getAllowance(id).spentInPeriod, 1 ether);
    }

    /* ─── anchor 0 → UTC midnight ─── */

    function test_anchor_zero_snaps_to_utc_midnight() public {
        // Set block.timestamp to something that is NOT midnight
        vm.warp(1_000_000 + 3600); // some arbitrary time 1h into a day
        EXPIRY = uint64(block.timestamp + 365 days);

        vm.prank(owner);
        UsdcAllowance.Rules memory r = UsdcAllowance.Rules({
            perPaymentCap: PER_CAP,
            periodCap: CAP,
            periodLength: PERIOD,
            periodAnchor: 0,
            expiresAt: EXPIRY,
            loosenDelay: 0,
            useAllowlist: false
        });
        vm.deal(owner, 100 ether);
        uint256 id = vault.createAllowance{value: 10 ether}(spender, r, new address[](0), "");

        UsdcAllowance.Allowance memory a = vault.getAllowance(id);
        // anchor must be exactly block.timestamp rounded down to day boundary
        uint64 expectedAnchor = uint64((block.timestamp / 1 days) * 1 days);
        assertEq(a.periodAnchor, expectedAnchor);
    }

    /* ─── period cap saturates after idle ─── */

    function test_period_cap_does_not_underflow_after_idle() public {
        uint64 anchor = uint64((block.timestamp / 1 days) * 1 days);
        // Set per-payment cap = period cap = 1 ether for simplicity
        vm.prank(owner);
        UsdcAllowance.Rules memory r = UsdcAllowance.Rules({
            perPaymentCap: 1 ether,
            periodCap: 1 ether,
            periodLength: PERIOD,
            periodAnchor: anchor,
            expiresAt: EXPIRY,
            loosenDelay: 0,
            useAllowlist: false
        });
        uint256 id = vault.createAllowance{value: 10 ether}(spender, r, new address[](0), "");

        _pay(id, 1 ether);
        // skip 2 periods
        vm.warp(anchor + 2 * PERIOD);
        // remaining after idle should be full 1 ether (not underflow)
        (bool ok, uint8 reason) = vault.canPay(id, payee, 1 ether, bytes32(0));
        assertTrue(ok, string(abi.encodePacked("reason=", reason)));
    }

    /* ─── budget() periodStart/End accuracy ─── */

    function test_budget_period_start_end() public {
        uint64 anchor = uint64(block.timestamp);
        vm.prank(owner);
        uint256 id = vault.createAllowance{value: 10 ether}(spender, _rules(anchor), new address[](0), "");

        UsdcAllowance.Budget memory b = vault.budget(id);
        assertEq(b.periodStart, anchor);
        assertEq(b.periodEnd,   anchor + PERIOD);
        assertEq(b.periodIndex, 0);
        assertEq(b.status,      1);

        vm.warp(anchor + PERIOD + 100);
        b = vault.budget(id);
        assertEq(b.periodStart, anchor + PERIOD);
        assertEq(b.periodEnd,   anchor + 2 * PERIOD);
        assertEq(b.periodIndex, 1);
    }

    /* ─── canPay agrees with pay across period boundary ─── */

    function test_canPay_period_boundary_agrees_with_pay() public {
        uint64 anchor = uint64((block.timestamp / 1 days) * 1 days);
        vm.prank(owner);
        uint256 id = vault.createAllowance{value: 20 ether}(spender, _rules(0), new address[](0), "");

        // exhaust period 0
        for (uint256 i = 0; i < 10; i++) {
            _pay(id, 1 ether);
        }
        (bool ok, uint8 reason) = vault.canPay(id, payee, 1 ether, bytes32(0));
        assertFalse(ok);
        assertEq(reason, 9); // ExceedsPeriodCap

        // cross period boundary
        vm.warp(anchor + PERIOD);
        (ok, reason) = vault.canPay(id, payee, 1 ether, bytes32(0));
        assertTrue(ok, "should be ok after period reset");
        _pay(id, 1 ether); // should not revert
    }

    /* ─── expiry boundary ─── */

    function test_expiry_boundary_inclusive() public {
        uint64 anchor = uint64(block.timestamp);
        vm.prank(owner);
        uint64 expiresAt = uint64(block.timestamp + 100);
        UsdcAllowance.Rules memory r = UsdcAllowance.Rules({
            perPaymentCap: 1 ether,
            periodCap: 10 ether,
            periodLength: 60,
            periodAnchor: anchor,
            expiresAt: expiresAt,
            loosenDelay: 0,
            useAllowlist: false
        });
        uint256 id = vault.createAllowance{value: 5 ether}(spender, r, new address[](0), "");

        // one second before expiry — should succeed
        vm.warp(expiresAt - 1);
        _pay(id, 1 ether);

        // at exactly expiresAt — should fail
        vm.warp(expiresAt);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.AllowanceExpired.selector, expiresAt));
        vault.pay(id, payee, 1 ether, bytes32(0), "");
    }
}
