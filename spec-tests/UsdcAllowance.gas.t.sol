// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {UsdcAllowance} from "../src/UsdcAllowance.sol";

/// @dev Execution gas of the demo calls (forge test --match-contract UsdcAllowanceGas -vv). A real tx adds 21,000 +
///      calldata (+25,000 when value lands on a fresh account).
contract UsdcAllowanceGas is Test {
    function test_gas_demoCalls() public {
        vm.warp(1_760_000_000);
        UsdcAllowance c = new UsdcAllowance();
        address owner = makeAddr("owner");
        address agent = makeAddr("agent");
        address api = makeAddr("api");
        vm.deal(owner, 10 ether);
        address[] memory ps = new address[](1);
        ps[0] = api;
        UsdcAllowance.Rules memory r = UsdcAllowance.Rules(0.10e18, 0.15e18, 300, uint64(block.timestamp),
            uint64(block.timestamp + 7 days), 120, true);
        uint256 g = gasleft();
        vm.prank(owner);
        uint256 id = c.createAllowance{value: 0.30e18}(agent, r, ps, "research-agent -> data APIs");
        console.log("createAllowance (1 payee, funded, 26-byte label)", g - gasleft());
        g = gasleft();
        vm.prank(agent);
        c.pay(id, api, 0.05e18, keccak256("req-1"), "GET /v1/prices?symbol=ETH (req-1)");
        console.log("pay #1 (ref, 34-byte memo; cold payee)", g - gasleft());
        g = gasleft();
        vm.prank(agent);
        c.pay(id, api, 0.05e18, keccak256("req-2"), "GET /v1/prices?symbol=BTC (req-2)");
        console.log("pay #2", g - gasleft());
        g = gasleft();
        vm.prank(agent);
        try c.pay(id, api, 0.10e18, keccak256("req-4"), "over the daily cap") {} catch {}
        console.log("pay rejected (ExceedsPeriodCap)", g - gasleft());
        g = gasleft();
        vm.prank(owner);
        c.setLimits(id, 0.10e18, 0.20e18, uint64(block.timestamp + 7 days));
        console.log("setLimits (loosen -> pending)", g - gasleft());
        address[] memory more = new address[](1);
        more[0] = makeAddr("api2");
        g = gasleft();
        vm.prank(owner);
        c.addPayees(id, more);
        console.log("addPayees (1)", g - gasleft());
        g = gasleft();
        vm.prank(owner);
        c.pause(id);
        console.log("pause", g - gasleft());
        g = gasleft();
        vm.prank(owner);
        c.revoke(id);
        console.log("revoke (refund to owner)", g - gasleft());
    }
}
