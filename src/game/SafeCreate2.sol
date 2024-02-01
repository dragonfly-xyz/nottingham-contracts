// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { LibBytes } from './LibBytes.sol';

contract SafeCreate2 {
    using LibBytes for bytes; 

    // Should be called with an upper gas limit.
    function safeCreate2(bytes memory initData, uint256 salt, uint256 value, bytes memory callData)
        external returns (address)
    {
        assembly ("memory-safe") {
            mstore(0x00, salt)
            mstore(0x20, caller())
            salt := keccak256(0x00, 0x40)
        }
        return initData.create2(salt, value, callData);
    }
}