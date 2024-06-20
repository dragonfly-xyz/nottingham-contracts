// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import '~/game/IGame.sol';

// Base class for BytecodePlayer (further below).
abstract contract BaseBytecodePlayer is IPlayer {
    constructor(
        IGame game,
        uint8 playerIdx,
        uint8 playerCount,
        uint8 assetCount,
        bytes memory bytecode
    ) {
        bytes memory bytecodeWithArgs = bytes.concat(
            bytecode,
            abi.encode(game, playerIdx, playerCount, assetCount)
        );
        // Witchcraft ahead 🧹.
        Echo echo = new Echo(bytecodeWithArgs);
        assembly ('memory-safe') {
            let s := delegatecall(
                gas(),
                echo,
                add(bytecodeWithArgs, 0x20),
                mload(bytecodeWithArgs),
                0x0,
                0
            )
            returndatacopy(0x00, 0x00, returndatasize())
            if iszero(s) { revert(0x00, returndatasize()) }
            return(0x00, returndatasize())
        }
    }

    // Just to shush the compiler.
    function createBundle(uint8 /* builderIdx */)
        external virtual returns (PlayerBundle memory bundle)
    {}

    // Just to shush the compiler.
    function buildBlock(PlayerBundle[] calldata bundles)
        external virtual returns (uint256 goldBid)
    {}
}

contract Echo {
    constructor(bytes memory data) {
        assembly ("memory-safe") {
            return(add(data, 0x20), mload(data))
        }
    }
}
