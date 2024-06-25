// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { Game, IPlayer, INVALID_PLAYER_IDX, MIN_PLAYERS, MAX_PLAYERS } from '~/game/Game.sol';
import { SafeCreate2 } from '~/game/SafeCreate2.sol';
import { GameDeployer } from '~/game/GameDeployer.sol';
import { LibMatchUtils } from '~/game/LibMatchUtils.sol';
import { LibBytes } from '~/game/LibBytes.sol';
import { AssetMarket } from '~/game/Markets.sol';
import { Script } from 'forge-std/Script.sol';
import { console2 } from 'forge-std/console2.sol';
import { Vm } from 'forge-std/Vm.sol';

contract Match is Script {
    using LibBytes for bytes;

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

    struct SwapResult {
        uint8 playerIdx;
        uint8 fromAssetIdx;
        uint8 toAssetIdx;
        uint256 fromAmount;
        uint256 toAmount;
    }

    struct Leak {
        uint8 assetIdx;
        uint256 assetAmount;
    }

    struct RoundState {
        PlayerInfo[] players;
        uint256[] bids;
        uint256[][] prevBalances;
        SwapResult[] swaps;
        uint256[] supply;
        RoundFailureInfo[] failures;
        Leak[] leaks;
    }

    struct RoundFailureInfo {
        uint8 flags;
        bytes buildBlockRevertData;
        bytes createBundleRevertData;
    }

    uint8 constant FAILED_BUNDLE_FLAG = 0x1;
    uint8 constant FAILED_BLOCK_FLAG = 0x2;

    bytes4 ERROR_SELECTOR = bytes4(keccak256('Error(string)'));
    bytes4 PANIC_SELECTOR = bytes4(keccak256('Panic(uint256)'));

    SafeCreate2 sc2;

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
            unicode'\n 🏁 Game ended after ',
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
            RoundState memory rs;
            rs.players = players;
            Vm.Log[] memory logs = vm.getRecordedLogs();
            rs.bids = _extractAuctionResults(
                game,
                logs,
                uint8(players.length)
            );
            rs.failures = _extractFailures(
                game,
                logs,
                uint8(players.length),
                game.lastBuilder()
            );
            rs.leaks = _extractLeaks(game, logs);
            rs.swaps = _extractSwaps(game, logs);
            rs.supply = game.marketState();
            rs.prevBalances = prevBalances;
            _printRoundState(game, rs);
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

    function _extractAuctionResults(
        Game game,
        Vm.Log[] memory logs,
        uint8 playerCount
    )
        private returns (uint256[] memory bids)
    {
        bids = new uint256[](playerCount);
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter == address(game) && log.topics.length == 1) {
                bytes32 sig = log.topics[0];
                if (sig == Game.BlockBid.selector) {
                    (uint8 playerIdx, uint256 bid) =
                        abi.decode(log.data, (uint8, uint256));
                    bids[playerIdx] = bid;
                }
            }
        }
    }

    function _extractFailures(
        Game game,
        Vm.Log[] memory logs,
        uint8 playerCount,
        uint8 roundBuilder
    )
        private returns (RoundFailureInfo[] memory failures)
    {
        failures = new RoundFailureInfo[](playerCount);
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter == address(game) && log.topics.length == 1) {
                bytes32 sig = log.topics[0];
                if (sig == Game.CreateBundleFailed.selector) {
                    (uint8 playerIdx, uint8 builderIdx, bytes memory revertData) =
                        abi.decode(log.data, (uint8, uint8, bytes));
                    if (builderIdx == roundBuilder) {
                        failures[playerIdx].flags |= FAILED_BUNDLE_FLAG;
                        failures[playerIdx].createBundleRevertData = revertData;
                    }
                } else if (sig == Game.BuildPlayerBlockFailed.selector) {
                    (uint8 playerIdx, bytes memory revertData) =
                        abi.decode(log.data, (uint8, bytes));
                    failures[playerIdx].flags |= FAILED_BLOCK_FLAG;    
                    failures[playerIdx].buildBlockRevertData = revertData;
                }
            }
        }
    }

    function _extractLeaks(Game game, Vm.Log[] memory logs)
        private returns (Leak[] memory leaks)
    {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter == address(game) && log.topics.length == 1) {
                bytes32 sig = log.topics[0];
                if (sig != Game.Leaked.selector) {
                    continue;
                }
                ++count;
            }
        }
        leaks = new Leak[](count);
        uint256 o;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter == address(game) && log.topics.length == 1) {
                bytes32 sig = log.topics[0];
                if (sig != Game.Leaked.selector) {
                    continue;
                }
                Leak memory leak;
                (leak.assetIdx, leak.assetAmount) =
                    abi.decode(log.data, (uint8, uint256));
                leaks[o++] = leak;
            }
        }
    }

    function _extractSwaps(Game game, Vm.Log[] memory logs)
        private returns (SwapResult[] memory swaps)
    {
        if (logs.length == 0) {
            return swaps;
        }
        uint256 o = logs.length;
        uint256 count;
        // Walk logs in reverse to find the end of simulated blocks.
        for (; o > 0; --o) {
            Vm.Log memory log = logs[o - 1];
            if (log.emitter == address(game) && log.topics.length == 1) {
                bytes32 sig = log.topics[0];
                if (sig == Game.EmptyBlock.selector) {
                    return swaps;
                }
                if (sig == Game.BlockBid.selector) {
                    // Found the last bid. Everything after actually occured.
                    ++o;
                    break;
                }
                if (sig == Game.Swap.selector) {
                    ++count;
                } else if (log.topics[0] == Game.BundleSettled.selector) {
                    (, bool success) =
                        abi.decode(log.data, (uint8, bool));
                    if (!success) {
                        ++count;
                    }
                }
            }
        }
        swaps = new SwapResult[](count);
        uint256 pos;
        for (uint256 i = o; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter == address(game) && log.topics.length == 1) {
                if (log.topics[0] == Game.Swap.selector) {
                    SwapResult memory swap;
                    (
                        swap.playerIdx,
                        swap.fromAssetIdx,
                        swap.toAssetIdx,
                        swap.fromAmount,
                        swap.toAmount
                    ) = abi.decode(log.data, (uint8, uint8, uint8, uint256, uint256));
                    swaps[pos++] = swap;
                } else if (log.topics[0] == Game.BundleSettled.selector) {
                    (uint8 playerIdx, bool success) =
                        abi.decode(log.data, (uint8, bool));
                    if (!success) {
                        SwapResult memory swap;
                        swap.playerIdx = playerIdx;
                        swap.fromAssetIdx = INVALID_PLAYER_IDX;
                        swaps[pos++] = swap;
                    }
                }
            }
        }
    }

    function _printRoundState(
        Game game,
        RoundState memory rs 
    ) private {
        console2.log(string.concat('\x1b[1mRound ', vm.toString(game.round()), '\x1b[0m:'));
        uint8[] memory ranking = _rankPlayers(game.scorePlayers());
        uint8 assetCount = game.assetCount();
        uint8 lastBuidlerIdx = game.lastBuilder();
        for (uint8 i; i < ranking.length; ++i) {
            uint8 playerIdx = ranking[i];
            console2.log(string.concat(
                '\t',
                lastBuidlerIdx == ranking[i] ? '(B) ' : '   ',
                rs.failures[playerIdx].flags != 0 ? '\x1b[31m' : '\x1b[1m',
                rs.players[playerIdx].name,
                '\x1b[0m [',
                vm.toString(playerIdx),
                ']',
                rs.bids[playerIdx] == 0
                    ? ''
                    : string.concat(
                        ' (bid ',
                        _toAssetEmoji(0),
                        ' ',
                        _toDecimals(rs.bids[playerIdx]),
                        ')'
                    ),
                ':'
            ));
            if (rs.failures[playerIdx].flags & FAILED_BLOCK_FLAG != 0) {
                console2.log(string.concat(
                    unicode'\t\t⚠️  \x1b[31mFailed to build block with error: ',
                    _humanizeErrorData(rs.failures[playerIdx].buildBlockRevertData),
                    '\x1b[0m'
                ));
            }
            for (uint8 asset; asset < assetCount; ++asset) {
                uint256 bal = game.balanceOf(playerIdx, asset);
                uint256 prevBal = rs.prevBalances[playerIdx][asset];
                if (bal == 0 && prevBal == 0) {
                    continue;
                }
                int128 delta = int128(uint128(bal)) -
                    int128(uint128(rs.prevBalances[playerIdx][asset]));
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
        {
            console2.log('\n\x1b[1m\tMarket Supply\x1b[0m:');
            string memory stringPrices = '\t\t';
            for (uint8 asset; asset < rs.supply.length; ++asset) {
                stringPrices = string.concat(
                    stringPrices,
                    _toAssetEmoji(asset),
                    ' ',
                    _toDecimals(rs.supply[asset]),
                    asset < rs.supply.length - 1 ? ', ' : ''
                );
            }
            console2.log(stringPrices);
        }
        console2.log('\n\t\t======ROUND ACTIVITY======\n');
        for (uint8 playerIdx; playerIdx < rs.players.length; ++playerIdx) {
            if (rs.failures[playerIdx].flags & FAILED_BUNDLE_FLAG != 0) {
                console2.log(string.concat(
                    unicode'\t\t\x1b[31m ⚠️  ',
                    rs.players[playerIdx].name,
                    ' failed to create bundle with error: ',
                    _humanizeErrorData(rs.failures[playerIdx].createBundleRevertData),
                    '\x1b[0m'
                ));
            }
        }
        console2.log('');
        if (rs.swaps.length == 0) {
            console2.log('\t\t<EMPTY BLOCK>');
        } else {
            for (uint256 i; i < rs.swaps.length; ++i) {
                uint8 playerIdx = rs.swaps[i].playerIdx;
                console2.log(string.concat(
                    '\t\t',
                    lastBuidlerIdx == playerIdx ? '(B) ' : '    ',
                    '\x1b[1m',
                    rs.players[playerIdx].name,
                    '\x1b[0m sold:'
                ));
                for (; i < rs.swaps.length; ++i) {
                    SwapResult memory swap = rs.swaps[i];
                    if (swap.playerIdx != playerIdx) {
                        --i;
                        break;
                    }
                    if (swap.fromAssetIdx == INVALID_PLAYER_IDX) {
                        console2.log(string.concat(
                            '\t\t\t',
                            '\x1b[31mBundle failed!\x1b[0m'
                        ));
                    } else {
                        console2.log(
                            string.concat(
                                '\t\t\t',
                                _toAssetEmoji(swap.fromAssetIdx),
                                ' ',
                                _toDecimals(swap.fromAmount),
                                unicode' ⇾ ',
                                _toAssetEmoji(swap.toAssetIdx),
                                ' ',
                                _toDecimals(swap.toAmount)
                            )
                        );
                    }
                }
            }
        }
        if (rs.leaks.length != 0) {
            string memory s = unicode'\n\t\t🔥 Burned ';
            for (uint256 i; i < rs.leaks.length; ++i) {
                Leak memory leak = rs.leaks[i];
                s = string.concat(
                    s,
                    _toAssetEmoji(leak.assetIdx),
                    ' ',
                    _toDecimals(leak.assetAmount),
                    i == rs.leaks.length - 1 ? '' : ', '
                );
            }
            s = string.concat(s, ' from the market');
            console2.log(s);
        }
    }

    function _humanizeErrorData(bytes memory errorData)
        private returns (string memory s)
    {
        bytes4 selector = errorData.getSelectorOr(bytes4(0));
        if (selector == ERROR_SELECTOR) {
            return abi.decode(errorData.slice(4), (string));
        }
        if (selector == PANIC_SELECTOR) {
            uint256 code = abi.decode(errorData.slice(4), (uint256));
            if (code == 0x01) {
                return 'assert failed';
            }
            if (code == 0x11) {
                return 'under/overflow';
            }
            if (code == 0x12) {
                return 'division by zero';
            }
            if (code == 0x21) {
                return 'conversion error';
            }
            if (code == 0x31) {
                return 'pop empty array';
            }
            if (code == 0x32) {
                return 'out of bounds';
            }
            return 'panic';
        }
        if (selector == Game.BuildBlockFailedError.selector) {
            (, bytes memory innerData) = abi.decode(errorData.slice(4), (uint8, bytes));
            return _humanizeErrorData(innerData);
        }
        if (selector == Game.BundleNotSettledError.selector) {
            (, uint8 bundleIdx) = abi.decode(errorData.slice(4), (uint8, uint8));
            return string.concat(
                'Did not settle bundle ',
                vm.toString(bundleIdx)
            );
        }
        if (selector == Game.InsufficientBalanceError.selector) {
            (, uint8 assetIdx) = abi.decode(errorData.slice(4), (uint8, uint8));
            return string.concat(
                'Insufficient balance of asset ',
                _toAssetEmoji(assetIdx)
            );
        }
        if (selector == Game.TooManySwapsError.selector) {
            return 'Too many swaps in bundle';
        }
        if (selector == AssetMarket.InsufficientLiquidityError.selector) {
            return 'Insufficient liquidity';
        }
        if (selector == Game.AccessError.selector) {
            return 'Access Error';
        }
        return vm.toString(errorData);
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
                _toAssetEmoji(playerResults[i].scoreAssetIdx),
                ' ',
                _toDecimals(playerResults[i].score),
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
        uint256 frac = (weis - (whole * 1e18) + 1e18) / 1e14;
        string memory fracStr = '0';
        if (frac != 1e4) {
            fracStr = vm.toString(frac);
            assembly ("memory-safe") {
                let len := mload(fracStr)
                fracStr := add(fracStr, 1)
                mstore(fracStr, sub(len, 1))
            }
        }
        return string.concat(vm.toString(whole), '.', fracStr);
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