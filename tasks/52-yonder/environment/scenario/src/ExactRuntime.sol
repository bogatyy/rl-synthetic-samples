// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Installs archival runtime bytecode with a reconstructed storage
/// image. VDS was unverified; Setup uses the exact pre-incident runtime and
/// relocates only its linked library address.
contract ExactRuntime {
    constructor(bytes memory runtime, bytes32[] memory slots, bytes32[] memory values) payable {
        require(runtime.length != 0 && slots.length == values.length, "runtime image");
        for (uint256 i; i < slots.length; ++i) {
            bytes32 slot = slots[i];
            bytes32 value = values[i];
            assembly { sstore(slot, value) }
        }
        assembly { return(add(runtime, 0x20), mload(runtime)) }
    }
}

contract VDimensionExactRuntime is ExactRuntime {
    constructor(bytes memory runtime, bytes32[] memory slots, bytes32[] memory values)
        ExactRuntime(runtime, slots, values)
    {}
}

contract VDimensionLibraryExactRuntime is ExactRuntime {
    constructor(bytes memory runtime, bytes32[] memory slots, bytes32[] memory values)
        ExactRuntime(runtime, slots, values)
    {}
}
