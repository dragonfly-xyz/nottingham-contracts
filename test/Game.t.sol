// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { Test } from "forge-std/Test.sol";
import { LibTestUtils as T } from "./LibTestUtils.sol";
import { Game } from "~/Game.sol";
import { IPlayer } from "~/IPlayer.sol";
import { LibBytes } from "~/LibBytes.sol";

event PlayerCreated(address self, uint8 playerIdx, uint8 playerCount);

contract GameTest is Test {
    uint256 constant MAX_PLAYERS = 8;
    uint8 constant MAX_ROUNDS = 101;
    uint256 constant MIN_WINNING_ASSET_BALANCE = 100e18;
    uint8 constant GOLD_IDX = 0;
    uint8 constant INVALID_PLAYER_IDX = type(uint8).max;

    function testDeploysPlayersWithArgs() external {
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

    // testCreatesNAssets()

    function testCannotDeployGameWithLessThanTwoPlayers() external {
        bytes[] memory creationCodes = new bytes[](1);
        uint256[] memory salts = new uint256[](1);
        vm.expectRevert(abi.encodeWithSelector(Game.GameSetupError.selector, ('# of players')));
        new Game(creationCodes, salts);
    }

    function testCannotDeployGameWithMoreThanEightPlayers() external {
        bytes[] memory creationCodes = new bytes[](9);
        uint256[] memory salts = new uint256[](9);
        vm.expectRevert(abi.encodeWithSelector(Game.GameSetupError.selector, ('# of players')));
        new Game(creationCodes, salts);
    }

    function testCannotDeployGameWithFailingPlayerInitCode() external {
        bytes[] memory creationCodes = new bytes[](2);
        creationCodes[0] = hex'fe';
        uint256[] memory salts = new uint256[](2);
        vm.expectRevert(LibBytes.Create2FailedError.selector);
        new Game(creationCodes, salts);
    }
    
    function testCanPlayRoundWithRevertingPlayers() external {
        (Game game,) = _createGame(T.toDynArray([
            type(RevertingPlayer).creationCode,
            type(RevertingPlayer).creationCode
        ]));
        uint8 winnerIdx = game.playRound();
        assertEq(winnerIdx, INVALID_PLAYER_IDX);
    }

    function testCanCompleteGameWithNoopPlayers() external {
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
    }

    function testCanCompleteGameWithDonatingPlayer() external {
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
    }

    function _createGame(bytes[] memory playerCreationCodes)
        private returns (Game game, IPlayer[] memory players)
    {
        uint256[] memory salts;
        (salts, players) = _minePlayers(_getNextDeployAddress(), playerCreationCodes);
        game = new Game(playerCreationCodes, salts);
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
        uint8 assetCount = game.assetCount();
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
        uint8 assetCount = game.assetCount();
        for (uint8 i = GOLD_IDX + 1; i < assetCount; ++i) {
            uint256 bal = game.balanceOf(playerIdx, i);
            if (bal > maxAssetBal) {
                maxAssetIdx = i;
                maxAssetBal = bal;
            }
        }
    }
}

contract NoopPlayer is IPlayer {
    constructor(uint8 playerIdx, uint8 playerCount) {
        emit PlayerCreated(address(this), playerIdx, playerCount);
    }

    function turn(uint8) external {}
    function buildBlock() external returns (uint256) {}
}

contract DonatingPlayer is IPlayer {
    uint8 immutable PLAYER_IDX;
    uint8 immutable PLAYER_COUNT;

    constructor(uint8 playerIdx, uint8 playerCount) {
        PLAYER_IDX = playerIdx;
        PLAYER_COUNT = playerCount;
    }

    function turn(uint8) external {
        Game game = Game(msg.sender);
        uint8 assetCount = game.assetCount();
        for (uint8 assetIdx = 1; assetIdx < assetCount; ++assetIdx) {
            // Always donate to last player.
            game.transfer(
                PLAYER_COUNT - 1,
                assetIdx,
                game.balanceOf(PLAYER_IDX, assetIdx)
            );
        }
    }

    function buildBlock() external returns (uint256) {}
}

contract RevertingPlayer is IPlayer {
    function turn(uint8) external pure { T.throwInvalid(); }
    function buildBlock() external pure returns (uint256) { T.throwInvalid(); }
}