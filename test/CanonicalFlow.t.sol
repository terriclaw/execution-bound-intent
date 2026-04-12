// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { ExecutionBoundCaveat } from "../src/ExecutionBoundCaveat.sol";
import { ExecutionIntent, ExecutionIntentLib } from "../src/libs/ExecutionIntentLib.sol";
import { DemoTarget } from "../src/DemoTarget.sol";

/// @title CanonicalFlow
/// @notice The intended usage path for ExecutionBoundCaveat.
///
/// Start here. This shows how the primitive works without framework complexity.
///
/// The flow:
///   1. Build an ExecutionIntent committing to exact execution
///   2. Sign it (EIP-712)
///   3. Call beforeHook — enforcement checks exact equality
///   4. Execute the matching calldata
///   5. State changes as expected
///
/// For proof that this survives the real MetaMask delegation stack,
/// see test/Flowwire7710.t.sol.

contract CanonicalFlowTest is Test {
    using ExecutionIntentLib for ExecutionIntent;

    ExecutionBoundCaveat caveat;
    DemoTarget           target;

    uint256 signerKey = 0xA11CE;
    address signer;
    address delegator;
    address redeemer;

    bytes32 caveatDomainSep;

    function setUp() public {
        caveat    = new ExecutionBoundCaveat();
        target    = new DemoTarget();
        signer    = vm.addr(signerKey);
        delegator = makeAddr("delegator");
        redeemer  = makeAddr("redeemer");
        caveatDomainSep = caveat.DOMAIN_SEPARATOR();
    }

    // -------------------------------------------------------------------------
    // Step 1: helpers
    // -------------------------------------------------------------------------

    function _calldata() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("setValue(uint256)", 42);
    }

    function _buildIntent(uint256 nonce_) internal view returns (ExecutionIntent memory) {
        return ExecutionIntent({
            account:  delegator,
            target:   address(target),
            value:    0,
            dataHash: keccak256(_calldata()),
            nonce:    nonce_,
            deadline: 0
        });
    }

    function _sign(ExecutionIntent memory intent_) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, intent_.digest(caveatDomainSep));
        return abi.encodePacked(r, s, v);
    }

    function _args(ExecutionIntent memory intent_) internal view returns (bytes memory) {
        return abi.encode(intent_, signer, _sign(intent_));
    }

    function _execCalldata() internal view returns (bytes memory) {
        return ExecutionLib.encodeSingle(address(target), 0, _calldata());
    }

    // -------------------------------------------------------------------------
    // Canonical happy path
    // -------------------------------------------------------------------------
    function test_canonical_exactExecution_succeeds() public {
        console.log("============================================================");
        console.log("Canonical ExecutionBoundCaveat Flow");
        console.log("============================================================");

        // Step 1: build the commitment
        ExecutionIntent memory intent = _buildIntent(0);
        console.log("Step 1: ExecutionIntent built");
        console.log("  account: ", intent.account);
        console.log("  target:  ", intent.target);
        console.log("  nonce:   ", intent.nonce);

        // Step 2: sign it
        bytes memory args = _args(intent);
        console.log("Step 2: Signed via EIP-712");

        // Step 3: enforce — beforeHook checks exact equality
        bytes32 singleMode = bytes32(0);
        vm.prank(delegator); // msg.sender scopes the nonce
        caveat.beforeHook(hex"", args, singleMode, _execCalldata(), bytes32(0), delegator, redeemer);
        console.log("Step 3: beforeHook passed - exact equality enforced");

        // Step 4: execute matching calldata
        (bool ok,) = address(target).call(_calldata());
        assertTrue(ok);
        console.log("Step 4: Execution succeeded");

        // Step 5: verify state
        assertEq(target.value(), 42);
        console.log("Step 5: target.value() ==", target.value());
        console.log("============================================================");
        console.log("Result: SUCCESS");
    }

    // -------------------------------------------------------------------------
    // Mismatch case — shows why exactness matters
    // -------------------------------------------------------------------------
    function test_canonical_mutatedCalldata_reverts() public {
        console.log("============================================================");
        console.log("Mismatch: mutated calldata reverts");
        console.log("============================================================");

        // Intent commits to setValue(42)
        ExecutionIntent memory intent = _buildIntent(0);
        bytes memory args = _args(intent);

        // Redeemer submits setValue(999) instead
        bytes memory mutatedCalldata = ExecutionLib.encodeSingle(
            address(target), 0, abi.encodeWithSignature("setValue(uint256)", 999)
        );

        bytes32 singleMode = bytes32(0);
        vm.prank(delegator);
        vm.expectRevert(abi.encodeWithSelector(
            ExecutionBoundCaveat.DataHashMismatch.selector,
            keccak256(_calldata()),
            keccak256(abi.encodeWithSignature("setValue(uint256)", 999))
        ));
        caveat.beforeHook(hex"", args, singleMode, mutatedCalldata, bytes32(0), delegator, redeemer);

        assertEq(target.value(), 0);
        console.log("Result: REVERTED (DataHashMismatch)");
        console.log("Mutated calldata cannot satisfy the signed commitment.");
    }
}
