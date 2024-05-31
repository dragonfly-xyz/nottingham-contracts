// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IPlayer, PlayerBundle } from './IPlayer.sol';
import './Constants.sol';

error InvalidPlayerError();

function getIndexFromPlayer(IPlayer player) pure returns (uint8 playerIdx) {
    require(player != IPlayer(address(0)), InvalidPlayerError());
    // The deployment process in the constructor ensures that the lowest 3 bits of the
    // player's address is also its player index.
    return uint8(uint160(address(player)) & PLAYER_ADDRESS_INDEX_MASK);
}

function getBundleHash(PlayerBundle memory bundle, uint16 round)
    pure returns (bytes32 hash)
{
    return bytes32((uint256(keccak256(abi.encode(bundle))) & ~uint256(0xFFFF)) | round);
}

function getRoundFromBundleHash(bytes32 hash) pure returns (uint16 round) {
    return uint16(uint256(hash) & 0xFFFF);
}

function tstore(uint256 slot, bytes32 value) {
    assembly ('memory-safe') {
        tstore(slot, value)
    }
}

function tload(uint256 slot) view returns (bytes32 value) {
    assembly ('memory-safe') {
        value := tload(slot)
    }
}

function hashSlot(uint256 a) pure returns (uint256 r) {
    assembly ('memory-safe') {
        mstore(0x00, a)
        r := keccak256(0x00, 0x20)
    }
}

type TransientArray_Bytes32 is uint256;

library LibTransientArray_Bytes32 {
    function store(
        TransientArray_Bytes32 slot,
        uint256 idx,
        bytes32 v
    ) internal {
        unchecked {
            tstore(hashSlot(TransientArray_Bytes32.unwrap(slot)) + idx, v);
        }
    }

    function load(TransientArray_Bytes32 slot, uint256 idx)
        internal view returns (bytes32 v)
    {
        unchecked {
            v = tload(hashSlot(TransientArray_Bytes32.unwrap(slot)) + idx);
        }
    }
}

using LibTransientArray_Bytes32 for TransientArray_Bytes32 global;

type TransientAddress is uint256;

library LibTransientAddress {
    function store(TransientAddress slot, address v)
        internal 
    {
        tstore(TransientAddress.unwrap(slot), bytes32(uint256(uint160(v))));
    }

    function load(TransientAddress slot)
        internal view returns (address v)
    {
        v = address(uint160(uint256(tload(TransientAddress.unwrap(slot)))));
    }
}

using LibTransientAddress for TransientAddress global;

type TransientBool is uint256;

library LibTransientBool {
    function store(TransientBool slot, bool v) internal {
        tstore(TransientBool.unwrap(slot), v ? bytes32(uint256(1)) : bytes32(0));
    }

    function load(TransientBool slot)
        internal view returns (bool v)
    {
        v = tload(TransientBool.unwrap(slot)) != bytes32(0);
    }
}

using LibTransientBool for TransientBool global;
