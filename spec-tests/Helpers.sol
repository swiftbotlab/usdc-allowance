// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UsdcAllowance} from "../src/UsdcAllowance.sol";

/// @dev A payee/owner that cannot receive native USDC.
contract RejectingReceiver {
    receive() external payable {
        revert("no thanks");
    }
}

/// @dev An OWNER contract that is also an allowlisted payee. When paid, it tries to revoke the allowance from inside
///      the payment (reentrancy). bubble=true: the inner revert bubbles (pay must revert TransferFailed);
///      bubble=false: the inner revert is swallowed (the payment must complete, the allowance must NOT be revoked).
contract ReentrantOwner {
    UsdcAllowance public immutable allowance;
    uint256 public id;
    bool public bubble;
    bool public innerFailed;
    uint256 public received;

    constructor(UsdcAllowance a) {
        allowance = a;
    }

    function create(address spender, UsdcAllowance.Rules calldata rules, address[] calldata payees)
        external
        payable
        returns (uint256)
    {
        id = allowance.createAllowance{value: msg.value}(spender, rules, payees, "reentrant-owner");
        return id;
    }

    function setBubble(bool b) external {
        bubble = b;
    }

    function revokeNow() external {
        allowance.revoke(id);
    }

    receive() external payable {
        received += msg.value;
        if (msg.sender != address(allowance) || allowance.getAllowance(id).revoked) return;
        if (bubble) {
            allowance.revoke(id);
        } else {
            try allowance.revoke(id) {}
            catch {
                innerFailed = true;
            }
        }
    }
}

/// @dev A SPENDER contract (an agent's smart account). The malicious payee below calls back into it while being paid.
contract SpenderAccount {
    UsdcAllowance public immutable allowance;
    uint256 public lastId;
    address public lastPayee;

    constructor(UsdcAllowance a) {
        allowance = a;
    }

    function pay(uint256 id, address payee, uint256 amount, bytes32 ref) external {
        lastId = id;
        lastPayee = payee;
        allowance.pay(id, payee, amount, ref, "via smart account");
    }

    /// @dev Called by the payee during the transfer: tries a second payment (must hit the reentrancy guard).
    function payAgain(uint256 amount) external {
        allowance.pay(lastId, lastPayee, amount, bytes32(0), "reentered");
    }
}

/// @dev A payee that, when paid, makes the spender account pay it again (double-dip attempt through reentrancy).
contract GreedyPayee {
    SpenderAccount public account;
    bool public swallow;
    bool public innerFailed;
    uint256 public received;

    function setAccount(SpenderAccount s, bool swallow_) external {
        account = s;
        swallow = swallow_;
    }

    receive() external payable {
        received += msg.value;
        if (address(account) == address(0)) return;
        SpenderAccount s = account;
        account = SpenderAccount(payable(address(0))); // one attempt only
        if (swallow) {
            try s.payAgain(msg.value) {}
            catch {
                innerFailed = true;
            }
        } else {
            s.payAgain(msg.value);
        }
    }
}
