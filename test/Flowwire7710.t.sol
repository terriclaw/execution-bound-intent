// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { DelegationManager } from "@delegation-framework/DelegationManager.sol";
import { HybridDeleGator } from "@delegation-framework/HybridDeleGator.sol";
import { DeleGatorCore } from "@delegation-framework/DeleGatorCore.sol";
import { EncoderLib } from "@delegation-framework/libraries/EncoderLib.sol";
import { P256SCLVerifierLib } from "@delegation-framework/libraries/P256SCLVerifierLib.sol";
import { Delegation, Caveat, ModeCode } from "@delegation-framework/utils/Types.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";

import { ExecutionBoundCaveat } from "../src/ExecutionBoundCaveat.sol";
import { ExecutionIntent, ExecutionIntentLib } from "../src/libs/ExecutionIntentLib.sol";
import { DemoTarget } from "../src/DemoTarget.sol";

/// @title Flowwire7710Test
/// @notice Full ERC-7710 flowwire integration test for ExecutionBoundCaveat.
///
/// Architecture:
///   - Delegator: HybridDeleGator (ERC-1271 smart account, signs delegation)
///   - Redeemer:  plain EOA (calls DelegationManager.redeemDelegations directly)
///   - Caveat:    ExecutionBoundCaveat (beforeHook called by DelegationManager)
///   - Target:    DemoTarget (setValue, easy state verification)
///
/// Two signatures — keep them conceptually separate:
///   [1] Delegation signature: delegator signs the delegation using DelegationManager's EIP-712 domain
///   [2] ExecutionIntent signature: signer signs the intent using ExecutionBoundCaveat's EIP-712 domain
///
/// The redeemer sets caveat.args at redemption time (args is excluded from delegation hash by design).
///
/// Flow:
///   1. Deploy stack (DelegationManager, HybridDeleGator, caveat, target)
///   2. Build delegation with ExecutionBoundCaveat attached
///   3. Delegator signs delegation  [Signature 1]
///   4. Signer signs ExecutionIntent [Signature 2]
///   5. Redeemer fills args with (intent, signer, sig2) and calls redeemDelegations
///   6. DelegationManager validates delegation sig, calls beforeHook, calls executeFromExecutor
///   7. Assert state / revert

contract Flowwire7710Test is Test {
    using ExecutionIntentLib for ExecutionIntent;
    using MessageHashUtils for bytes32;

    // -------------------------------------------------------------------------
    // Stack
    // -------------------------------------------------------------------------

    DelegationManager     delegationManager;
    HybridDeleGator       delegatorImpl;
    HybridDeleGator       delegatorAccount; // proxy
    ExecutionBoundCaveat  caveat;
    DemoTarget            demoTarget;

    // Stub EntryPoint — HybridDeleGator needs one but we won't use ERC-4337
    IEntryPoint           entryPoint;

    // -------------------------------------------------------------------------
    // Keys and addresses
    // -------------------------------------------------------------------------

    // Delegator: owns the HybridDeleGator smart account
    uint256 delegatorKey  = 0xDE1E6A70;
    address delegatorEOA;

    // Redeemer: plain EOA that calls redeemDelegations
    uint256 redeemerKey   = 0xBEEFCAFE;
    address redeemer;

    // Signer: signs the ExecutionIntent (may differ from delegator)
    uint256 signerKey     = 0xA11CE;
    address signer;

    bytes32 ROOT_AUTHORITY;
    bytes32 caveatDomainSep;
    bytes32 delegationDomainSep;

    ModeCode singleMode;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        vm.warp(1_000_000);

        // Etch P256 verifier required by HybridDeleGator
        vm.etch(P256SCLVerifierLib.VERIFIER, hex"00");

        // Deploy a stub entrypoint (address only, no logic needed for direct calls)
        entryPoint = IEntryPoint(makeAddr("EntryPoint"));

        // Deploy DelegationManager
        delegationManager = new DelegationManager(makeAddr("owner"));
        ROOT_AUTHORITY    = delegationManager.ROOT_AUTHORITY();
        delegationDomainSep = delegationManager.getDomainHash();

        // Deploy HybridDeleGator implementation
        delegatorImpl = new HybridDeleGator(delegationManager, entryPoint);

        // Deploy delegator proxy — owner is delegatorEOA
        delegatorEOA = vm.addr(delegatorKey);
        string[] memory keyIds = new string[](0);
        uint256[] memory xs    = new uint256[](0);
        uint256[] memory ys    = new uint256[](0);
        delegatorAccount = HybridDeleGator(payable(address(
            new ERC1967Proxy(
                address(delegatorImpl),
                abi.encodeWithSignature(
                    "initialize(address,string[],uint256[],uint256[])",
                    delegatorEOA, keyIds, xs, ys
                )
            )
        )));
        vm.deal(address(delegatorAccount), 10 ether);

        // Deploy caveat and target
        caveat    = new ExecutionBoundCaveat();
        demoTarget = new DemoTarget();

        // Keys
        redeemer = vm.addr(redeemerKey);
        signer   = vm.addr(signerKey);

        caveatDomainSep = caveat.DOMAIN_SEPARATOR();
        singleMode = ModeLib.encodeSimpleSingle();
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @notice Sign a delegation using DelegationManager's EIP-712 domain.
    /// [Signature 1]
    function _signDelegation(Delegation memory delegation) internal view returns (Delegation memory) {
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);
        bytes32 typedDataHash  = MessageHashUtils.toTypedDataHash(delegationDomainSep, delegationHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegatorKey, typedDataHash);
        delegation.signature = abi.encodePacked(r, s, v);
        return delegation;
    }

    /// @notice Sign an ExecutionIntent using ExecutionBoundCaveat's EIP-712 domain.
    /// [Signature 2]
    function _signIntent(ExecutionIntent memory intent) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, intent.digest(caveatDomainSep));
        return abi.encodePacked(r, s, v);
    }

    /// @notice Build a delegation with ExecutionBoundCaveat attached.
    /// args is left empty — redeemer fills it at redemption time.
    function _buildDelegation() internal view returns (Delegation memory) {
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({
            enforcer: address(caveat),
            terms:    hex"",   // unused in v1
            args:     hex""    // filled by redeemer at redemption time
        });

        return Delegation({
            delegate:  redeemer,
            delegator: address(delegatorAccount),
            authority: ROOT_AUTHORITY,
            caveats:   caveats,
            salt:      0,
            signature: hex""
        });
    }

    /// @notice Execute a redemption through DelegationManager.
    /// Redeemer fills in args with the signed intent.
    function _redeem(
        Delegation memory delegation,
        bytes memory intentArgs,
        bytes memory execCalldata
    ) internal {
        // Redeemer sets args at redemption time (excluded from delegation hash)
        delegation.caveats[0].args = intentArgs;

        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegations);

        ModeCode[] memory modes = new ModeCode[](1);
        modes[0] = singleMode;

        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] = execCalldata;

        vm.prank(redeemer);
        delegationManager.redeemDelegations(permissionContexts, modes, executionCallDatas);
    }

    // -------------------------------------------------------------------------
    // Case 1: Exact execution passes
    // -------------------------------------------------------------------------

    function test_flowwire_exactExecution_passes() public {
        bytes memory cd = abi.encodeWithSignature("setValue(uint256)", 42);

        // [Signature 1] Delegator signs delegation
        Delegation memory delegation = _signDelegation(_buildDelegation());

        // [Signature 2] Signer signs ExecutionIntent
        ExecutionIntent memory intent = ExecutionIntent({
            account:  address(delegatorAccount),
            target:   address(demoTarget),
            value:    0,
            dataHash: keccak256(cd),
            nonce:    0,
            deadline: 0
        });
        bytes memory intentSig = _signIntent(intent);
        bytes memory intentArgs = abi.encode(intent, signer, intentSig);

        console.log("=== Flowwire Case 1: Exact Execution ===");
        console.log("delegator:  ", address(delegatorAccount));
        console.log("redeemer:   ", redeemer);
        console.log("signer:     ", signer);
        console.log("target:     ", address(demoTarget));

        assertEq(demoTarget.value(), 0);

        _redeem(delegation, intentArgs, ExecutionLib.encodeSingle(address(demoTarget), 0, cd));

        assertEq(demoTarget.value(), 42);
        console.log("SUCCESS: demoTarget.value() ==", demoTarget.value());
    }

    // -------------------------------------------------------------------------
    // Case 2: Mutated execution reverts
    // -------------------------------------------------------------------------

    function test_flowwire_mutatedExecution_reverts() public {
        bytes memory signedCd  = abi.encodeWithSignature("setValue(uint256)", 42);
        bytes memory mutatedCd = abi.encodeWithSignature("setValue(uint256)", 999);

        // [Signature 1] Delegator signs delegation
        Delegation memory delegation = _signDelegation(_buildDelegation());

        // [Signature 2] Signer signs intent for setValue(42)
        ExecutionIntent memory intent = ExecutionIntent({
            account:  address(delegatorAccount),
            target:   address(demoTarget),
            value:    0,
            dataHash: keccak256(signedCd),
            nonce:    0,
            deadline: 0
        });
        bytes memory intentArgs = abi.encode(intent, signer, _signIntent(intent));

        console.log("=== Flowwire Case 2: Mutated Execution ===");
        console.log("signed:  setValue(42)");
        console.log("mutated: setValue(999)");

        vm.expectRevert(abi.encodeWithSelector(
            ExecutionBoundCaveat.DataHashMismatch.selector,
            keccak256(signedCd),
            keccak256(mutatedCd)
        ));

        _redeem(delegation, intentArgs, ExecutionLib.encodeSingle(address(demoTarget), 0, mutatedCd));

        console.log("REVERTED: DataHashMismatch");
        assertEq(demoTarget.value(), 0);
    }

    // -------------------------------------------------------------------------
    // Case 3: Replay reverts
    // -------------------------------------------------------------------------

    function test_flowwire_replay_reverts() public {
        bytes memory cd = abi.encodeWithSignature("setValue(uint256)", 42);

        // [Signature 1] Delegator signs delegation
        Delegation memory delegation = _signDelegation(_buildDelegation());

        // [Signature 2] Signer signs intent
        ExecutionIntent memory intent = ExecutionIntent({
            account:  address(delegatorAccount),
            target:   address(demoTarget),
            value:    0,
            dataHash: keccak256(cd),
            nonce:    7,
            deadline: 0
        });
        bytes memory intentArgs = abi.encode(intent, signer, _signIntent(intent));

        console.log("=== Flowwire Case 3: Replay ===");

        // First redemption succeeds
        _redeem(delegation, intentArgs, ExecutionLib.encodeSingle(address(demoTarget), 0, cd));
        assertEq(demoTarget.value(), 42);
        console.log("First redemption: SUCCESS");

        // Second redemption reverts
        vm.expectRevert(abi.encodeWithSelector(
            ExecutionBoundCaveat.NonceAlreadyUsed.selector,
            address(delegatorAccount),
            signer,
            7
        ));
        _redeem(delegation, intentArgs, ExecutionLib.encodeSingle(address(demoTarget), 0, cd));
        console.log("Replay: REVERTED NonceAlreadyUsed");
    }

    // -------------------------------------------------------------------------
    // Case 4: Non-single call type reverts
    // -------------------------------------------------------------------------

    function test_flowwire_unsupportedCallType_reverts() public {
        bytes memory cd = abi.encodeWithSignature("setValue(uint256)", 42);

        // [Signature 1] Delegator signs delegation
        Delegation memory delegation = _signDelegation(_buildDelegation());

        // [Signature 2] Signer signs intent
        ExecutionIntent memory intent = ExecutionIntent({
            account:  address(delegatorAccount),
            target:   address(demoTarget),
            value:    0,
            dataHash: keccak256(cd),
            nonce:    0,
            deadline: 0
        });
        bytes memory intentArgs = abi.encode(intent, signer, _signIntent(intent));

        // Use delegatecall mode
        ModeCode delegatecallMode = ModeCode.wrap(bytes32(uint256(0xFF) << 248));

        console.log("=== Flowwire Case 4: Unsupported Call Type ===");

        delegation.caveats[0].args = intentArgs;
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegations);

        ModeCode[] memory modes = new ModeCode[](1);
        modes[0] = delegatecallMode;

        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] = ExecutionLib.encodeSingle(address(demoTarget), 0, cd);

        vm.prank(redeemer);
        vm.expectRevert(ExecutionBoundCaveat.UnsupportedCallType.selector);
        delegationManager.redeemDelegations(permissionContexts, modes, executionCallDatas);

        console.log("REVERTED: UnsupportedCallType");
    }
}
