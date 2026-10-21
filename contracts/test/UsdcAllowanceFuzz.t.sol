// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {UsdcAllowance} from "../UsdcAllowance.sol";

/// @notice Fuzz tests: canPay agrees with pay, period index math, spend never exceeds caps.
contract UsdcAllowanceFuzzTest is Test {
    UsdcAllowance internal vault;

    address internal owner   = address(0xA001);
    address internal spender = address(0xA002);
    address internal payee   = address(0xA003);

    uint64  constant MIN_P  = 60;
    uint64  constant MAX_P  = 365 days;
    uint64  constant MAX_DUR = 3650 days;

    function setUp() public {
        vault = new UsdcAllowance();
        vm.deal(owner,  1_000_000 ether);
        vm.deal(spender, 100 ether);
        vm.deal(payee,   0);
    }

    /* ─── helpers ─── */

    function _boundedRules(
        uint128 perCap,
        uint128 periodCap,
        uint64  periodLen,
        uint64  anchor,
        uint64  expiresAt,
        uint32  loosenDelay
    ) internal view returns (UsdcAllowance.Rules memory) {
        perCap      = uint128(bound(perCap,       1,        type(uint64).max));
        periodCap   = uint128(bound(periodCap,    perCap,   type(uint64).max));
        periodLen   = uint64(bound(periodLen,     MIN_P,    MAX_P));
        anchor      = uint64(bound(anchor,        0,        block.timestamp));
        expiresAt   = uint64(bound(expiresAt,     block.timestamp + 1, block.timestamp + MAX_DUR));
        loosenDelay = uint32(bound(loosenDelay,   0,        30 days));
        return UsdcAllowance.Rules({
            perPaymentCap: perCap,
            periodCap:     periodCap,
            periodLength:  periodLen,
            periodAnchor:  anchor,
            expiresAt:     expiresAt,
            loosenDelay:   loosenDelay,
            useAllowlist:  false
        });
    }

    /* ─── canPay agrees with pay ─── */

    /// @notice If canPay says ok, pay() must not revert. If canPay says no, pay must revert.
    function testFuzz_canPay_agrees_with_pay(
        uint128 perCap,
        uint128 periodCap,
        uint64  periodLen,
        uint64  anchor,
        uint64  expiresAt,
        uint32  loosenDelay,
        uint128 fundAmount,
        uint128 payAmount
    ) public {
        UsdcAllowance.Rules memory r = _boundedRules(perCap, periodCap, periodLen, anchor, expiresAt, loosenDelay);
        fundAmount = uint128(bound(fundAmount, 1, 100_000 ether));
        payAmount  = uint128(bound(payAmount,  1, 100_000 ether));

        vm.prank(owner);
        uint256 id = vault.createAllowance{value: fundAmount}(spender, r, new address[](0), "fuzz");

        (bool ok, uint8 reason) = vault.canPay(id, payee, payAmount, bytes32(0));

        if (ok) {
            vm.prank(spender);
            vault.pay(id, payee, payAmount, bytes32(0), "");
        } else {
            // pay must revert (we only verify it reverts, not the exact error,
            // because effective limits may differ from rule input after pending resolution)
            vm.prank(spender);
            bool reverted;
            try vault.pay(id, payee, payAmount, bytes32(0), "") {
                reverted = false;
            } catch {
                reverted = true;
            }
            assertTrue(reverted, string(abi.encodePacked("expected revert for reason=", uint8(reason))));
        }
    }

    /* ─── period index math ─── */

    function testFuzz_period_index_math(
        uint64 anchorOffset,
        uint64 periodLen,
        uint64 timeAdvance
    ) public {
        periodLen   = uint64(bound(periodLen,   MIN_P, 7 days));
        anchorOffset = uint64(bound(anchorOffset, 0, 30 days));
        timeAdvance = uint64(bound(timeAdvance,  0, 365 days));

        uint64 anchor = block.timestamp > anchorOffset ? uint64(block.timestamp - anchorOffset) : 0;
        if (anchor == 0) anchor = uint64((block.timestamp / 1 days) * 1 days);

        UsdcAllowance.Rules memory r = UsdcAllowance.Rules({
            perPaymentCap: 1 ether,
            periodCap:     1000 ether,
            periodLength:  periodLen,
            periodAnchor:  anchor,
            expiresAt:     uint64(block.timestamp + MAX_DUR),
            loosenDelay:   0,
            useAllowlist:  false
        });

        vm.prank(owner);
        uint256 id = vault.createAllowance{value: 100 ether}(spender, r, new address[](0), "");

        vm.warp(block.timestamp + timeAdvance);

        UsdcAllowance.Budget memory b = vault.budget(id);
        uint64 expectedIndex = uint64((block.timestamp - anchor) / periodLen);
        assertEq(b.periodIndex, expectedIndex, "period index mismatch");

        // periodStart and periodEnd must bracket block.timestamp
        assertLe(b.periodStart, block.timestamp, "periodStart > now");
        assertGt(b.periodEnd,   block.timestamp, "periodEnd <= now");
    }

    /* ─── spend never exceeds caps ─── */

    function testFuzz_spend_never_exceeds_caps(
        uint8 numPayments,
        uint128 perCap,
        uint128 periodCap
    ) public {
        numPayments = uint8(bound(numPayments, 1, 20));
        perCap      = uint128(bound(perCap,    1 ether, 5 ether));
        periodCap   = uint128(bound(periodCap, perCap,  20 ether));

        UsdcAllowance.Rules memory r = UsdcAllowance.Rules({
            perPaymentCap: perCap,
            periodCap:     periodCap,
            periodLength:  1 days,
            periodAnchor:  0,
            expiresAt:     uint64(block.timestamp + MAX_DUR),
            loosenDelay:   0,
            useAllowlist:  false
        });

        vm.prank(owner);
        uint256 id = vault.createAllowance{value: periodCap * 2}(spender, r, new address[](0), "caps");

        uint256 totalSpentInPeriod = 0;
        for (uint256 i = 0; i < numPayments; i++) {
            // Use canPay to decide if we should pay
            uint256 amt = perCap;
            (bool ok,) = vault.canPay(id, payee, amt, bytes32(uint256(i + 1)));
            if (ok) {
                vm.prank(spender);
                vault.pay(id, payee, amt, bytes32(uint256(i + 1)), "");
                totalSpentInPeriod += amt;
            }
        }

        UsdcAllowance.Allowance memory a = vault.getAllowance(id);
        assertLe(a.spentInPeriod, periodCap, "spentInPeriod exceeded periodCap");

        // Also verify individual payment tracking
        assertLe(a.totalPaid, periodCap * 2, "totalPaid sanity overflow");
    }

    /* ─── canPay reason codes are exhaustive ─── */

    function testFuzz_canPay_reason_is_in_range(
        uint128 perCap,
        uint128 periodCap,
        uint64  periodLen,
        uint64  anchor,
        uint64  expiresAt,
        uint32  loosenDelay,
        uint128 fundAmount,
        uint128 payAmount
    ) public {
        UsdcAllowance.Rules memory r = _boundedRules(perCap, periodCap, periodLen, anchor, expiresAt, loosenDelay);
        fundAmount = uint128(bound(fundAmount, 0, 1000 ether));
        payAmount  = uint128(bound(payAmount,  0, 1000 ether));

        vm.prank(owner);
        uint256 id = vault.createAllowance{value: fundAmount}(spender, r, new address[](0), "range");

        (bool ok, uint8 reason) = vault.canPay(id, payee, payAmount, bytes32(0));
        assertTrue(reason <= 11, "reason out of range");
        if (ok) assertEq(reason, 0);
        if (!ok) assertGt(reason, 0);
    }
}
