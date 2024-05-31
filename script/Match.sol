// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { Game, IPlayer, INVALID_PLAYER_IDX, MIN_PLAYERS, MAX_PLAYERS } from '~/game/Game.sol';
import { SafeCreate2 } from '~/game/SafeCreate2.sol';
import { GameDeployer } from '~/game/GameDeployer.sol';
import { LibMatchUtils } from '~/game/LibMatchUtils.sol';
import { Script } from 'forge-std/Script.sol';
import { console2 } from 'forge-std/console2.sol';

contract Match is Script {
    SafeCreate2 sc2;

    struct PlayerInfo {
        string name;
        bytes creationCode;
    }

    struct PlayerResult {
        uint8 playerIdx;
        IPlayer player;
        uint256 score; 
        uint8 scoreAssetIdx;
    }

    function setUp() external {
        sc2 = new SafeCreate2();
    }

    function runMatch(string[] memory botNames)
        external returns (Game game, PlayerResult[] memory playerResults)
    {
        require(botNames.length >= MIN_PLAYERS && botNames.length <= MAX_PLAYERS, '# of players');
        PlayerInfo[] memory players = new PlayerInfo[](botNames.length);
        for (uint256 i; i < botNames.length; ++i) {
            string memory json = vm.readFile(string(abi.encodePacked(
                vm.projectRoot(),
                '/out/',
                botNames[i],
                '.sol/',
                botNames[i],
                '.json'
            )));
            players[i].name = botNames[i];
            players[i].creationCode = vm.parseJsonBytes(json, '.bytecode.object');
        }
        (game, playerResults) = runMatch(players);
        {
            console2.log(string(abi.encodePacked(
                unicode'🏁 Game ended after ',
                vm.toString(game.round()),
                ' rounds:'
            )));
            for (uint256 i; i < playerResults.length; ++i) {
                string memory bullet = unicode'🥉';
                if (i == 0) {
                    bullet = unicode'🏆️';
                } else if (i == 1) {
                    bullet = unicode'🥈';
                }
                console2.log(string(abi.encodePacked(
                    '\t',
                    bullet,
                    ' \x1b[1m',
                    players[playerResults[i].playerIdx].name,
                    '\x1b[0m [',
                    vm.toString(playerResults[i].playerIdx),
                    ']: ',
                    _toDecimals(playerResults[i].score),
                    ' ',
                    _toAssetEmoji(playerResults[i].scoreAssetIdx)
                )));
            }
        }
    }

    function runMatch(PlayerInfo[] memory players)
        public returns (Game game, PlayerResult[] memory playerResults)
    {
        IPlayer[] memory playerInstances;
        {
            bytes[] memory playerCreationCodes = new bytes[](players.length);
            for (uint256 i; i < players.length; ++i) {
                playerCreationCodes[i] = players[i].creationCode;
            }
            (game, playerInstances) = LibMatchUtils.deployGame(
                sc2,
                address(this),
                uint32(vm.getNonce(address(this))),
                bytes32(uint256(0x1234)),
                playerCreationCodes 
            );
        }
        for (uint256 i; i < playerInstances.length; ++i) {
            if (address(playerInstances[i]).code.length == 0) {
                revert(string(abi.encodePacked(
                    'Player "',
                    players[i].name,
                    '" failed to deploy!'
                )));
            }
        }
        uint8 winnerIdx = INVALID_PLAYER_IDX;
        while (winnerIdx == INVALID_PLAYER_IDX) {
            winnerIdx = game.playRound();
        }
        uint256[] memory scores = game.scorePlayers();
        uint8[] memory scoreAssetIdxs = new uint8[](players.length);
        for (uint8 i; i < playerInstances.length; ++i) {
            for (uint8 j = 1; j < players.length; ++j) {
                if (game.balanceOf(i, j) == scores[i]) {
                    scoreAssetIdxs[i] = j;
                    break;
                }
            }
        }
        uint8[] memory ranking = _rankPlayers(scores);
        assert(winnerIdx == ranking[0]);
        playerResults = new PlayerResult[](players.length);
        for (uint256 i; i < players.length; ++i) {
            playerResults[i] = PlayerResult({
                playerIdx: ranking[i],
                player: playerInstances[ranking[i]],
                score: scores[ranking[i]],
                scoreAssetIdx: scoreAssetIdxs[ranking[i]]
            });
        }
    }
   
    function _rankPlayers(uint256[] memory scores)
        private pure returns (uint8[] memory idxs)
    {
        uint8 n = uint8(scores.length);
        if (n == 0) return idxs;
        idxs = new uint8[](n);
        for (uint8 i; i < n; ++i) idxs[i] = i;
        bool swapped = true;
        while (swapped) {
            swapped = false;
            for (uint8 i; i < n - 1; ++i) {
                if (scores[idxs[i]] < scores[idxs[i + 1]]) {
                   (idxs[i], idxs[i+1])  = (idxs[i+1], idxs[i]);
                   swapped = true; 
                }
            }
        }
    }

    function _toDecimals(uint256 weis)
        private pure returns (string memory dec)
    {
        uint256 whole = weis / 1e18;
        uint256 frac = weis - (whole * 1e18);
        return string(abi.encodePacked(vm.toString(whole), '.', vm.toString(frac)));
    }

    function _toAssetEmoji(uint8 assetIdx)
        private pure returns (string memory emoji)
    {
        if (assetIdx > 6) return string(abi.encodePacked('$', vm.toString(assetIdx)));
        if (assetIdx == 6) return unicode'🍌';
        if (assetIdx == 5) return unicode'🍒';
        if (assetIdx == 4) return unicode'🥑';
        if (assetIdx == 3) return unicode'🐟️';
        if (assetIdx == 2) return unicode'🥖';
        if (assetIdx == 1) return unicode'🍅';
        return unicode'🪙';
    }
}