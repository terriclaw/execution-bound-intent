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
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { P256SCLVerifierLib } from "@delegation-framework/libraries/P256SCLVerifierLib.sol";
import { Delegation, Caveat, ModeCode } from "@delegation-framework/utils/Types.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";

import { ExactExecutionEnforcer } from "@delegation-framework/enforcers/ExactExecutionEnforcer.sol";
import { TimestampEnforcer } from "@delegation-framework/enforcers/TimestampEnforcer.sol";
import { IdEnforcer } from "@delegation-framework/enforcers/IdEnforcer.sol";

import { DemoTarget } from "../src/DemoTarget.sol";

/// @title CompositionFlowTest
/// @notice Real end-to-end composition flow using delegation-framework.
///
/// Proves the composable path through actual MetaMask delegation-framework contracts:
///   ExactExecutionEnforcer + TimestampEnforcer + IdEnforcer stacked on a delegation
///
/// Architecture:
///   - Delegator: HybridDeleGator (ERC-1271 smart account)
///   - Redeemer:  plain EOA
///   - Caveats:   ExactExecutionEnforcer + TimestampEnforcer + IdEnforcer
///   - Target:    DemoTarget (setValue)
///
/// Cases proven:
///   1. Exact execution succeeds
///   2. Mutated calldata fails (ExactExecutionEnforcer rejects)
///   3. Replay fails (IdEnforcer rejects second redemption)
///   4. Expired delegation fails (TimestampEnforcer rejects)
///
/// Contrast with execution-intent path (ExecutionBoundCaveat / ExecutionBoundEnforcer):
///   - Composition: calldata committed at delegation time, guarantees enforced independently
///   - Execution intent: all guarantees in one signed artifact at redemption time

contract CompositionFlowTest is Test {
    using MessageHashUtils for bytes32;

    // ---------------------------------------------------------------------------
    // Stack
    // ---------------------------------------------------------------------------
    DelegationManager        delegationManager;
    HybridDeleGator          delegatorImpl;
    HybridDeleGator          delegatorAccount;
    ExactExecutionEnforcer   exactEnforcer;
    TimestampEnforcer        timestampEnforcer;
    IdEnforcer               idEnforcer;
    DemoTarget               target;
    IEntryPoint              entryPoint;

    bytes32 delegationDomainSep;
    bytes32 ROOT_AUTHORITY;
    uint256 delegatorKey  = 0xDE1E6A702;
    address delegatorEOA;
    address redeemer;

    // ---------------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------------
    function setUp() public {
        delegatorEOA = vm.addr(delegatorKey);
        redeemer     = makeAddr("redeemer");

        // Deploy entrypoint stub
        entryPoint = IEntryPoint(makeAddr("entrypoint"));
        vm.etch(address(entryPoint), hex"00");

        // Deploy DelegationManager
        delegationManager = new DelegationManager(delegatorEOA);

        delegationDomainSep = delegationManager.getDomainHash();
        ROOT_AUTHORITY      = delegationManager.ROOT_AUTHORITY();

        // Deploy HybridDeleGator implementation
        delegatorImpl = new HybridDeleGator(
            delegationManager,
            entryPoint
        );

        // Deploy delegator account as proxy
        bytes memory initData = abi.encodeCall(
            HybridDeleGator.initialize,
            (delegatorEOA, new string[](0), new uint256[](0), new uint256[](0))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(delegatorImpl), initData);
        delegatorAccount = HybridDeleGator(payable(address(proxy)));

        // Fund delegator account
        vm.deal(address(delegatorAccount), 10 ether);

        // Deploy enforcers
        exactEnforcer     = new ExactExecutionEnforcer();
        timestampEnforcer = new TimestampEnforcer();
        idEnforcer        = new IdEnforcer();

        // Deploy target
        target = new DemoTarget();
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------
    function _buildExecution(uint256 setValue_) internal view returns (bytes memory execCalldata_) {
        bytes memory cd = abi.encodeWithSignature("setValue(uint256)", setValue_);
        execCalldata_ = ExecutionLib.encodeSingle(address(target), 0, cd);
    }

    function _buildCaveats(
        uint256 setValue_,
        uint128 deadlineAfter_,
        uint128 deadlineBefore_,
        uint256 delegationId_
    ) internal view returns (Caveat[] memory caveats_) {
        caveats_ = new Caveat[](3);

        // ExactExecutionEnforcer: terms = encoded execution (target, value, calldata)
        bytes memory cd = abi.encodeWithSignature("setValue(uint256)", setValue_);
        caveats_[0] = Caveat({
            enforcer: address(exactEnforcer),
            terms:    ExecutionLib.encodeSingle(address(target), 0, cd),
            args:     hex""
        });

        // TimestampEnforcer: terms = abi.encode(uint128 after, uint128 before)
        caveats_[1] = Caveat({
            enforcer: address(timestampEnforcer),
            terms:    abi.encodePacked(deadlineAfter_, deadlineBefore_),
            args:     hex""
        });

        // IdEnforcer: terms = abi.encode(uint256 id)
        caveats_[2] = Caveat({
            enforcer: address(idEnforcer),
            terms:    abi.encode(delegationId_),
            args:     hex""
        });
    }

    function _signDelegation(Delegation memory delegation_) internal view returns (bytes memory) {
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        bytes32 digest_ = MessageHashUtils.toTypedDataHash(delegationDomainSep, delegationHash_);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegatorKey, digest_);
        return abi.encodePacked(r, s, v);
    }

    function _redeem(Delegation memory delegation_, bytes memory execCalldata_) internal {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = execCalldata_;

        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleSingle();

        vm.prank(redeemer);
        delegationManager.redeemDelegations(permissionContexts_, modes_, executionCallDatas_);
    }

    // ---------------------------------------------------------------------------
    // Case 1: Exact execution succeeds
    // ---------------------------------------------------------------------------
    function test_composition_exactExecution_succeeds() public {
        console.log("=== Composition Flow: Exact Execution ===");

        uint128 deadlineBefore = uint128(block.timestamp + 3600);
        uint256 delegationId   = 1;

        Caveat[] memory caveats = _buildCaveats(42, 0, deadlineBefore, delegationId);

        Delegation memory delegation = Delegation({
            delegate:   redeemer,
            delegator:  address(delegatorAccount),
            authority:  ROOT_AUTHORITY,
            caveats:    caveats,
            salt:       0,
            signature:  hex""
        });

        delegation.signature = _signDelegation(delegation);

        _redeem(delegation, _buildExecution(42));

        assertEq(target.value(), 42);
        console.log("target.value():", target.value());
        console.log("RESULT: SUCCESS - ExactExecutionEnforcer + TimestampEnforcer + IdEnforcer all passed");
    }

    // ---------------------------------------------------------------------------
    // Case 2: Mutated calldata fails
    // ---------------------------------------------------------------------------
    function test_composition_mutatedCalldata_fails() public {
        console.log("=== Composition Flow: Mutated Calldata ===");

        uint128 deadlineBefore = uint128(block.timestamp + 3600);
        uint256 delegationId   = 2;

        // Delegation commits to setValue(42)
        Caveat[] memory caveats = _buildCaveats(42, 0, deadlineBefore, delegationId);

        Delegation memory delegation = Delegation({
            delegate:   redeemer,
            delegator:  address(delegatorAccount),
            authority:  ROOT_AUTHORITY,
            caveats:    caveats,
            salt:       0,
            signature:  hex""
        });

        delegation.signature = _signDelegation(delegation);

        // Redeemer attempts setValue(999) instead
        vm.expectRevert();
        _redeem(delegation, _buildExecution(999));

        assertEq(target.value(), 0);
        console.log("RESULT: REVERTED - ExactExecutionEnforcer blocked mutation");
    }

    // ---------------------------------------------------------------------------
    // Case 3: Replay fails (IdEnforcer)
    // ---------------------------------------------------------------------------
    function test_composition_replay_fails() public {
        console.log("=== Composition Flow: Replay Attack ===");

        uint128 deadlineBefore = uint128(block.timestamp + 3600);
        uint256 delegationId   = 3;

        Caveat[] memory caveats = _buildCaveats(42, 0, deadlineBefore, delegationId);

        Delegation memory delegation = Delegation({
            delegate:   redeemer,
            delegator:  address(delegatorAccount),
            authority:  ROOT_AUTHORITY,
            caveats:    caveats,
            salt:       0,
            signature:  hex""
        });

        delegation.signature = _signDelegation(delegation);

        // First redemption succeeds
        _redeem(delegation, _buildExecution(42));
        assertEq(target.value(), 42);
        console.log("First redemption: SUCCESS");

        // Second redemption fails — IdEnforcer consumed the id
        vm.expectRevert();
        _redeem(delegation, _buildExecution(42));
        console.log("RESULT: REVERTED - IdEnforcer blocked replay");
    }

    // ---------------------------------------------------------------------------
    // Case 4: Expired delegation fails (TimestampEnforcer)
    // ---------------------------------------------------------------------------
    function test_composition_expired_fails() public {
        console.log("=== Composition Flow: Expired Delegation ===");

        uint128 deadlineBefore = uint128(block.timestamp + 100);
        uint256 delegationId   = 4;

        Caveat[] memory caveats = _buildCaveats(42, 0, deadlineBefore, delegationId);

        Delegation memory delegation = Delegation({
            delegate:   redeemer,
            delegator:  address(delegatorAccount),
            authority:  ROOT_AUTHORITY,
            caveats:    caveats,
            salt:       0,
            signature:  hex""
        });

        delegation.signature = _signDelegation(delegation);

        // Warp past deadline
        vm.warp(block.timestamp + 200);

        vm.expectRevert();
        _redeem(delegation, _buildExecution(42));
        console.log("RESULT: REVERTED - TimestampEnforcer blocked expired delegation");
    }
}
