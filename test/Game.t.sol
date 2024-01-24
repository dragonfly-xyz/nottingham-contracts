// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { Test } from "forge-std/Test.sol";
import { LibTestUtils as T } from "./LibTestUtils.sol";
import {
    Game,
    NULL_PLAYER,
    getIndexFromPlayer,
    MAX_PLAYERS,
    MAX_ROUNDS,
    MIN_WINNING_ASSET_BALANCE,
    GOLD_IDX,
    INVALID_PLAYER_IDX,
    INCOME_AMOUNT
} from "~/Game.sol";
import { IPlayer } from "~/IPlayer.sol";
import { LibBytes } from "~/LibBytes.sol";

event PlayerCreated(address self, uint8 playerIdx, uint8 playerCount);
event Building(uint16 round, uint256 goldBalance);

contract GameTest is Test {

    function test_deploysPlayersWithArgs() external {
        address gameAddress = _getNextDeployAddress();
        uint256 playerCount = T.randomUint256() % 5 + 2;
        bytes[] memory creationCodes = new bytes[](playerCount);
        for (uint256 i; i < playerCount; ++i) {
            creationCodes[i] = type(NoopPlayer).creationCode;
        }
        (uint256[] memory salts, IPlayer[] memory players) = _minePlayers(gameAddress, creationCodes);
        for (uint256 i; i < playerCount; ++i) {
            assertEq(uint160(address(players[i])) & 7, i);
            vm.expectEmit(true, true, true, true);
            emit PlayerCreated(address(players[i]), uint8(i), uint8(playerCount));
        }
        Game game = new Game(creationCodes, salts);
        assertEq(address(game), gameAddress); 
    }

    function test_createsNAssets() external {
        uint256 playerCount = T.randomUint256() % 5 + 2;
        bytes[] memory creationCodes = new bytes[](playerCount);
        for (uint256 i; i < playerCount; ++i) {
            creationCodes[i] = type(NoopPlayer).creationCode;
        }
        (Game game,) = _createGame(creationCodes);
        assertEq(game.ASSET_COUNT(), playerCount);
    }

    function test_cannotDeployGameWithLessThanTwoPlayers() external {
        bytes[] memory creationCodes = new bytes[](1);
        uint256[] memory salts = new uint256[](1);
        vm.expectRevert(abi.encodeWithSelector(Game.GameSetupError.selector, ('# of players')));
        new Game(creationCodes, salts);
    }

    function test_cannotDeployGameWithMoreThanEightPlayers() external {
        bytes[] memory creationCodes = new bytes[](9);
        uint256[] memory salts = new uint256[](9);
        vm.expectRevert(abi.encodeWithSelector(Game.GameSetupError.selector, ('# of players')));
        new Game(creationCodes, salts);
    }

    function test_cannotDeployGameWithFailingPlayerInitCode() external {
        bytes[] memory creationCodes = new bytes[](2);
        creationCodes[0] = hex'fe';
        uint256[] memory salts = new uint256[](2);
        vm.expectRevert(LibBytes.Create2FailedError.selector);
        new Game(creationCodes, salts);
    }
    
    function test_canPlayRoundWithRevertingPlayers() external {
        (Game game,) = _createGame(T.toDynArray([
            type(RevertingPlayer).creationCode,
            type(RevertingPlayer).creationCode
        ]));
        uint8 winnerIdx = game.playRound();
        assertEq(winnerIdx, INVALID_PLAYER_IDX);
    }

    function test_canCompleteGameWithNoopPlayers() external {
        (Game game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 winnerIdx;
        while (true) {
            winnerIdx = game.playRound();
            if (winnerIdx != INVALID_PLAYER_IDX) break;
        }
        assertEq(winnerIdx, 0);
        (uint8 assetIdx, uint256 bal) = _getMaxNonGoldAssetBalance(game, winnerIdx);
        assertTrue(assetIdx != GOLD_IDX);
        assertGe(bal, MIN_WINNING_ASSET_BALANCE);
        assertTrue(game.isGameOver());
    }

    function test_canCompleteGameWithDonatingPlayer() external {
        (Game game,) = _createGame(T.toDynArray([
            type(DonatingPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 winnerIdx;
        while (true) {
            winnerIdx = game.playRound();
            if (winnerIdx != INVALID_PLAYER_IDX) break;
        }
        assertEq(winnerIdx, 1);
        (uint8 assetIdx, uint256 bal) = _getMaxNonGoldAssetBalance(game, winnerIdx);
        assertEq(assetIdx, GOLD_IDX + 1);
        assertGe(bal, MIN_WINNING_ASSET_BALANCE);
        assertEq(game.round(), MAX_ROUNDS / 2 - 1);
        assertTrue(game.isGameOver());
    }

    function test_cannotPlayAnotherRoundAfterWinnerDeclared() external {
        (Game game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 winnerIdx;
        while (true) {
            winnerIdx = game.playRound();
            if (winnerIdx != INVALID_PLAYER_IDX) break;
        }
        assertEq(winnerIdx, 0);
        (uint8 assetIdx, uint256 bal) = _getMaxNonGoldAssetBalance(game, winnerIdx);
        assertTrue(assetIdx != GOLD_IDX);
        assertGe(bal, MIN_WINNING_ASSET_BALANCE);
        assertTrue(game.isGameOver());
        vm.expectRevert(Game.GameOverError.selector);
        game.playRound();
    }

    function test_gameEndsEarlyIfWinnerFound() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setMockWinner(players[1]);
        uint8 winnerIdx = game.playRound();
        assertEq(winnerIdx, 1);
        assertTrue(game.isGameOver());
    }

    function test_auctionWinnerBuildsBlock() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(EmitBuilderPlayer).creationCode
        ]));
        game.setMockBlockBuilder(players[1], 1337);
        vm.expectCall(address(players[0]), abi.encodeCall(IPlayer.buildBlock, ()), 0);
        vm.expectEmit(true, true, true, true, address(players[1]));
        emit Building(0, INCOME_AMOUNT);
        game.playRound();
        assertEq(game.balanceOf(1, GOLD_IDX), INCOME_AMOUNT - 1337);
    }

    function test_panicsIfBuilderBidsWithDifferentBidThanAuction() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(EmitBuilderPlayer).creationCode
        ]));
        game.setMockBlockBuilder(players[1], 1338);
        vm.expectRevert();
        game.playRound();
    }

    function test_failsIfBuilderDoesNotIncludeOtherPlayers() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(EmitBuilderPlayer).creationCode
        ]));
        EmitBuilderPlayer(address(players[1])).ignorePlayer(players[0]);
        game.setMockBlockBuilder(players[1], 1337);
        vm.expectRevert(abi.encodeWithSelector(Game.PlayerMissingFromBlockError.selector, 1));
        game.playRound();
    }

    // function test_auctionIgnoresBuilderThatDoesNotIncludeAll() external {
    //     (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
    //         type(NoopPlayer).creationCode,
    //         type(EmitBuilderPlayer).creationCode
    //     ]));
    //     game.setMockBlockBuilder(players[1], 1337);
    //     vm.expectCall(address(players[0]), abi.encodeCall(IPlayer.buildBlock, ()), 0);
    //     vm.expectEmit(true, true, true, true, address(players[1]));
    //     emit Building(0, INCOME_AMOUNT);
    //     game.playRound();
    //     assertEq(game.balanceOf(1, GOLD_IDX), INCOME_AMOUNT - 1337);
    // }

    function _createGame(bytes[] memory playerCreationCodes)
        private returns (TestGame game, IPlayer[] memory players)
    {
        uint256[] memory salts;
        (salts, players) = _minePlayers(_getNextDeployAddress(), playerCreationCodes);
        game = new TestGame(playerCreationCodes, salts);
    }

    function _minePlayers(address deployer, bytes[] memory playerCreationCodes)
        private view returns (uint256[] memory salts, IPlayer[] memory players)
    {
        salts = new uint256[](playerCreationCodes.length);
        players = new IPlayer[](playerCreationCodes.length);
        for (uint256 i; i < playerCreationCodes.length; ++i) {
            (salts[i], players[i]) = _findPlayerSaltAndAddress(
                playerCreationCodes[i],
                deployer,
                uint8(i),
                uint8(playerCreationCodes.length)
            );
        }
    }

    function _findPlayerSaltAndAddress(
        bytes memory creationCode,
        address deployer,
        uint8 playerIdx,
        uint8 playerCount
    )
        internal view returns (uint256 salt, IPlayer player)
    {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(creationCode, abi.encode(playerIdx, playerCount)));
        unchecked {
            for (salt = T.randomUint256(); true; ++salt) {
                address addr = T.getCreate2Address(initCodeHash, deployer, salt);
                if ((uint160(addr) & 7) == playerIdx) {
                    return (salt, IPlayer(addr));
                }
            }
        }
    }

    function _getNextDeployAddress() internal view returns (address) {
        return T.getCreateAddress(address(this), vm.getNonce(address(this)));
    }

    function _getMaxAssetBalance(Game game, uint8 playerIdx)
        internal view returns (uint8 maxAssetIdx, uint256 maxAssetBal)
    {
        uint8 assetCount = game.ASSET_COUNT();
        for (uint8 i; i < assetCount; ++i) {
            uint256 bal = game.balanceOf(playerIdx, i);
            if (bal > maxAssetBal) {
                maxAssetIdx = i;
                maxAssetBal = bal;
            }
        }
    }

    function _getMaxNonGoldAssetBalance(Game game, uint8 playerIdx)
        internal view returns (uint8 maxAssetIdx, uint256 maxAssetBal)
    {
        maxAssetIdx = GOLD_IDX + 1;
        uint8 assetCount = game.ASSET_COUNT();
        for (uint8 i = GOLD_IDX + 1; i < assetCount; ++i) {
            uint256 bal = game.balanceOf(playerIdx, i);
            if (bal > maxAssetBal) {
                maxAssetIdx = i;
                maxAssetBal = bal;
            }
        }
    }
}

contract TestGame is Game {
    IPlayer public mockWinner;
    IPlayer public mockBuilder;
    uint256 public mockBuilderBid;

    constructor(bytes[] memory playerCreationCodes, uint256[] memory deploySalts)
        Game(playerCreationCodes, deploySalts)
    {}

    function setMockWinner(IPlayer winner) external {
        _assertValidPlayer(winner);
        mockWinner = winner;
    }

    function setMockBlockBuilder(IPlayer builder, uint256 bid) external {
        _assertValidPlayer(builder);
        mockBuilder = builder;
        mockBuilderBid = bid;
    }

    function _auctionBlock(IPlayer[] memory players)
        internal override returns (uint8 builderIdx, uint256 builderBid)
    {
        if (mockBuilder != NULL_PLAYER) {
            return (getIndexFromPlayer(mockBuilder), mockBuilderBid);
        }
        return Game._auctionBlock(players);
    }

    function _findWinner(uint8 playerCount_, uint16 round_)
        internal override view returns (IPlayer winner)
    {
        if (mockWinner != NULL_PLAYER) {
            return mockWinner;
        }
        return Game._findWinner(playerCount_, round_);
    }

    function _assertValidPlayer(IPlayer player) private view {
        assert(_playerByIdx[getIndexFromPlayer(player)] == player);
    }
}

contract NoopPlayer is IPlayer {
    uint8 public PLAYER_IDX;
    uint8 immutable PLAYER_COUNT;

    constructor(uint8 playerIdx, uint8 playerCount) {
        PLAYER_IDX = playerIdx;
        PLAYER_COUNT = playerCount;
        emit PlayerCreated(address(this), playerIdx, playerCount);
    }

    function turn(uint8) external virtual {}
    function buildBlock() external virtual returns (uint256) {}
}

contract DonatingPlayer is NoopPlayer {
    constructor(uint8 playerIdx, uint8 playerCount) NoopPlayer(playerIdx, playerCount) {}

    function turn(uint8) external override {
        Game game = Game(msg.sender);
        uint8 assetCount = game.ASSET_COUNT();
        for (uint8 assetIdx = 1; assetIdx < assetCount; ++assetIdx) {
            // Always donate to last player.
            game.transfer(
                PLAYER_COUNT - 1,
                assetIdx,
                game.balanceOf(PLAYER_IDX, assetIdx)
            );
        }
    }
}

contract RevertingPlayer is NoopPlayer {
    constructor(uint8 playerIdx, uint8 playerCount) NoopPlayer(playerIdx, playerCount) {}
    function turn(uint8) external override pure { T.throwInvalid(); }
    function buildBlock() external override pure returns (uint256) { T.throwInvalid(); }
}

contract EmitBuilderPlayer is NoopPlayer {
    IPlayer public ignoredPlayer;
    constructor(uint8 playerIdx, uint8 playerCount) NoopPlayer(playerIdx, playerCount) {}

    function buildBlock() external override returns (uint256) {
        Game game = Game(msg.sender);
        emit Building(game.round(), game.balanceOf(PLAYER_IDX, GOLD_IDX));
        for (uint8 i; i < PLAYER_COUNT; ++i) {
            if (ignoredPlayer != NULL_PLAYER && getIndexFromPlayer(ignoredPlayer) == i) continue;
            game.grantTurn(i);
        }
        return 1337;
    }

    function ignorePlayer(IPlayer player) external {
        ignoredPlayer = player;
    }
}