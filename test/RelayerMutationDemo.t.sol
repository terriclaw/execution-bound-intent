// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ExecutionBoundCaveat } from "../src/ExecutionBoundCaveat.sol";
import { ExecutionIntent, ExecutionIntentLib } from "../src/libs/ExecutionIntentLib.sol";

/// @notice Minimal reproduction of AllowedMethodsEnforcer - checks selector only.
contract AllowedMethodsEnforcer {
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        bytes32,
        bytes calldata _executionCalldata,
        bytes32,
        address,
        address
    ) external pure {
        (, , bytes memory callData) = ExecutionLib.decodeSingle(_executionCalldata);
        require(callData.length >= 4, "invalid calldata");
        bytes4 selector;
        assembly { selector := mload(add(callData, 32)) }
        bytes4 allowed = bytes4(_terms[0:4]);
        require(selector == allowed, "method not allowed");
    }
}

/// @title RelayerMutationDemo
///
/// @notice Demonstrates the attack that execution-bound-intent prevents.
///
/// Scenario:
///   Alice (delegator) wants to transfer 100 USDC to Bob.
///   She delegates to a relayer with an AllowedMethods caveat allowing transfer().
///   The relayer mutates the calldata: changes recipient to Eve, amount to 1000 USDC.
///   AllowedMethodsEnforcer passes (selector is still transfer()).
///   ExecutionBoundCaveat reverts (dataHash does not match).

contract RelayerMutationDemo is Test {
    using ExecutionIntentLib for ExecutionIntent;

    AllowedMethodsEnforcer allowedMethods;
    ExecutionBoundCaveat   boundCaveat;

    address alice    = address(0xA11CE);
    address bob      = address(0xB0B);
    address eve      = address(0xEEEE);
    address token    = address(0x1234);
    address redeemer = address(0xCA11);

    uint256 signerKey = 0xA11CE;
    address signer;
    bytes32 domainSep;

    bytes4 constant TRANSFER_SELECTOR = bytes4(keccak256("transfer(address,uint256)"));

    function setUp() public {
        vm.warp(1_000_000);
        allowedMethods = new AllowedMethodsEnforcer();
        boundCaveat    = new ExecutionBoundCaveat();
        signer         = vm.addr(signerKey);
        domainSep      = boundCaveat.DOMAIN_SEPARATOR();
    }

    /// @notice AllowedMethodsEnforcer passes even when the relayer mutates
    ///         recipient and amount. The selector check is insufficient.
    function test_policyEnforcer_allowsRelayerMutation() public view {
        // Relayer mutates: transfer(eve, 1000e6) instead of transfer(bob, 100e6)
        bytes memory mutatedCalldata = abi.encodeWithSelector(TRANSFER_SELECTOR, eve, 1000e6);
        bytes memory terms = abi.encodePacked(TRANSFER_SELECTOR);

        // Policy enforcer sees only the selector - passes on mutated calldata
        allowedMethods.beforeHook(
            terms,
            "",
            bytes32(0),
            ExecutionLib.encodeSingle(token, 0, mutatedCalldata),
            bytes32(0),
            alice,
            redeemer
        );

        // Mutation went undetected - transfer(eve, 1000e6) would execute
    }

    /// @notice ExecutionBoundCaveat reverts on the same mutation.
    ///         The signed commitment binds exact calldata - any change is caught.
    function test_executionBoundCaveat_blocksRelayerMutation() public {
        // Alice signed: transfer(bob, 100e6)
        bytes memory signedCalldata = abi.encodeWithSelector(TRANSFER_SELECTOR, bob, 100e6);

        ExecutionIntent memory intent = ExecutionIntent({
            account:  alice,
            target:   token,
            value:    0,
            dataHash: keccak256(signedCalldata),
            nonce:    0,
            deadline: 0
        });

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, intent.digest(domainSep));
        bytes memory signature = abi.encodePacked(r, s, v);

        // Relayer mutates: transfer(eve, 1000e6)
        bytes memory mutatedCalldata = abi.encodeWithSelector(TRANSFER_SELECTOR, eve, 1000e6);

        // ExecutionBoundCaveat catches the mutation - DataHashMismatch
        vm.expectRevert(abi.encodeWithSelector(
            ExecutionBoundCaveat.DataHashMismatch.selector,
            keccak256(signedCalldata),
            keccak256(mutatedCalldata)
        ));

        boundCaveat.beforeHook(
            "",
            abi.encode(intent, signer, signature),
            bytes32(0),
            ExecutionLib.encodeSingle(token, 0, mutatedCalldata),
            bytes32(0),
            alice,
            redeemer
        );
    }

    /// @notice Exact calldata passes.
    function test_executionBoundCaveat_passesExactCalldata() public {
        bytes memory calldata_ = abi.encodeWithSelector(TRANSFER_SELECTOR, bob, 100e6);

        ExecutionIntent memory intent = ExecutionIntent({
            account:  alice,
            target:   token,
            value:    0,
            dataHash: keccak256(calldata_),
            nonce:    0,
            deadline: 0
        });

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, intent.digest(domainSep));
        bytes memory signature = abi.encodePacked(r, s, v);

        boundCaveat.beforeHook(
            "",
            abi.encode(intent, signer, signature),
            bytes32(0),
            ExecutionLib.encodeSingle(token, 0, calldata_),
            bytes32(0),
            alice,
            redeemer
        );
    }
}
