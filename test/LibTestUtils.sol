// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

library LibTestUtils {

    function getCreateAddress(address deployer, uint256 deployerNonce)
        internal pure returns (address deployed)
    {
        assembly {
            mstore(0x02, shl(96, deployer))
            let rlpNonceLength
            switch gt(deployerNonce, 0xFFFFFF)
                case 1 { // 4 byte nonce
                    rlpNonceLength := 5
                    mstore8(0x00, 0xD8)
                    mstore8(0x16, 0x84)
                    mstore(0x17, shl(224, deployerNonce))
                }
                default {
                    switch gt(deployerNonce, 0xFFFF)
                        case 1 {
                            // 3 byte nonce
                            rlpNonceLength := 4
                            mstore8(0x16, 0x83)
                            mstore(0x17, shl(232, deployerNonce))
                        }
                        default {
                            switch gt(deployerNonce, 0xFF)
                                case 1 {
                                    // 2 byte nonce
                                    rlpNonceLength := 3
                                    mstore8(0x16, 0x82)
                                    mstore(0x17, shl(240, deployerNonce))
                                }
                                default {
                                    switch gt(deployerNonce, 0x7F)
                                        case 1 {
                                            // 1 byte nonce >= 0x80
                                            rlpNonceLength := 2
                                            mstore8(0x16, 0x81)
                                            mstore8(0x17, deployerNonce)
                                        }
                                        default {
                                            rlpNonceLength := 1
                                            switch iszero(deployerNonce)
                                                case 1 {
                                                    // zero nonce
                                                    mstore8(0x16, 0x80)
                                                }
                                                default {
                                                    // 1 byte nonce < 0x80
                                                    mstore8(0x16, deployerNonce)
                                                }
                                        }
                                }
                        }
                }
            mstore8(0x00, add(0xD5, rlpNonceLength))
            mstore8(0x01, 0x94)
            deployed := and(
                keccak256(0x00, add(0x16, rlpNonceLength)),
                0xffffffffffffffffffffffffffffffffffffffff
            )
        }
    }

    function getCreate2Address(bytes32 creationCodeHash, address deployer, uint256 salt)
        internal pure returns (address deployed)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1('\xff'),
            deployer,
            salt,
            creationCodeHash
        )))));
    }

    function randomBytes32() internal view returns (bytes32 r) {
        return keccak256(abi.encode(msg.data, gasleft(), address(this).codehash));
    }

    function randomUint256() internal view returns (uint256 r) {
        return uint256(randomBytes32());
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

    function throwInvalid() internal pure {
        assembly ("memory-safe") {
            invalid()
        }
    }
}