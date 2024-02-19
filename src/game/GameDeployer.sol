// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { Game } from './Game.sol';
import { SafeCreate2 } from './SafeCreate2.sol';

contract GameDeployer {
    
    event GameCreated(Game game);

    constructor(bytes32 seed, bytes[] memory playerCreationCodes) {
        SafeCreate2 sc2 = new SafeCreate2();
        uint256[] memory playerSalts = _minePlayerSalts(
            _getNextDeployAddress(2),
            sc2,
            seed,
            playerCreationCodes
        );
        emit GameCreated(new Game(
            msg.sender,
            sc2,
            playerCreationCodes,
            playerSalts
        ));
        selfdestruct(payable(msg.sender));
    }

    function _minePlayerSalts(address game, SafeCreate2 sc2, bytes32 seed, bytes[] memory playerCreationCodes)
        private pure returns (uint256[] memory salts)
    {
        salts = new uint256[](playerCreationCodes.length);
        for (uint256 i; i < playerCreationCodes.length; ++i) {
            salts[i] = _findPlayerSalt(
                game,
                sc2,
                seed,
                playerCreationCodes[i],
                uint8(i),
                uint8(playerCreationCodes.length)
            );
        }
    }

    function _findPlayerSalt(
        address game,
        SafeCreate2 sc2, 
        bytes32 seed,
        bytes memory creationCode,
        uint8 playerIdx,
        uint8 playerCount
    )
        internal pure returns (uint256 salt)
    {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(creationCode, abi.encode(playerIdx, playerCount)));
        unchecked {
            for (salt = uint256(seed); true; ++salt) {
                uint256 create2Salt = uint256(keccak256(abi.encode(salt, game)));
                address addr = _getCreate2Address(initCodeHash, address(sc2), create2Salt);
                if ((uint160(addr) & 7) == playerIdx) {
                    return salt;
                }
            }
        }
    }

    function _getNextDeployAddress(uint32 nonce) internal view returns (address) {
        return _getCreateAddress(address(this), nonce);
    }

    function _getCreateAddress(address deployer, uint32 deployerNonce)
        private pure returns (address deployed)
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

    function _getCreate2Address(bytes32 creationCodeHash, address deployer, uint256 salt)
        private pure returns (address deployed)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1('\xff'),
            deployer,
            salt,
            creationCodeHash
        )))));
    }
}
