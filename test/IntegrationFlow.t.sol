// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { ExecutionBoundCaveat } from "../src/ExecutionBoundCaveat.sol";
import { ExecutionIntent, ExecutionIntentLib } from "../src/libs/ExecutionIntentLib.sol";
import { DemoTarget } from "../src/DemoTarget.sol";

contract IntegrationFlowTest is Test {
    using ExecutionIntentLib for ExecutionIntent;

    ExecutionBoundCaveat caveat;
    DemoTarget           target;

    uint256 signerKey  = 0xA11CE;
    address signer;
    address delegator  = address(0xDE1E);
    address redeemer   = address(0xBEEF);
    bytes32 domainSep;

    function setUp() public {
        vm.warp(1_000_000);
        caveat    = new ExecutionBoundCaveat();
        target    = new DemoTarget();
        signer    = vm.addr(signerKey);
        domainSep = caveat.DOMAIN_SEPARATOR();
    }

    function _sign(ExecutionIntent memory intent) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, intent.digest(domainSep));
        return abi.encodePacked(r, s, v);
    }

    function _intent(bytes memory cd, uint256 nonce) internal view returns (ExecutionIntent memory) {
        return ExecutionIntent({
            account:  delegator,
            target:   address(target),
            value:    0,
            dataHash: keccak256(cd),
            nonce:    nonce,
            deadline: 0
        });
    }

    function _redeem(ExecutionIntent memory intent, bytes memory sig, bytes memory execCalldata) internal {
        caveat.beforeHook(
            "",
            abi.encode(intent, signer, sig),
            bytes32(0),
            execCalldata,
            bytes32(0),
            delegator,
            redeemer
        );
    }

    function test_integration_exactExecution_passes() public {
        bytes memory cd = abi.encodeWithSignature("setValue(uint256)", 42);
        ExecutionIntent memory intent = _intent(cd, 0);

        console.log("=== Case 1: Exact Execution ===");
        _redeem(intent, _sign(intent), ExecutionLib.encodeSingle(address(target), 0, cd));
        vm.prank(delegator);
        (bool ok,) = address(target).call(cd);
        assertTrue(ok);
        assertEq(target.value(), 42);
        console.log("SUCCESS: target.value() ==", target.value());
    }

    function test_integration_mutatedExecution_reverts() public {
        bytes memory signedCd  = abi.encodeWithSignature("setValue(uint256)", 42);
        bytes memory mutatedCd = abi.encodeWithSignature("setValue(uint256)", 999);
        ExecutionIntent memory intent = _intent(signedCd, 0);

        console.log("=== Case 2: Mutated Execution ===");

        vm.expectRevert(abi.encodeWithSelector(
            ExecutionBoundCaveat.DataHashMismatch.selector,
            keccak256(signedCd),
            keccak256(mutatedCd)
        ));

        _redeem(intent, _sign(intent), ExecutionLib.encodeSingle(address(target), 0, mutatedCd));
        console.log("REVERTED: DataHashMismatch as expected.");
    }

    function test_integration_wrongAccount_reverts() public {
        bytes memory cd = abi.encodeWithSignature("setValue(uint256)", 42);
        ExecutionIntent memory intent = _intent(cd, 0);
        address wrongDelegator = address(0xBAD);

        console.log("=== Case 3: Wrong Account ===");

        vm.expectRevert(abi.encodeWithSelector(
            ExecutionBoundCaveat.AccountMismatch.selector,
            delegator,
            wrongDelegator
        ));

        caveat.beforeHook("", abi.encode(intent, signer, _sign(intent)), bytes32(0),
            ExecutionLib.encodeSingle(address(target), 0, cd), bytes32(0), wrongDelegator, redeemer);
        console.log("REVERTED: AccountMismatch as expected.");
    }

    function test_integration_fullHappyPath() public {
        bytes memory cd = abi.encodeWithSignature("setValue(uint256)", 100);
        ExecutionIntent memory intent = _intent(cd, 42);

        console.log("=== Case 4: Full Happy Path ===");
        assertFalse(caveat.isNonceUsed(delegator, signer, 42));

        _redeem(intent, _sign(intent), ExecutionLib.encodeSingle(address(target), 0, cd));

        assertTrue(caveat.isNonceUsed(delegator, signer, 42));
        console.log("Nonce 42 consumed.");

        vm.expectRevert(abi.encodeWithSelector(
            ExecutionBoundCaveat.NonceAlreadyUsed.selector, delegator, signer, 42));
        _redeem(intent, _sign(intent), ExecutionLib.encodeSingle(address(target), 0, cd));
        console.log("Replay blocked.");

        vm.prank(delegator);
        (bool ok,) = address(target).call(cd);
        assertTrue(ok);
        assertEq(target.value(), 100);
        console.log("SUCCESS: target.value() ==", target.value());
    }

    function test_integration_delegatecall_rejected() public {
        bytes memory cd = abi.encodeWithSignature("setValue(uint256)", 42);
        ExecutionIntent memory intent = _intent(cd, 0);
        bytes32 delegatecallMode = bytes32(uint256(0xFF) << 248);

        console.log("=== Case 5: Delegatecall Rejected ===");

        vm.expectRevert(ExecutionBoundCaveat.UnsupportedCallType.selector);

        caveat.beforeHook("", abi.encode(intent, signer, _sign(intent)), delegatecallMode,
            ExecutionLib.encodeSingle(address(target), 0, cd), bytes32(0), delegator, redeemer);
        console.log("REVERTED: UnsupportedCallType.");
    }
}
