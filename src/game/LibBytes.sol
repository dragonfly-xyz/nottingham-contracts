// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

library LibBytes {
    error Create2FailedError();

    function trimLeadingBytesDestructive(bytes memory buf, uint256 numBytes)
        internal pure returns (bytes memory self)
    {
        unchecked { 
            uint256 len = buf.length;
            if (numBytes < len) {
                len = len - numBytes;
            } else {
                numBytes = len;
                len = 0;
            }
            assembly ("memory-safe") {
                buf := add(buf, numBytes)
                mstore(buf, len)
            }
        }
        return buf;
    }

    function getSelectorOr(bytes memory buf, bytes4 defaultValue)
        internal pure returns (bytes4 selector)
    {
        uint256 len = buf.length;
        if (len < 4) {
            return defaultValue;
        }
        assembly ("memory-safe") {
            selector := shl(224, shr(224, mload(add(buf, 0x20))))
        }
    }

    function slice(bytes memory buf, uint256 offset)
        internal pure returns (bytes memory sliced)
    {
        return slice(buf, offset, buf.length);
    }
    function slice(bytes memory buf, uint256 offset, uint256 size)
        internal pure returns (bytes memory sliced)
    {
        if (buf.length == 0 || offset >= buf.length) {
            return "";
        }
        uint256 end = size + offset > buf.length ? buf.length : offset + size;
        size = end - offset;
        sliced = new bytes(size);
        assembly ("memory-safe") {
            mcopy(add(sliced, 0x20), add(buf, add(0x20, offset)), size)
        }
    }

    function rawRevert(bytes memory buf)
        internal pure
    {
        assembly ("memory-safe") {
            revert(add(buf, 0x20), mload(buf))
        }
    }

    function rawReturn(bytes memory buf)
        internal pure
    {
        assembly ("memory-safe") {
            return(add(buf, 0x20), mload(buf))
        }
    }

    function create2(bytes memory initData, uint256 salt, uint256 value, bytes memory callArgs)
        internal returns (address deployed)
    {
        assembly ("memory-safe") {
            let merged := mload(0x40)
            let initLen := mload(initData)
            let s := staticcall(gas(), 0x4, add(initData, 0x20), initLen, merged, initLen)
            if iszero(s) { revert(0, 0) }
            let argsLen := mload(callArgs)
            s := staticcall(gas(), 0x4, add(callArgs, 0x20), argsLen, add(merged, initLen), argsLen)
            if iszero(s) { revert(0, 0) }
            deployed := create2(value, merged, add(initLen, argsLen), salt)
        }
        if (deployed == address(0)) {
            revert Create2FailedError();
        }
    }
}
