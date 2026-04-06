// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ExecutionBoundCaveat } from "../src/ExecutionBoundCaveat.sol";
import { ExecutionIntent, ExecutionIntentLib } from "../src/libs/ExecutionIntentLib.sol";

/// @title EdgeCases
/// @notice Covers boundary conditions and ambiguous execution inputs.
///
/// Cases:
///   - prefix match does not pass (full hash equality required)
///   - zero-length calldata hashes correctly and passes
///   - zero-length calldata mismatch reverts
///   - malformed executionCalldata (too short) reverts in decodeSingle
///   - nonce consumed only after signature verification
///   - different nonces per account are independent
///   - value zero is explicit (not default)

contract EdgeCasesTest is Test {
    using ExecutionIntentLib for ExecutionIntent;

    ExecutionBoundCaveat caveat;

    uint256 signerKey = 0xA11CE;
    address signer;
    address account  = address(0xACC0);
    address target   = address(0xBEEF);
    address redeemer = address(0xCA11);
    bytes32 domainSep;

    function setUp() public {
        vm.warp(1_000_000);
        caveat    = new ExecutionBoundCaveat();
        signer    = vm.addr(signerKey);
        domainSep = caveat.DOMAIN_SEPARATOR();
    }

    function _intent(bytes memory cd, uint256 nonce) internal view returns (ExecutionIntent memory) {
        return ExecutionIntent({
            account:  account,
            target:   target,
            value:    0,
            dataHash: keccak256(cd),
            nonce:    nonce,
            deadline: 0
        });
    }

    function _sign(ExecutionIntent memory intent) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, intent.digest(domainSep));
        return abi.encodePacked(r, s, v);
    }

    function _hook(ExecutionIntent memory intent, bytes memory sig, bytes memory execCalldata) internal {
        caveat.beforeHook(
            "",
            abi.encode(intent, signer, sig),
            bytes32(0),
            execCalldata,
            bytes32(0),
            account,
            redeemer
        );
    }

    // -------------------------------------------------------------------------
    // Prefix match does not pass
    // -------------------------------------------------------------------------

    /// Signing aabbccdd but executing aabbcc (prefix) must revert.
    function test_edge_prefixMatch_reverts() public {
        bytes memory signed  = hex"aabbccdd";
        bytes memory prefix  = hex"aabbcc";

        ExecutionIntent memory intent = _intent(signed, 0);
        bytes memory sig = _sign(intent);

        vm.expectRevert(abi.encodeWithSelector(
            ExecutionBoundCaveat.DataHashMismatch.selector,
            keccak256(signed),
            keccak256(prefix)
        ));
        _hook(intent, sig, ExecutionLib.encodeSingle(target, 0, prefix));
    }

    /// Signing aabbcc but executing aabbccdd (extension) must revert.
    function test_edge_extensionMatch_reverts() public {
        bytes memory signed    = hex"aabbcc";
        bytes memory extended  = hex"aabbccdd";

        ExecutionIntent memory intent = _intent(signed, 0);
        bytes memory sig = _sign(intent);

        vm.expectRevert(abi.encodeWithSelector(
            ExecutionBoundCaveat.DataHashMismatch.selector,
            keccak256(signed),
            keccak256(extended)
        ));
        _hook(intent, sig, ExecutionLib.encodeSingle(target, 0, extended));
    }

    // -------------------------------------------------------------------------
    // Zero-length calldata
    // -------------------------------------------------------------------------

    /// Empty calldata committed and executed — must pass.
    function test_edge_zeroLengthCalldata_passes() public {
        bytes memory empty = hex"";
        ExecutionIntent memory intent = _intent(empty, 0);
        bytes memory sig = _sign(intent);
        _hook(intent, sig, ExecutionLib.encodeSingle(target, 0, empty));
    }

    /// Empty calldata signed but non-empty executed — must revert.
    function test_edge_zeroLengthCalldata_mismatch_reverts() public {
        bytes memory empty   = hex"";
        bytes memory nonEmpty = hex"deadbeef";

        ExecutionIntent memory intent = _intent(empty, 0);
        bytes memory sig = _sign(intent);

        vm.expectRevert(abi.encodeWithSelector(
            ExecutionBoundCaveat.DataHashMismatch.selector,
            keccak256(empty),
            keccak256(nonEmpty)
        ));
        _hook(intent, sig, ExecutionLib.encodeSingle(target, 0, nonEmpty));
    }

    // -------------------------------------------------------------------------
    // Malformed executionCalldata
    // -------------------------------------------------------------------------

    /// executionCalldata shorter than 52 bytes — decodeSingle reads past bounds.
    /// Forge catches this as an EVM revert.
    function test_edge_malformedCalldata_reverts() public {
        bytes memory cd = hex"deadbeef";
        ExecutionIntent memory intent = _intent(cd, 0);
        bytes memory sig = _sign(intent);

        // Only 10 bytes — too short for decodeSingle (needs >= 52)
        bytes memory malformed = hex"00000000000000000000";

        vm.expectRevert();
        _hook(intent, sig, malformed);
    }

    // -------------------------------------------------------------------------
    // Nonce consumed only after signature verification
    // -------------------------------------------------------------------------

    /// Invalid signature must not consume nonce.
    /// After failed attempt, valid attempt with same nonce must succeed.
    function test_edge_invalidSig_doesNotConsumeNonce() public {
        bytes memory cd = hex"facade";
        ExecutionIntent memory intent = _intent(cd, 99);

        // Bad signature
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBADBAD, intent.digest(domainSep));
        bytes memory badSig = abi.encodePacked(r, s, v);

        // First attempt: invalid sig → revert, nonce NOT consumed
        vm.expectRevert(ExecutionBoundCaveat.InvalidSignature.selector);
        _hook(intent, badSig, ExecutionLib.encodeSingle(target, 0, cd));

        assertFalse(caveat.isNonceUsed(account, signer, 99));

        // Second attempt: valid sig → succeeds, nonce consumed
        bytes memory goodSig = _sign(intent);
        _hook(intent, goodSig, ExecutionLib.encodeSingle(target, 0, cd));

        assertTrue(caveat.isNonceUsed(account, signer, 99));
    }

    // -------------------------------------------------------------------------
    // Nonces are independent per account
    // -------------------------------------------------------------------------

    /// Same signer, same nonce, different accounts — independent state.
    function test_edge_nonceScopedByAccount() public {
        address account2 = address(0xACC1);
        bytes memory cd  = hex"11223344";

        // Intent for account
        ExecutionIntent memory intent1 = ExecutionIntent({
            account: account, target: target, value: 0,
            dataHash: keccak256(cd), nonce: 0, deadline: 0
        });

        // Intent for account2
        ExecutionIntent memory intent2 = ExecutionIntent({
            account: account2, target: target, value: 0,
            dataHash: keccak256(cd), nonce: 0, deadline: 0
        });

        bytes memory sig1 = _sign(intent1);
        bytes memory sig2 = _sign(intent2);

        // Redeem for account
        caveat.beforeHook("", abi.encode(intent1, signer, sig1), bytes32(0),
            ExecutionLib.encodeSingle(target, 0, cd), bytes32(0), account, redeemer);

        // Nonce used for account but not account2
        assertTrue(caveat.isNonceUsed(account, signer, 0));
        assertFalse(caveat.isNonceUsed(account2, signer, 0));

        // Redeem for account2 — same nonce, different account, must succeed
        caveat.beforeHook("", abi.encode(intent2, signer, sig2), bytes32(0),
            ExecutionLib.encodeSingle(target, 0, cd), bytes32(0), account2, redeemer);

        assertTrue(caveat.isNonceUsed(account2, signer, 0));
    }

    // -------------------------------------------------------------------------
    // Explicit zero value
    // -------------------------------------------------------------------------

    /// value = 0 in intent must match value = 0 in execution explicitly.
    function test_edge_zeroValue_explicit() public {
        bytes memory cd = hex"aabb";
        ExecutionIntent memory intent = _intent(cd, 0);
        bytes memory sig = _sign(intent);

        // Execution sends 1 wei — must revert even though value is "small"
        vm.expectRevert(abi.encodeWithSelector(
            ExecutionBoundCaveat.ValueMismatch.selector,
            0,
            1
        ));
        _hook(intent, sig, ExecutionLib.encodeSingle(target, 1, cd));
    }
}
