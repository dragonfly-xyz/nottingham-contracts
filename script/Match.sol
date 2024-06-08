// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { Game, IPlayer, INVALID_PLAYER_IDX, MIN_PLAYERS, MAX_PLAYERS } from '~/game/Game.sol';
import { SafeCreate2 } from '~/game/SafeCreate2.sol';
import { GameDeployer } from '~/game/GameDeployer.sol';
import { LibMatchUtils } from '~/game/LibMatchUtils.sol';
import { Script } from 'forge-std/Script.sol';
import { console2 } from 'forge-std/console2.sol';
import { Vm } from 'forge-std/Vm.sol';

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

    function runShuffledMatch(string[] memory botNames)
        external returns (Game game, PlayerResult[] memory playerResults)
    {
        uint256 r = uint256(keccak256(abi.encodePacked(vm.unixTime())));
        uint256 n = botNames.length;
        for (uint256 i; i < n; ++i) {
            uint256 j = (r % (n - i)) + i;
            (botNames[i], botNames[j]) = (botNames[j], botNames[i]);
            r = uint256(keccak256(abi.encodePacked(r)));
        }
        return runMatch(botNames);
    }

    function runMatch(string[] memory botNames)
        public returns (Game game, PlayerResult[] memory playerResults)
    {
        require(botNames.length >= MIN_PLAYERS && botNames.length <= MAX_PLAYERS, '# of players');
        PlayerInfo[] memory players = new PlayerInfo[](botNames.length);
        for (uint256 i; i < botNames.length; ++i) {
            string memory json = vm.readFile(string.concat(
                vm.projectRoot(),
                '/out/',
                botNames[i],
                '.sol/',
                botNames[i],
                '.json'
            ));
            players[i].name = botNames[i];
            players[i].creationCode = vm.parseJsonBytes(json, '.bytecode.object');
        }
        (game, playerResults) = _runMatch(players);
        console2.log(string.concat(
            unicode'🏁 Game ended after ',
            vm.toString(game.round()),
            ' rounds:'
        ));
        _printFinalScores(players, playerResults);
    }

    function _runMatch(PlayerInfo[] memory players)
        private returns (Game game, PlayerResult[] memory playerResults)
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
                revert(string.concat(
                    'Player "',
                    players[i].name,
                    '" failed to deploy!'
                ));
            }
        }

        uint256[][] memory prevBalances = new uint256[][](players.length);
        uint8 assetCount = game.assetCount();
        for (uint8 playerIdx; playerIdx < prevBalances.length; ++playerIdx) {
            prevBalances[playerIdx] = new uint256[](assetCount);
        }
        uint8 winnerIdx = INVALID_PLAYER_IDX;
        while (!game.isGameOver()) {
            vm.recordLogs();
            winnerIdx = game.playRound();
            uint256[] memory bids = _extractAuctionResults(
                vm.getRecordedLogs(),
                uint8(players.length)
            );
            _printRoundState(game, players, bids, prevBalances);
            for (uint8 playerIdx; playerIdx < prevBalances.length; ++playerIdx) {
                for (uint8 assetIdx; assetIdx < assetCount; ++assetIdx) {
                    prevBalances[playerIdx][assetIdx] =
                        game.balanceOf(playerIdx, assetIdx);
                }
            }
        }

        playerResults = new PlayerResult[](players.length);
        uint8[] memory scoreAssetIdxs = new uint8[](players.length);
        uint256[] memory scores = game.scorePlayers();
        for (uint8 i; i < playerInstances.length; ++i) {
            for (uint8 j = 1; j < players.length; ++j) {
                if (game.balanceOf(i, j) == scores[i]) {
                    scoreAssetIdxs[i] = j;
                    break;
                }
            }
        }
        uint8[] memory ranking = _rankPlayers(scores);
        assert(winnerIdx == INVALID_PLAYER_IDX || winnerIdx == ranking[0]);
        for (uint256 i; i < players.length; ++i) {
            playerResults[i].playerIdx = ranking[i];
            playerResults[i].player = playerInstances[ranking[i]];
            playerResults[i].score = scores[ranking[i]];
            playerResults[i].scoreAssetIdx = scoreAssetIdxs[ranking[i]];
        }
    }

    function _extractAuctionResults(Vm.Log[] memory logs, uint8 playerCount)
        private returns (uint256[] memory bids)
    {
        bids = new uint256[](playerCount);
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.topics.length == 1) {
                bytes32 sig = log.topics[0];
                if (sig == Game.BlockBid.selector) {
                    (uint8 playerIdx, uint256 bid) =
                        abi.decode(log.data, (uint8, uint256));
                    bids[playerIdx] = bid;
                }
            }
        }
    }

    function _printRoundState(
        Game game,
        PlayerInfo[] memory players,
        uint256[] memory bids,
        uint256[][] memory prevBalances
    ) private {
        console2.log(string.concat('Round ', vm.toString(game.round()), ':'));
        uint8[] memory ranking = _rankPlayers(game.scorePlayers());
        uint8 assetCount = game.assetCount();
        uint8 lastBuidlerIdx = game.lastBuilder();
        for (uint8 i; i < ranking.length; ++i) {
            uint8 playerIdx = ranking[i];
            console2.log(string.concat(
                '\t',
                lastBuidlerIdx == ranking[i] ? '(B) ' : '   ',
                '\x1b[1m',
                players[playerIdx].name,
                '\x1b[0m [',
                vm.toString(playerIdx),
                ']',
                bids[playerIdx] == 0
                    ? ''
                    : string.concat(' (bid ', _toDecimals(bids[playerIdx]), ' ', _toAssetEmoji(0), ')'),
                ':'
            ));
            for (uint8 asset; asset < assetCount; ++asset) {
                uint256 bal = game.balanceOf(playerIdx, asset);
                int128 delta = int128(uint128(bal)) -
                    int128(uint128(prevBalances[playerIdx][asset]));
                console2.log(
                    string.concat(
                        '\t\t',
                        _toAssetEmoji(asset),
                        ' ',
                        _toDecimals(bal),
                        delta != 0
                            ? string.concat(' (', _toDeltaDecimals(delta), ')')
                            : ''
                    )
                );
            }
        }
    }

    function _printFinalScores(
        PlayerInfo[] memory players,
        PlayerResult[] memory playerResults
    )
        private
    {
        for (uint256 i; i < playerResults.length; ++i) {
            string memory bullet = unicode'🥉';
            if (i == 0) {
                bullet = unicode'🏆️';
            } else if (i == 1) {
                bullet = unicode'🥈';
            }
            console2.log(string.concat(
                '\t',
                bullet,
                ' \x1b[1m',
                players[playerResults[i].playerIdx].name,
                '\x1b[0m [',
                vm.toString(playerResults[i].playerIdx),
                ']: ',
                _toDecimals(playerResults[i].score),
                ' ',
                _toAssetEmoji(playerResults[i].scoreAssetIdx),
                ' (',
                vm.toString(playerResults[i].scoreAssetIdx),
                ')'
            ));
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
        uint256 frac = (weis - (whole * 1e18)) / 1e14;
        return string.concat(vm.toString(whole), '.', vm.toString(frac));
    }


    function _toDeltaDecimals(int128 delta)
        private pure returns (string memory dec)
    {
        if (delta < 0) {
            return string.concat('\x1b[31m-', _toDecimals(uint256(uint128(-delta))), '\x1b[0m');
        }
        return string.concat('\x1b[32m+', _toDecimals(uint256(uint128(delta))), '\x1b[0m');
    }

    function _toAssetEmoji(uint8 assetIdx)
        private pure returns (string memory emoji)
    {
        if (assetIdx > 6) return string.concat('$', vm.toString(assetIdx));
        if (assetIdx == 6) return unicode'🍌';
        if (assetIdx == 5) return unicode'🍒';
        if (assetIdx == 4) return unicode'🥑';
        if (assetIdx == 3) return unicode'🐟️';
        if (assetIdx == 2) return unicode'🥖';
        if (assetIdx == 1) return unicode'🍅';
        return unicode'🪙';
    }
}