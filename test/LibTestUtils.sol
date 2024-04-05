// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

library LibTestUtils {
    function randomBytes32() internal view returns (bytes32 r) {
        return keccak256(abi.encode(msg.data, gasleft(), address(this).codehash));
    }

    function randomUint256() internal view returns (uint256 r) {
        return uint256(randomBytes32());
    }

    function randomAddress() internal view returns (address payable r) {
        return payable(address(uint160(randomUint256())));
    }

    function randomBytes(uint256 len) internal view returns (bytes memory b) {
        b = new bytes(len);
        for (uint256 i; i < len; i += 32) {
            bytes32 w = randomBytes32();
            uint256 o = len - i > 32 ? 256 : (len - i) * 8;
            bytes32 m = bytes32(~((uint256(2) << (256 - o)) - 1));
            assembly ('memory-safe') {
                let p := add(b, add(0x20, i))
                let t := mload(p)
                mstore(p, or(and(w, m), and(t, not(m))))
            }
        }
    }

    function toDynArray(bytes[1] memory fixedArr)
        internal pure returns (bytes[] memory dynArr)
    {
        dynArr = new bytes[](fixedArr.length);
        for (uint256 i; i < fixedArr.length; ++i) {
            dynArr[i] = fixedArr[i];
        }
    }

    function toDynArray(bytes[2] memory fixedArr)
        internal pure returns (bytes[] memory dynArr)
    {
        dynArr = new bytes[](fixedArr.length);
        for (uint256 i; i < fixedArr.length; ++i) {
            dynArr[i] = fixedArr[i];
        }
    }

    function toDynArray(bytes[3] memory fixedArr)
        internal pure returns (bytes[] memory dynArr)
    {
        dynArr = new bytes[](fixedArr.length);
        for (uint256 i; i < fixedArr.length; ++i) {
            dynArr[i] = fixedArr[i];
        }
    }

    function toDynArray(bytes[4] memory fixedArr)
        internal pure returns (bytes[] memory dynArr)
    {
        dynArr = new bytes[](fixedArr.length);
        for (uint256 i; i < fixedArr.length; ++i) {
            dynArr[i] = fixedArr[i];
        }
    }

    function toDynArray(bytes[5] memory fixedArr)
        internal pure returns (bytes[] memory dynArr)
    {
        dynArr = new bytes[](fixedArr.length);
        for (uint256 i; i < fixedArr.length; ++i) {
            dynArr[i] = fixedArr[i];
        }
    }

    function toDynArray(address[1] memory fixedArr)
        internal pure returns (address[] memory dynArr)
    {
        dynArr = new address[](fixedArr.length);
        for (uint256 i; i < fixedArr.length; ++i) {
            dynArr[i] = fixedArr[i];
        }
    }

    function toDynArray(address[2] memory fixedArr)
        internal pure returns (address[] memory dynArr)
    {
        dynArr = new address[](fixedArr.length);
        for (uint256 i; i < fixedArr.length; ++i) {
            dynArr[i] = fixedArr[i];
        }
    }

    function toDynArray(address[3] memory fixedArr)
        internal pure returns (address[] memory dynArr)
    {
        dynArr = new address[](fixedArr.length);
        for (uint256 i; i < fixedArr.length; ++i) {
            dynArr[i] = fixedArr[i];
        }
    }

    function toDynArray(address[4] memory fixedArr)
        internal pure returns (address[] memory dynArr)
    {
        dynArr = new address[](fixedArr.length);
        for (uint256 i; i < fixedArr.length; ++i) {
            dynArr[i] = fixedArr[i];
        }
    }

    function toDynArray(address[5] memory fixedArr)
        internal pure returns (address[] memory dynArr)
    {
        dynArr = new address[](fixedArr.length);
        for (uint256 i; i < fixedArr.length; ++i) {
            dynArr[i] = fixedArr[i];
        }
    }

    function toDynArray(uint256[1] memory fixedArr)
        internal pure returns (uint256[] memory dynArr)
    {
        dynArr = new uint256[](fixedArr.length);
        for (uint256 i; i < fixedArr.length; ++i) {
            dynArr[i] = fixedArr[i];
        }
    }

    function toDynArray(uint256[2] memory fixedArr)
        internal pure returns (uint256[] memory dynArr)
    {
        dynArr = new uint256[](fixedArr.length);
        for (uint256 i; i < fixedArr.length; ++i) {
            dynArr[i] = fixedArr[i];
        }
    }

    function toDynArray(uint256[3] memory fixedArr)
        internal pure returns (uint256[] memory dynArr)
    {
        dynArr = new uint256[](fixedArr.length);
        for (uint256 i; i < fixedArr.length; ++i) {
            dynArr[i] = fixedArr[i];
        }
    }

    function toDynArray(uint256[4] memory fixedArr)
        internal pure returns (uint256[] memory dynArr)
    {
        dynArr = new uint256[](fixedArr.length);
        for (uint256 i; i < fixedArr.length; ++i) {
            dynArr[i] = fixedArr[i];
        }
    }

    function toDynArray(uint256[5] memory fixedArr)
        internal pure returns (uint256[] memory dynArr)
    {
        dynArr = new uint256[](fixedArr.length);
        for (uint256 i; i < fixedArr.length; ++i) {
            dynArr[i] = fixedArr[i];
        }
    }

    function throwInvalid() internal pure {
        assembly ("memory-safe") {
            invalid()
        }
    }
}