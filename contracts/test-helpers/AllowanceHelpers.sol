// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UsdcAllowance} from "../UsdcAllowance.sol";

/// @notice Rejects all native-value transfers (simulates a payee that cannot receive USDC).
contract RejectingPayee {
    receive() external payable {
        revert("rejected");
    }
}

/// @notice Accepts native value but then re-enters pay() in the same allowance.
/// The reentrant call should fail due to ReentrancyGuard.
contract ReentrantPayee {
    UsdcAllowance public vault;
    uint256 public targetId;
    address public secondPayee;
    uint256 public amount;
    bool public attacked;
    bool public reentryReverted;

    constructor(UsdcAllowance _vault) {
        vault = _vault;
    }

    function setup(uint256 _id, address _secondPayee, uint256 _amount) external {
        targetId = _id;
        secondPayee = _secondPayee;
        amount = _amount;
    }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            // Attempt reentrant pay — must revert
            try vault.pay(targetId, secondPayee, amount, bytes32(0), "") {
                // Should never reach here
            } catch {
                reentryReverted = true;
            }
        }
    }
}

/// @notice A smart-account spender that can call pay() on the vault, and whose receive() triggers
/// a second pay() to test reentrancy through a spender contract.
contract SpenderSmartAccount {
    UsdcAllowance public vault;
    uint256 public attackId;
    address public attackPayee;
    uint256 public attackAmount;
    bool public attacked;
    bool public reentryReverted;

    constructor(UsdcAllowance _vault) {
        vault = _vault;
    }

    function pay(uint256 id, address payee, uint256 amt, bytes32 ref, string calldata memo) external {
        vault.pay(id, payee, amt, ref, memo);
    }

    function setupAttack(uint256 id, address payee, uint256 amt) external {
        attackId = id;
        attackPayee = payee;
        attackAmount = amt;
    }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            // Attempt reentrant pay through the spender path
            try vault.pay(attackId, attackPayee, attackAmount, bytes32(0), "reentrant") {
                // Should never succeed
            } catch {
                reentryReverted = true;
            }
        }
    }
}

/// @notice An owner that calls revoke() inside receive() — tests reentrancy during withdraw/revoke.
contract ReentrantOwner {
    UsdcAllowance public vault;
    uint256 public targetId;
    bool public attacked;
    bool public reentryReverted;

    constructor(UsdcAllowance _vault) {
        vault = _vault;
    }

    function setup(uint256 id) external {
        targetId = id;
    }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            // Try to revoke again inside the receive — should fail with reentrancy guard
            try vault.revoke(targetId) {
                // Should never reach here
            } catch {
                reentryReverted = true;
            }
        }
    }
}
