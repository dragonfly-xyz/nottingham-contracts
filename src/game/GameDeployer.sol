// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { Game, IPlayer } from './Game.sol';
import { SafeCreate2 } from './SafeCreate2.sol';
import { LibMatchUtils } from './LibMatchUtils.sol';

contract GameDeployer {
    event GameCreated(Game game, IPlayer[] players);

    constructor(bytes32 seed, bytes[] memory playerCreationCodes) {
        SafeCreate2 sc2 = new SafeCreate2();
        Game game;
        IPlayer[] memory players;
        (game, players) = LibMatchUtils.deployGame(
            sc2,
            msg.sender,
            2,
            seed,
            playerCreationCodes
        );
        emit GameCreated(game, players);
        selfdestruct(payable(tx.origin));
    }
}
