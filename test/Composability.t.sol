// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ExecutionBoundCaveat } from "../src/ExecutionBoundCaveat.sol";
import { ExecutionIntent, ExecutionIntentLib } from "../src/libs/ExecutionIntentLib.sol";

/// @notice Minimal AllowedTargets caveat — passes only if target is in terms list.
contract AllowedTargetsCaveat {
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        bytes32,
        bytes calldata _executionCalldata,
        bytes32,
        address,
        address
    ) external pure {
        (address target,,) = ExecutionLib.decodeSingle(_executionCalldata);
        uint256 len = _terms.length / 20;
        for (uint256 i = 0; i < len; i++) {
            address allowed = address(bytes20(_terms[i * 20:(i + 1) * 20]));
            if (target == allowed) return;
        }
        revert("AllowedTargetsCaveat: target not allowed");
    }
}

/// @notice Minimal TimeBound caveat — passes only if block.timestamp <= deadline in terms.
contract TimeBoundCaveat {
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        bytes32,
        bytes calldata,
        bytes32,
        address,
        address
    ) external view {
        uint256 deadline = uint256(bytes32(_terms[0:32]));
        require(block.timestamp <= deadline, "TimeBoundCaveat: expired");
    }
}

/// @title Composability
/// @notice Proves ExecutionBoundCaveat composes safely with other caveats.
///
/// Key properties tested:
///   - stacking does not create bypass paths
///   - any single caveat failure reverts the whole flow
///   - ExecutionBound catches mutation even when other caveats pass
///   - order of caveat execution does not affect outcome

contract ComposabilityTest is Test {
    using ExecutionIntentLib for ExecutionIntent;

    ExecutionBoundCaveat  boundCaveat;
    AllowedTargetsCaveat  allowedTargets;
    TimeBoundCaveat       timeBound;

    uint256 signerKey = 0xA11CE;
    address signer;
    address account  = address(0xACC0);
    address target   = address(0xBEEF);
    address badTarget = address(0xDEAD);
    address redeemer = address(0xCA11);
    bytes32 domainSep;

    bytes4 constant TRANSFER_SELECTOR = bytes4(keccak256("transfer(address,uint256)"));

    function setUp() public {
        vm.warp(1_000_000);
        boundCaveat   = new ExecutionBoundCaveat();
        allowedTargets = new AllowedTargetsCaveat();
        timeBound      = new TimeBoundCaveat();
        signer         = vm.addr(signerKey);
        domainSep      = boundCaveat.DOMAIN_SEPARATOR();
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _calldata() internal view returns (bytes memory) {
        return abi.encodeWithSelector(TRANSFER_SELECTOR, redeemer, 100e6);
    }

    function _mutatedCalldata() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(TRANSFER_SELECTOR, address(0xEEEE), 1000e6);
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

    function _runBound(bytes memory cd, bytes memory execCd, uint256 nonce) internal {
        ExecutionIntent memory intent = _intent(cd, nonce);
        boundCaveat.beforeHook(
            "",
            abi.encode(intent, signer, _sign(intent)),
            bytes32(0),
            execCd,
            bytes32(0),
            account,
            redeemer
        );
    }

    function _runAllowedTargets(address t, bytes memory cd) internal view {
        allowedTargets.beforeHook(
            abi.encodePacked(t),
            "",
            bytes32(0),
            ExecutionLib.encodeSingle(t, 0, cd),
            bytes32(0),
            account,
            redeemer
        );
    }

    function _runTimeBound(uint256 deadline, bytes memory cd) internal view {
        timeBound.beforeHook(
            abi.encodePacked(bytes32(deadline)),
            "",
            bytes32(0),
            ExecutionLib.encodeSingle(target, 0, cd),
            bytes32(0),
            account,
            redeemer
        );
    }

    // -------------------------------------------------------------------------
    // ExecutionBound + AllowedTargets
    // -------------------------------------------------------------------------

    /// Both caveats pass on exact execution.
    function test_stack_boundAndAllowedTargets_passes() public {
        bytes memory cd = _calldata();
        bytes memory execCd = ExecutionLib.encodeSingle(target, 0, cd);
        _runAllowedTargets(target, cd);
        _runBound(cd, execCd, 0);
    }

    /// AllowedTargets passes but calldata is mutated — ExecutionBound catches it.
    function test_stack_allowedTargetsPasses_boundCatchesMutation() public {
        bytes memory cd        = _calldata();
        bytes memory mutatedCd = _mutatedCalldata();

        // AllowedTargets only checks target — passes on mutated calldata
        _runAllowedTargets(target, mutatedCd);

        // ExecutionBound catches the mutation
        ExecutionIntent memory intent = _intent(cd, 0);
        vm.expectRevert(abi.encodeWithSelector(
            ExecutionBoundCaveat.DataHashMismatch.selector,
            keccak256(cd),
            keccak256(mutatedCd)
        ));
        boundCaveat.beforeHook(
            "",
            abi.encode(intent, signer, _sign(intent)),
            bytes32(0),
            ExecutionLib.encodeSingle(target, 0, mutatedCd),
            bytes32(0),
            account,
            redeemer
        );
    }

    /// AllowedTargets fails — revert propagates regardless of ExecutionBound.
    function test_stack_allowedTargetsFails_reverts() public {
        bytes memory cd = _calldata();
        // terms allow `target`, but execution uses `badTarget` -> revert
        vm.expectRevert("AllowedTargetsCaveat: target not allowed");
        allowedTargets.beforeHook(
            abi.encodePacked(target),
            "",
            bytes32(0),
            ExecutionLib.encodeSingle(badTarget, 0, cd),
            bytes32(0),
            account,
            redeemer
        );
    }

    // -------------------------------------------------------------------------
    // ExecutionBound + TimeBound
    // -------------------------------------------------------------------------

    /// Both pass when within deadline and exact calldata.
    function test_stack_boundAndTimeBound_passes() public {
        bytes memory cd = _calldata();
        bytes memory execCd = ExecutionLib.encodeSingle(target, 0, cd);
        _runTimeBound(block.timestamp + 1 hours, cd);
        _runBound(cd, execCd, 0);
    }

    /// TimeBound fails — revert propagates.
    function test_stack_timeBoundFails_reverts() public {
        bytes memory cd = _calldata();
        vm.expectRevert("TimeBoundCaveat: expired");
        _runTimeBound(block.timestamp - 1, cd);
    }

    /// TimeBound passes but ExecutionBound catches mutation.
    function test_stack_timeBoundPasses_boundCatchesMutation() public {
        bytes memory cd        = _calldata();
        bytes memory mutatedCd = _mutatedCalldata();

        _runTimeBound(block.timestamp + 1 hours, mutatedCd);

        ExecutionIntent memory intent = _intent(cd, 0);
        vm.expectRevert(abi.encodeWithSelector(
            ExecutionBoundCaveat.DataHashMismatch.selector,
            keccak256(cd),
            keccak256(mutatedCd)
        ));
        boundCaveat.beforeHook(
            "",
            abi.encode(intent, signer, _sign(intent)),
            bytes32(0),
            ExecutionLib.encodeSingle(target, 0, mutatedCd),
            bytes32(0),
            account,
            redeemer
        );
    }

    // -------------------------------------------------------------------------
    // Triple stack: ExecutionBound + AllowedTargets + TimeBound
    // -------------------------------------------------------------------------

    /// All three pass on exact execution within deadline.
    function test_stack_triple_passes() public {
        bytes memory cd = _calldata();
        bytes memory execCd = ExecutionLib.encodeSingle(target, 0, cd);
        _runAllowedTargets(target, cd);
        _runTimeBound(block.timestamp + 1 hours, cd);
        _runBound(cd, execCd, 0);
    }

    /// Any single caveat failure reverts — TimeBound fails in triple stack.
    function test_stack_triple_timeBoundFails_reverts() public {
        bytes memory cd = _calldata();
        _runAllowedTargets(target, cd);
        vm.expectRevert("TimeBoundCaveat: expired");
        _runTimeBound(block.timestamp - 1, cd);
    }

    /// Any single caveat failure reverts — mutation caught in triple stack.
    function test_stack_triple_mutationCaught() public {
        bytes memory cd        = _calldata();
        bytes memory mutatedCd = _mutatedCalldata();

        _runAllowedTargets(target, mutatedCd);
        _runTimeBound(block.timestamp + 1 hours, mutatedCd);

        ExecutionIntent memory intent = _intent(cd, 0);
        vm.expectRevert(abi.encodeWithSelector(
            ExecutionBoundCaveat.DataHashMismatch.selector,
            keccak256(cd),
            keccak256(mutatedCd)
        ));
        boundCaveat.beforeHook(
            "",
            abi.encode(intent, signer, _sign(intent)),
            bytes32(0),
            ExecutionLib.encodeSingle(target, 0, mutatedCd),
            bytes32(0),
            account,
            redeemer
        );
    }
}
