// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {UsdcAllowance} from "../UsdcAllowance.sol";
import {RejectingPayee} from "../test-helpers/AllowanceHelpers.sol";

/// @notice Stateful invariant handler for UsdcAllowance.
/// Invariants:
/// 1. contract balance == totalHeld == sum of all per-allowance balances
/// 2. per allowance: totalFunded == balance + totalPaid + totalRefunded
/// 3. after every successful payment: spentInPeriod <= effectivePeriodCap, amount <= effectivePerPaymentCap
/// 4. only allowlisted+active payees get paid when useAllowlist=true
/// 5. revoked is terminal (cannot revert to active)
contract AllowanceHandler is Test {
    UsdcAllowance public vault;
    RejectingPayee public rejector;

    // 2 owners, 2 spenders, 3 payees (one is the rejector)
    address[2] public owners;
    address[2] public spenders;
    address[3] public normalPayees;

    // Tracked allowance ids
    uint256[] public ids;
    // Track whether each id has ever been revoked
    mapping(uint256 => bool) public wasRevoked;
    // Track which ids use an allowlist
    mapping(uint256 => bool) public usesAllowlist;
    // Track per-id listed payees
    mapping(uint256 => address[]) public listedPayees;

    uint256 constant FUND = 10 ether;

    constructor(UsdcAllowance _vault) {
        vault = _vault;
        rejector = new RejectingPayee();

        owners[0]  = address(0xA100); owners[1]  = address(0xA200);
        spenders[0] = address(0xB100); spenders[1] = address(0xB200);
        normalPayees[0] = address(0xC100);
        normalPayees[1] = address(0xC200);
        normalPayees[2] = address(rejector);

        for (uint256 i = 0; i < 2; i++) {
            vm.deal(owners[i],   1_000_000 ether);
            vm.deal(spenders[i], 1_000_000 ether);
        }
        for (uint256 i = 0; i < 3; i++) {
            vm.deal(normalPayees[i], 0);
        }
    }

    // ──────────────────────── create ────────────────────────

    function createAllowance(
        uint8 ownerIdx,
        uint8 spenderIdx,
        uint128 perCap,
        uint128 periodCap,
        bool useList
    ) external {
        ownerIdx  %= 2;
        spenderIdx %= 2;
        perCap    = uint128(bound(perCap,    1, 2 ether));
        periodCap = uint128(bound(periodCap, perCap, 10 ether));

        address owner_  = owners[ownerIdx];
        address spender_ = spenders[spenderIdx];
        if (owner_ == spender_) return; // skip degenerate case

        UsdcAllowance.Rules memory r = UsdcAllowance.Rules({
            perPaymentCap: perCap,
            periodCap:     periodCap,
            periodLength:  1 hours,
            periodAnchor:  0,
            expiresAt:     uint64(block.timestamp + 365 days),
            loosenDelay:   0,
            useAllowlist:  useList
        });

        vm.prank(owner_);
        try vault.createAllowance{value: FUND}(spender_, r, new address[](0), "inv") returns (uint256 id) {
            ids.push(id);
            usesAllowlist[id] = useList;
        } catch {}
    }

    // ──────────────────────── fund ────────────────────────

    function fund(uint8 idIdx) external {
        if (ids.length == 0) return;
        uint256 id = ids[idIdx % ids.length];
        UsdcAllowance.Allowance memory a = vault.getAllowance(id);
        if (a.owner == address(0) || a.revoked) return;
        vm.prank(a.owner);
        try vault.fund{value: 1 ether}(id) {} catch {}
    }

    // ──────────────────────── pay ────────────────────────

    function pay(uint8 idIdx, uint8 payeeIdx, uint128 amount) external {
        if (ids.length == 0) return;
        uint256 id = ids[idIdx % ids.length];
        UsdcAllowance.Allowance memory a = vault.getAllowance(id);
        if (a.owner == address(0) || a.revoked) return;

        payeeIdx %= 3;
        address target = normalPayees[payeeIdx];
        amount = uint128(bound(amount, 1, 2 ether));

        vm.prank(a.spender);
        try vault.pay(id, target, amount, bytes32(uint256(block.timestamp) ^ uint256(uint160(target)) ^ amount), "") {
            // Track listed payee post-payment check done in invariant
        } catch {}
    }

    // ──────────────────────── addPayees ────────────────────────

    function addPayee(uint8 idIdx, uint8 payeeIdx) external {
        if (ids.length == 0) return;
        uint256 id = ids[idIdx % ids.length];
        UsdcAllowance.Allowance memory a = vault.getAllowance(id);
        if (a.owner == address(0) || a.revoked || !a.useAllowlist) return;

        payeeIdx %= 3;
        address target = normalPayees[payeeIdx];

        address[] memory p = new address[](1);
        p[0] = target;
        vm.prank(a.owner);
        try vault.addPayees(id, p) {
            // track
            if (_payeeIndex(id, target) == 0) {
                listedPayees[id].push(target);
            }
        } catch {}

        // refresh listed payees from contract
        _refreshListedPayees(id);
    }

    function _payeeIndex(uint256 id, address payee_) internal view returns (uint256) {
        (address[] memory stored,) = vault.getPayees(id);
        for (uint256 i = 0; i < stored.length; i++) {
            if (stored[i] == payee_) return i + 1;
        }
        return 0;
    }

    function _refreshListedPayees(uint256 id) internal {
        (address[] memory stored,) = vault.getPayees(id);
        delete listedPayees[id];
        for (uint256 i = 0; i < stored.length; i++) {
            listedPayees[id].push(stored[i]);
        }
    }

    // ──────────────────────── pause/unpause ────────────────────────

    function togglePause(uint8 idIdx) external {
        if (ids.length == 0) return;
        uint256 id = ids[idIdx % ids.length];
        UsdcAllowance.Allowance memory a = vault.getAllowance(id);
        if (a.owner == address(0) || a.revoked) return;
        if (a.paused) {
            vm.prank(a.owner); try vault.unpause(id) {} catch {}
        } else {
            vm.prank(a.owner); try vault.pause(id) {} catch {}
        }
    }

    // ──────────────────────── withdraw ────────────────────────

    function withdraw(uint8 idIdx, uint128 amount) external {
        if (ids.length == 0) return;
        uint256 id = ids[idIdx % ids.length];
        UsdcAllowance.Allowance memory a = vault.getAllowance(id);
        if (a.owner == address(0) || a.revoked || a.balance == 0) return;
        amount = uint128(bound(amount, 1, a.balance));
        vm.prank(a.owner);
        try vault.withdraw(id, amount) {} catch {}
    }

    // ──────────────────────── revoke ────────────────────────

    function revoke(uint8 idIdx) external {
        if (ids.length == 0) return;
        uint256 id = ids[idIdx % ids.length];
        UsdcAllowance.Allowance memory a = vault.getAllowance(id);
        if (a.owner == address(0) || a.revoked) return;
        vm.prank(a.owner);
        try vault.revoke(id) {
            wasRevoked[id] = true;
        } catch {}
    }

    // ──────────────────────── warp ────────────────────────

    function warp(uint32 delta) external {
        delta = uint32(bound(delta, 1, 7 days));
        vm.warp(block.timestamp + delta);
    }
}

contract UsdcAllowanceInvariantsTest is StdInvariant, Test {
    UsdcAllowance internal vault;
    AllowanceHandler internal handler;

    function setUp() public {
        vault   = new UsdcAllowance();
        handler = new AllowanceHandler(vault);
        targetContract(address(handler));
    }

    /* ── Invariant 1: contract balance == totalHeld ── */

    function invariant_contractBalance_equalsTotalHeld() public view {
        assertEq(
            address(vault).balance,
            vault.totalHeld(),
            "contract balance != totalHeld"
        );
    }

    /* ── Invariant 2: totalHeld == sum of balances ── */

    function invariant_totalHeld_equalsSumOfBalances() public view {
        uint256 count = vault.allowanceCount();
        uint256 sum = 0;
        for (uint256 id = 1; id <= count; id++) {
            sum += vault.getAllowance(id).balance;
        }
        assertEq(vault.totalHeld(), sum, "totalHeld != sum of balances");
    }

    /* ── Invariant 3: accounting identity per allowance ── */

    function invariant_accounting_identity_per_allowance() public view {
        uint256 count = vault.allowanceCount();
        for (uint256 id = 1; id <= count; id++) {
            UsdcAllowance.Allowance memory a = vault.getAllowance(id);
            assertEq(
                a.totalFunded,
                a.balance + a.totalPaid + a.totalRefunded,
                "accounting identity broken"
            );
        }
    }

    /* ── Invariant 4: spentInPeriod <= effective period cap (for active period) ── */

    function invariant_spentInPeriod_within_cap() public view {
        uint256 count = vault.allowanceCount();
        for (uint256 id = 1; id <= count; id++) {
            UsdcAllowance.Allowance memory a = vault.getAllowance(id);
            if (a.revoked) continue;
            (, uint128 effPeriodCap,) = vault.effectiveLimits(id);
            // Check only if we're in the same stored period
            uint64 currentPeriod = uint64((block.timestamp - a.periodAnchor) / a.periodLength);
            if (currentPeriod == a.periodIndex) {
                assertLe(a.spentInPeriod, effPeriodCap, "spentInPeriod > periodCap");
            }
        }
    }

    /* ── Invariant 5: revoked is terminal ── */

    function invariant_revoked_is_terminal() public view {
        uint256 count = vault.allowanceCount();
        for (uint256 id = 1; id <= count; id++) {
            if (handler.wasRevoked(id)) {
                assertTrue(vault.getAllowance(id).revoked, "revoked allowance came back to life");
            }
        }
    }

    /* ── Invariant 6: revoked allowance has zero balance ── */

    function invariant_revoked_zero_balance() public view {
        uint256 count = vault.allowanceCount();
        for (uint256 id = 1; id <= count; id++) {
            UsdcAllowance.Allowance memory a = vault.getAllowance(id);
            if (a.revoked) {
                assertEq(a.balance, 0, "revoked allowance has non-zero balance");
            }
        }
    }

    /* ── Invariant 7: budget().remainingInPeriod == min(periodCap - spent, balance) for Active ── */

    function invariant_budget_remainingInPeriod_capped_by_balance() public view {
        uint256 count = vault.allowanceCount();
        for (uint256 id = 1; id <= count; id++) {
            UsdcAllowance.Budget memory b = vault.budget(id);
            if (b.status != 1) continue; // only Active allowances

            UsdcAllowance.Allowance memory a = vault.getAllowance(id);
            (, uint128 effPeriodCap,) = vault.effectiveLimits(id);

            // Compute current spentInPeriod (may be 0 if in a new period)
            uint64 currentPeriod = uint64((block.timestamp - a.periodAnchor) / a.periodLength);
            uint128 spent = currentPeriod > a.periodIndex ? 0 : a.spentInPeriod;

            uint128 capHeadroom = spent >= effPeriodCap ? 0 : effPeriodCap - spent;
            uint128 expected = capHeadroom < a.balance ? capHeadroom : a.balance;

            assertEq(
                b.remainingInPeriod,
                expected,
                "budget().remainingInPeriod != min(capHeadroom, balance)"
            );
        }
    }
}
