// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ExecutionBoundCaveat } from "../src/ExecutionBoundCaveat.sol";
import { ExecutionIntent, ExecutionIntentLib } from "../src/libs/ExecutionIntentLib.sol";

/// @title DelegatecallEdgeCases
/// @notice Proves that ExecutionBoundCaveat enforces single-call mode only.
///
/// Policy: this primitive supports only CALLTYPE_SINGLE (0x00 first byte of ModeCode).
/// Delegatecall, batch, static, and any unknown call types are rejected.
///
/// Reasoning:
///   Under delegatecall, intent.target means "run this code in my account's storage context"
///   rather than "call this contract." The signer's expectation of what target means breaks.
///   The primitive cannot guarantee execution equality semantics across this context shift.
///   Therefore all non-single call types are rejected at the enforcement boundary.

contract DelegatecallEdgeCasesTest is Test {
    using ExecutionIntentLib for ExecutionIntent;

    ExecutionBoundCaveat caveat;

    uint256 signerKey = 0xA11CE;
    address signer;
    address account  = address(0xACC0);
    address target   = address(0xBEEF);
    address redeemer = address(0xCA11);
    bytes32 domainSep;

    // ModeCode first byte constants (from ERC-7579 ModeLib)
    bytes32 constant MODE_SINGLE      = bytes32(0); // CALLTYPE_SINGLE = 0x00
    bytes32 constant MODE_BATCH       = bytes32(uint256(0x01) << 248);
    bytes32 constant MODE_STATIC      = bytes32(uint256(0xFE) << 248);
    bytes32 constant MODE_DELEGATECALL = bytes32(uint256(0xFF) << 248);

    function setUp() public {
        vm.warp(1_000_000);
        caveat    = new ExecutionBoundCaveat();
        signer    = vm.addr(signerKey);
        domainSep = caveat.DOMAIN_SEPARATOR();
    }

    function _intent(bytes memory cd) internal view returns (ExecutionIntent memory) {
        return ExecutionIntent({
            account:  account,
            target:   target,
            value:    0,
            dataHash: keccak256(cd),
            nonce:    0,
            deadline: 0
        });
    }

    function _sign(ExecutionIntent memory intent) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, intent.digest(domainSep));
        return abi.encodePacked(r, s, v);
    }

    function _hook(bytes32 mode, bytes memory cd) internal {
        ExecutionIntent memory intent = _intent(cd);
        bytes memory sig = _sign(intent);
        caveat.beforeHook(
            "",
            abi.encode(intent, signer, sig),
            mode,
            ExecutionLib.encodeSingle(target, 0, cd),
            bytes32(0),
            account,
            redeemer
        );
    }

    // -------------------------------------------------------------------------
    // Single-call mode passes
    // -------------------------------------------------------------------------

    /// CALLTYPE_SINGLE (0x00) is the only supported mode.
    function test_calltype_single_passes() public {
        _hook(MODE_SINGLE, hex"aabbccdd");
    }

    // -------------------------------------------------------------------------
    // All non-single modes revert
    // -------------------------------------------------------------------------

    /// CALLTYPE_DELEGATECALL (0xFF) must revert.
    /// Delegatecall changes execution context — target semantics break.
    function test_calltype_delegatecall_reverts() public {
        vm.expectRevert(ExecutionBoundCaveat.UnsupportedCallType.selector);
        _hook(MODE_DELEGATECALL, hex"aabbccdd");
    }

    /// CALLTYPE_BATCH (0x01) must revert.
    /// This primitive is defined over single-call execution only.
    function test_calltype_batch_reverts() public {
        vm.expectRevert(ExecutionBoundCaveat.UnsupportedCallType.selector);
        _hook(MODE_BATCH, hex"aabbccdd");
    }

    /// CALLTYPE_STATIC (0xFE) must revert.
    function test_calltype_static_reverts() public {
        vm.expectRevert(ExecutionBoundCaveat.UnsupportedCallType.selector);
        _hook(MODE_STATIC, hex"aabbccdd");
    }

    /// Unknown future call types must revert.
    function test_calltype_unknown_reverts() public {
        bytes32 unknownMode = bytes32(uint256(0xAB) << 248);
        vm.expectRevert(ExecutionBoundCaveat.UnsupportedCallType.selector);
        _hook(unknownMode, hex"aabbccdd");
    }
}
