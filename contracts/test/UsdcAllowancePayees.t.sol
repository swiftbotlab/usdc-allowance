// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {UsdcAllowance} from "../UsdcAllowance.sol";

/// @notice Payee management tests: delayed add, allowlist enforcement, max 20,
///         swap-and-pop removal, re-add after remove, various error paths.
contract UsdcAllowancePayeesTest is Test {
    UsdcAllowance internal vault;

    address internal owner   = address(0xA001);
    address internal spender = address(0xA002);
    address[25] internal payees;

    uint64  internal PERIOD = 1 days;
    uint32  internal DELAY  = 1 hours;
    uint64  internal EXPIRY;

    function setUp() public {
        vault = new UsdcAllowance();
        vm.deal(owner, 200 ether);
        EXPIRY = uint64(block.timestamp + 60 days);
        for (uint256 i = 0; i < 25; i++) {
            payees[i] = address(uint160(0xB001 + i));
            vm.deal(payees[i], 1 ether);
        }
    }

    /* ─── helpers ─── */

    function _rulesAllowlist(uint32 delay, bool list) internal view returns (UsdcAllowance.Rules memory) {
        return UsdcAllowance.Rules({
            perPaymentCap: 1 ether,
            periodCap:     100 ether,
            periodLength:  PERIOD,
            periodAnchor:  0,
            expiresAt:     EXPIRY,
            loosenDelay:   delay,
            useAllowlist:  list
        });
    }

    function _createAllowlist(uint32 delay) internal returns (uint256 id) {
        vm.prank(owner);
        id = vault.createAllowance{value: 50 ether}(
            spender, _rulesAllowlist(delay, true), new address[](0), ""
        );
    }

    function _createNoList() internal returns (uint256 id) {
        vm.prank(owner);
        id = vault.createAllowance{value: 50 ether}(
            spender, _rulesAllowlist(0, false), new address[](0), ""
        );
    }

    /* ─── addPayees errors ─── */

    function test_addPayees_revert_unknown() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.UnknownAllowance.selector, 99));
        vault.addPayees(99, new address[](0));
    }

    function test_addPayees_revert_not_owner() public {
        uint256 id = _createAllowlist(0);
        address[] memory p = new address[](1);
        p[0] = payees[0];
        vm.prank(address(0xDEAD));
        vm.expectRevert(UsdcAllowance.NotOwner.selector);
        vault.addPayees(id, p);
    }

    function test_addPayees_revert_revoked() public {
        uint256 id = _createAllowlist(0);
        vm.prank(owner);
        vault.revoke(id);
        address[] memory p = new address[](1);
        p[0] = payees[0];
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.AllowanceRevoked.selector);
        vault.addPayees(id, p);
    }

    function test_addPayees_revert_allowlist_disabled() public {
        uint256 id = _createNoList();
        address[] memory p = new address[](1);
        p[0] = payees[0];
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.AllowlistDisabled.selector);
        vault.addPayees(id, p);
    }

    function test_addPayees_revert_invalid_payee_zero() public {
        uint256 id = _createAllowlist(0);
        address[] memory p = new address[](1);
        p[0] = address(0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.InvalidPayee.selector, address(0)));
        vault.addPayees(id, p);
    }

    function test_addPayees_revert_invalid_payee_spender() public {
        uint256 id = _createAllowlist(0);
        address[] memory p = new address[](1);
        p[0] = spender;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.InvalidPayee.selector, spender));
        vault.addPayees(id, p);
    }

    /* ─── max 20 payees ─── */

    function test_addPayees_max_20() public {
        uint256 id = _createAllowlist(0);
        address[] memory batch = new address[](20);
        for (uint256 i = 0; i < 20; i++) {
            batch[i] = payees[i];
        }
        vm.prank(owner);
        vault.addPayees(id, batch);
        (address[] memory stored,) = vault.getPayees(id);
        assertEq(stored.length, 20);
    }

    function test_addPayees_revert_exceeds_max() public {
        uint256 id = _createAllowlist(0);
        address[] memory batch = new address[](20);
        for (uint256 i = 0; i < 20; i++) {
            batch[i] = payees[i];
        }
        vm.prank(owner);
        vault.addPayees(id, batch);

        // adding one more should revert
        address[] memory one = new address[](1);
        one[0] = payees[20];
        vm.prank(owner);
        vm.expectRevert(UsdcAllowance.TooManyPayees.selector);
        vault.addPayees(id, one);
    }

    /* ─── already-listed skipped ─── */

    function test_addPayees_already_listed_skipped() public {
        uint256 id = _createAllowlist(0);
        address[] memory p = new address[](1);
        p[0] = payees[0];
        vm.prank(owner);
        vault.addPayees(id, p);
        vm.prank(owner);
        vault.addPayees(id, p); // second add silently skipped
        (address[] memory stored,) = vault.getPayees(id);
        assertEq(stored.length, 1); // still 1
    }

    /* ─── delayed activation ─── */

    function test_addPayees_delayed_activation() public {
        uint256 id = _createAllowlist(DELAY);
        address[] memory p = new address[](1);
        p[0] = payees[0];
        vm.prank(owner);
        vault.addPayees(id, p);

        uint64 activeAt = vault.payeeActiveAt(id, payees[0]);
        assertGt(activeAt, block.timestamp);

        // try to pay before active — should fail
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.PayeeNotAllowed.selector, payees[0]));
        vault.pay(id, payees[0], 1 ether, bytes32(0), "");

        // warp past delay
        vm.warp(activeAt + 1);
        vm.prank(spender);
        vault.pay(id, payees[0], 1 ether, bytes32(0), "after-delay");
    }

    /* ─── initial payees active immediately ─── */

    function test_create_initial_payees_active_immediately() public {
        address[] memory p = new address[](1);
        p[0] = payees[0];
        vm.prank(owner);
        uint256 id = vault.createAllowance{value: 5 ether}(
            spender, _rulesAllowlist(DELAY, true), p, "init"
        );
        // Initial payees: activeAt == block.timestamp (immediately active)
        uint64 active = vault.payeeActiveAt(id, payees[0]);
        assertLe(active, uint64(block.timestamp));
        vm.prank(spender);
        vault.pay(id, payees[0], 1 ether, bytes32(0), "");
    }

    /* ─── removePayees swap-and-pop ─── */

    function test_removePayees_basic() public {
        uint256 id = _createAllowlist(0);
        address[] memory p = new address[](3);
        p[0] = payees[0]; p[1] = payees[1]; p[2] = payees[2];
        vm.prank(owner);
        vault.addPayees(id, p);

        // remove payees[1] (middle)
        address[] memory rem = new address[](1);
        rem[0] = payees[1];
        vm.prank(owner);
        vault.removePayees(id, rem);

        (address[] memory stored,) = vault.getPayees(id);
        assertEq(stored.length, 2);
        // payees[1] should not be in the list
        for (uint256 i = 0; i < stored.length; i++) {
            assertNotEq(stored[i], payees[1]);
        }
        // index cleared
        assertEq(vault.payeeActiveAt(id, payees[1]), 0);
    }

    function test_removePayees_unlisted_ignored() public {
        uint256 id = _createAllowlist(0);
        address[] memory rem = new address[](1);
        rem[0] = payees[0]; // not listed
        vm.prank(owner);
        vault.removePayees(id, rem); // should not revert
    }

    function test_removePayees_cannot_pay_after_removal() public {
        uint256 id = _createAllowlist(0);
        address[] memory p = new address[](1);
        p[0] = payees[0];
        vm.prank(owner);
        vault.addPayees(id, p);

        vm.prank(spender);
        vault.pay(id, payees[0], 1 ether, bytes32(0), "before");

        // remove
        vm.prank(owner);
        vault.removePayees(id, p);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(UsdcAllowance.PayeeNotAllowed.selector, payees[0]));
        vault.pay(id, payees[0], 1 ether, bytes32(uint256(1)), "after");
    }

    function test_removePayees_then_readd() public {
        uint256 id = _createAllowlist(0);
        address[] memory p = new address[](1);
        p[0] = payees[0];
        vm.prank(owner);
        vault.addPayees(id, p);

        vm.prank(owner);
        vault.removePayees(id, p);

        // Re-add
        vm.prank(owner);
        vault.addPayees(id, p);
        (address[] memory stored,) = vault.getPayees(id);
        assertEq(stored.length, 1);
        assertEq(stored[0], payees[0]);
    }

    /* ─── no-allowlist allowance can pay any payee ─── */

    function test_no_allowlist_any_payee_allowed() public {
        uint256 id = _createNoList();
        vm.prank(spender);
        vault.pay(id, payees[0], 1 ether, bytes32(0), "");
        // arbitrary address, not in any list
        assertEq(vault.getAllowance(id).paymentCount, 1);
    }

    /* ─── canPay PayeeNotAllowed ─── */

    function test_canPay_payee_not_allowed() public {
        uint256 id = _createAllowlist(0);
        (bool ok, uint8 reason) = vault.canPay(id, payees[0], 1 ether, bytes32(0));
        assertFalse(ok);
        assertEq(reason, 6);
    }

    /* ─── getPayees consistency with swap-and-pop ─── */

    function test_getPayees_consistent_after_swap_and_pop() public {
        uint256 id = _createAllowlist(0);
        address[] memory p = new address[](4);
        for (uint256 i = 0; i < 4; i++) p[i] = payees[i];
        vm.prank(owner);
        vault.addPayees(id, p);

        // Remove the first one (triggers swap-and-pop with last)
        address[] memory rem = new address[](1);
        rem[0] = payees[0];
        vm.prank(owner);
        vault.removePayees(id, rem);

        (address[] memory stored,) = vault.getPayees(id);
        assertEq(stored.length, 3);

        // Verify index consistency: each remaining payee should be payable
        for (uint256 i = 0; i < stored.length; i++) {
            vm.prank(spender);
            vault.pay(id, stored[i], 1 ether, bytes32(uint256(i + 100)), "");
        }
    }
}
