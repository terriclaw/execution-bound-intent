// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title DemoTarget
/// @notice Minimal contract for integration flow verification.
contract DemoTarget {
    uint256 public value;
    event ValueSet(uint256 newValue);

    function setValue(uint256 _value) external {
        value = _value;
        emit ValueSet(_value);
    }
}
