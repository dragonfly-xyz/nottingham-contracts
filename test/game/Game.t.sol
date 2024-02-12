// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { Vm, Test } from "forge-std/Test.sol";
import { LibTestUtils as T } from "../LibTestUtils.sol";
import {
    Game,
    NULL_PLAYER,
    getIndexFromPlayer,
    MAX_PLAYERS,
    MAX_ROUNDS,
    MIN_WINNING_ASSET_BALANCE,
    GOLD_IDX,
    INVALID_PLAYER_IDX,
    INCOME_AMOUNT,
    MAX_BUILD_GAS,
    DEFAULT_BUILDER
} from "~/game/Game.sol";
import { AssetMarket } from "~/game/Markets.sol";
import { IPlayer } from "~/game/IPlayer.sol";
import { LibBytes } from "~/game/LibBytes.sol";
import { SafeCreate2 } from "~/game/SafeCreate2.sol";

enum RevertMode {
    None,
    Revert,
    Invalid
}

using LibBytes for bytes;

event PlayerCreated(address self, uint8 playerIdx, uint8 playerCount);
event Turning(uint16 round, uint8 playerIdx, uint8 builderIdx);
event Building(uint16 round, uint8 playerIdx);
error TestError();
event TurnState(uint8 playerIdx, uint8 builderIdx, bytes32 h);
event BuildBlockState(uint8 builderIdx, bytes32 h);

bytes32 constant TURN_STATE_EVENT_SIGNATURE = keccak256('TurnState(uint8,uint8,bytes32)');
bytes32 constant BUILD_BLOCK_EVENT_SIGNATURE = keccak256('BuildBlockState(uint8,bytes32)');

function isAddressCold(address addr) view returns (bool isCold) {
    assembly ("memory-safe") {
        let g := gas()
        pop(staticcall(gas(), addr, 0, 0, 0, 0))
        g := sub(g, gas())
        isCold := gt(g, 200)
    }
}

contract GameTest is Test {
    SafeCreate2 sc2 = new SafeCreate2();

    function test_deploysPlayersWithArgs() external {
        address gameAddress = _getNextDeployAddress();
        uint256 playerCount = T.randomUint256() % 5 + 2;
        bytes[] memory creationCodes = new bytes[](playerCount);
        for (uint256 i; i < playerCount; ++i) {
            creationCodes[i] = type(NoopPlayer).creationCode;
        }
        (uint256[] memory salts, IPlayer[] memory players) = _minePlayers(Game(gameAddress), creationCodes);
        for (uint256 i; i < playerCount; ++i) {
            assertEq(uint160(address(players[i])) & 7, i);
            vm.expectEmit(true, true, true, true);
            emit PlayerCreated(address(players[i]), uint8(i), uint8(playerCount));
        }
        Game game = new Game(address(this), sc2, creationCodes, salts);
        assertEq(address(game), gameAddress); 
    }

    function test_createsNAssets() external {
        uint256 playerCount = T.randomUint256() % 5 + 2;
        bytes[] memory creationCodes = new bytes[](playerCount);
        for (uint256 i; i < playerCount; ++i) {
            creationCodes[i] = type(NoopPlayer).creationCode;
        }
        (Game game,) = _createGame(creationCodes);
        assertEq(game.assetCount(), playerCount);
    }

    function test_cannotDeployGameWithLessThanTwoPlayers() external {
        bytes[] memory creationCodes = new bytes[](1);
        uint256[] memory salts = new uint256[](1);
        vm.expectRevert(abi.encodeWithSelector(Game.GameSetupError.selector, ('# of players')));
        new Game(address(this), sc2, creationCodes, salts);
    }

    function test_cannotDeployGameWithMoreThanEightPlayers() external {
        bytes[] memory creationCodes = new bytes[](9);
        uint256[] memory salts = new uint256[](9);
        vm.expectRevert(abi.encodeWithSelector(Game.GameSetupError.selector, ('# of players')));
        new Game(address(this), sc2, creationCodes, salts);
    }

    function test_canDeployGameWithFailingPlayerInitCode() external {
        bytes[] memory creationCodes = new bytes[](2);
        creationCodes[0] = hex'fe';
        (uint256[] memory salts, ) = _minePlayers(Game(_getNextDeployAddress()), creationCodes);
        vm.expectEmit(true, true, true, true);
        emit Game.CreatePlayerFailed(0);
        new Game(address(this), sc2, creationCodes, salts);
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

    function test_distributeIncome_givesOneEtherOfEveryAssetToEveryPlayer() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 assetCount = game.assetCount();
        for (uint8 playerIdx; playerIdx < players.length; ++playerIdx) {
            for (uint8 assetIdx; assetIdx < assetCount; ++assetIdx) {
                assertEq(game.balanceOf(playerIdx, assetIdx), 0);
            }
        }
        for (uint256 i; i < 3; ++i) {
            game.__distributeIncome();
            for (uint8 playerIdx; playerIdx < players.length; ++playerIdx) {
                for (uint8 assetIdx; assetIdx < assetCount; ++assetIdx) {
                    assertEq(game.balanceOf(playerIdx, assetIdx), 1 ether * (i + 1));
                }
            }
        }
    }

    function test_findWinner_whenBelowMaxRoundsAndPlayerHas100OfANonGoldAsset_returnsThatPlayer() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setRound(MAX_ROUNDS - 1);
        uint8 assetIdx = uint8(1 + T.randomUint256() % (game.assetCount() - 1));
        game.mintAssetTo(players[1], assetIdx, 100 ether);
        uint8 winnerIdx = game.findWinner();
        assertEq(winnerIdx, 1);
    }

    function test_findWinner_whenBelowMaxRoundsAndNoPlayerHas100OfANonGoldAsset_returnsNoWinner() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setRound(MAX_ROUNDS - 1);
        uint8 assetIdx = uint8(1 + T.randomUint256() % (game.assetCount() - 1));
        game.mintAssetTo(players[1], assetIdx, 1 ether - 1);
        uint8 winnerIdx = game.findWinner();
        assertEq(winnerIdx, INVALID_PLAYER_IDX);
    }

    function test_findWinner_whenAtMaxRoundsAndNoPlayerHas100OfANonGoldAsset_returnsPlayerWithMaxBalance() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setRound(MAX_ROUNDS);
        uint8 assetIdx = uint8(1 + T.randomUint256() % (game.assetCount() - 1));
        game.mintAssetTo(players[1], assetIdx, 1 ether - 1);
        uint8 winnerIdx = game.findWinner();
        assertEq(winnerIdx, 1);
    }

    function test_findWinner_whenAtMaxRoundsAndEveryPlayerHasZeroOfANonGoldAsset_returnsNoWinner() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setRound(MAX_ROUNDS);
        uint8 winnerIdx = game.findWinner();
        assertEq(winnerIdx, INVALID_PLAYER_IDX);
    }

    function test_playRound_WinnerBuildsBlock() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        TestPlayer builder = TestPlayer(address(players[1]));
        builder.setBid(1337);
        game.setMockBlockAuctionWinner(players[1], 1337);
        vm.expectCall(address(players[0]), abi.encodeCall(IPlayer.buildBlock, ()), 0);
        vm.expectEmit(true, true, true, true, address(players[1]));
        emit Building(0, 1);
        game.playRound();
        assertEq(game.balanceOf(1, GOLD_IDX), INCOME_AMOUNT - 1337);
    }

    function test_buildBlock_buildsDefaultBlockIfWinningBidIsZero() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        NoopPlayer ignoredBuilder = NoopPlayer(address(players[1]));
        uint16 round = game.round();
        for (uint8 playerIdx; playerIdx < players.length; ++playerIdx) {
            vm.expectEmit(true, true, true, true, address(players[playerIdx]));
            emit Turning(round, playerIdx, INVALID_PLAYER_IDX);
        }
        vm.expectEmit(true, true, true, true, address(game));
        emit Game.DefaultBlockBuilt(0);
        game.__buildBlock(ignoredBuilder, 0);
    }

    function test_buildBlock_buildsPlayerBlockIfWinningBidIsNonZero() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        TestPlayer builder = TestPlayer(address(players[1]));
        builder.setBid(1);
        game.mintAssetTo(builder, GOLD_IDX, 1);
        vm.expectEmit(true, true, true, true);
        emit Game.PlayerBlockBuilt(0, 1);
        game.__buildBlock(builder, 1);
    }

    function test_buildBlock_defaultBlockPlaysAllPlayersInRoundRobinFashion() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        for (uint16 round; round < players.length + 1; ++round) {
            game.setRound(round);
            for (uint8 i; i < players.length; ++i) {
                uint8 playerIdx = uint8((round + i) % players.length);
                vm.expectEmit(true, true, true, true, address(players[playerIdx]));
                emit Turning(round, playerIdx, INVALID_PLAYER_IDX);
            }
            vm.expectEmit(true, true, true, true);
            emit Game.DefaultBlockBuilt(round);
            game.__buildBlock(players[0], 0);
        }
    }

    function test_buildBlock_canIncludeRevertingPlayerInDefaultBlock() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(RevertingPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        vm.expectEmit(true, true, true, true);
        emit Game.DefaultBlockBuilt(0);
        game.__buildBlock(NULL_PLAYER, 0);
    }

    // This state should be unreachable under normal conditions because the auction
    // process will filter out this activity.
    function test_buildBlock_panicsIfBuilderBidsWithDifferentBidThanAuction() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        TestPlayer builder = TestPlayer(address(players[1]));
        builder.setBid(1337);
        vm.expectRevert();
        game.__buildBlock(builder, 1337);
    }

    function test_buildPlayerBlock_cannotIncludePlayerMoreThanOnce() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(DoubleIncludePlayer).creationCode
        ]));
        vm.expectRevert(abi.encodeWithSelector(
            Game.PlayerBuildBlockFailedError.selector,
            1,
            abi.encodeWithSelector(Game.PlayerAlreadyIncludedError.selector, 0)
        ));
        game.__buildPlayerBlock(players[1]);
    }

    function test_buildPlayerBlock_failsIfBuilderDoesNotIncludeOtherPlayers() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        TestPlayer builder = TestPlayer(address(players[1]));
        builder.setBid(1337);
        builder.ignorePlayer(players[2]);
        vm.expectRevert(abi.encodeWithSelector(Game.PlayerMissingFromBlockError.selector, 1));
        game.__buildPlayerBlock(builder);
    }

    function test_buildPlayerBlock_builderCanExcludeThemself() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        TestPlayer builder = TestPlayer(address(players[1]));
        game.mintAssetTo(builder, GOLD_IDX, 1337);
        builder.setBid(1337);
        builder.ignorePlayer(builder);
        game.__buildPlayerBlock(builder);
    }

    function test_buildPlayerBlock_failsIfBuilderRevertsDuringBuild() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        TestPlayer builder = TestPlayer(address(players[1]));
        builder.setBid(1337);
        builder.setRevertOnBuild(RevertMode.Revert);
        vm.expectRevert(abi.encodeWithSelector(
            Game.PlayerBuildBlockFailedError.selector,
            1,
            abi.encodeWithSelector(TestError.selector)
        ));
        game.__buildPlayerBlock(builder);
    }

    function test_buildPlayerBlock_failsIfBuilderDoesntHaveFundsAtTheEndOfBlock() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        TestPlayer builder = TestPlayer(address(players[1]));
        builder.setBid(1337);
        builder.addMintOnTurn(builder, GOLD_IDX, 1336);
        vm.expectRevert(abi.encodeWithSelector(
            Game.InsufficientBalanceError.selector,
            1,
            GOLD_IDX
        ));
        game.__buildPlayerBlock(builder);
    }

    function test_buildPlayerBlock_succeedsIfBuilderDoesHaveFundsAtTheEndOfBlock() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        TestPlayer builder = TestPlayer(address(players[1]));
        builder.setBid(1337);
        builder.addMintOnTurn(builder, GOLD_IDX, 1338);
        game.__buildPlayerBlock(builder);
        assertEq(game.balanceOf(1, GOLD_IDX), 1); // 1337 of 1338 is burned.
    }

    function test_buildPlayerBlock_doesNotConsumeAllGasIfBuilderExplodesDuringBuild() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        TestPlayer builder = TestPlayer(address(players[1]));
        builder.setBid(1337);
        builder.setRevertOnBuild(RevertMode.Invalid);
        vm.expectRevert(abi.encodeWithSelector(
            Game.PlayerBuildBlockFailedError.selector,
            1,
            ""
        ));
        uint256 gasUsed = gasleft();
        game.__buildPlayerBlock(builder);
        gasUsed -= gasleft();
        assertApproxEqAbs(gasUsed, MAX_BUILD_GAS, 32e3);
    }
   
    function test_buildPlayerBlock_revertingPlayerCountsAsIncluded() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(RevertingPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        game.__buildPlayerBlock(players[1]);
    }

    function test_auctionBlock_returnsHighestBidder() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        TestPlayer[] memory builders;
        assembly ("memory-safe") { builders := players }
        game.mintAssetTo(builders[0], GOLD_IDX, 100);
        builders[0].setBid(100);
        game.mintAssetTo(builders[1], GOLD_IDX, 300);
        builders[1].setBid(300);
        game.mintAssetTo(builders[2], GOLD_IDX, 200);
        builders[2].setBid(200);
        (uint8 builderIdx, uint256 bid) = game.__auctionBlock();
        assertEq(builderIdx, 1);
        assertEq(bid, 300);
    }

    function test_auctionBlock_returnsSecondHighestBidderIfHighestReverts() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        TestPlayer[] memory builders;
        assembly ("memory-safe") { builders := players }
        game.mintAssetTo(builders[0], GOLD_IDX, 100);
        builders[0].setBid(100);
        game.mintAssetTo(builders[1], GOLD_IDX, 300);
        builders[1].setBid(300);
        builders[1].setRevertOnBuild(RevertMode.Revert);
        game.mintAssetTo(builders[2], GOLD_IDX, 200);
        builders[2].setBid(200);
        (uint8 builderIdx, uint256 bid) = game.__auctionBlock();
        assertEq(builderIdx, 2);
        assertEq(bid, 200);
    }

    function test_auctionBlock_returnsZeroIfNoOneBids() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        TestPlayer[] memory builders;
        assembly ("memory-safe") { builders := players }
        (uint8 builderIdx, uint256 bid) = game.__auctionBlock();
        assertEq(builderIdx, 0);
        assertEq(bid, 0);
    }

    function test_auctionBlock_returnsZeroIfEveryoneReverts() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        TestPlayer[] memory builders;
        assembly ("memory-safe") { builders := players }
        builders[0].setRevertOnBuild(RevertMode.Revert);
        builders[1].setRevertOnBuild(RevertMode.Revert);
        builders[2].setRevertOnBuild(RevertMode.Revert);
        (uint8 builderIdx, uint256 bid) = game.__auctionBlock();
        assertEq(builderIdx, 0);
        assertEq(bid, 0);
    }

    function test_transfer_cannotBeCalledOutsideOfBlock() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(DonatingPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        game.mintAssetTo(players[0], GOLD_IDX, 1337);
        vm.expectRevert(Game.DuringBlockError.selector);
        vm.prank(address(players[0]));
        game.transfer(1, GOLD_IDX, 1);
    }

    function test_transfer_canBeCalledDuringDefaultBlock() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(DonatingPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        game.mintAssetTo(players[0], GOLD_IDX + 1, 1337);
        vm.expectEmit(true, true, true, true);
        emit Game.Transfer(0, 1, GOLD_IDX + 1, 1337);
        vm.expectEmit(true, true, true, true);
        emit Game.DefaultBlockBuilt(0);
        game.__buildBlock(NULL_PLAYER, 0);
    }

    function test_transfer_canBeCalledDuringPlayerBlock() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(DonatingPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        TestPlayer(address(players[1])).setBid(1);
        game.mintAssetTo(players[0], GOLD_IDX + 1, 1337);
        game.mintAssetTo(players[1], GOLD_IDX, 1);
        vm.expectEmit(true, true, true, true);
        emit Game.Transfer(0, 1, GOLD_IDX + 1, 1337);
        vm.expectEmit(true, true, true, true);
        emit Game.PlayerBlockBuilt(0, 1);
        game.__buildBlock(players[1], 1);
    }

    function test_transfer_cannotProvideInvalidAsset() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 assetCount = game.assetCount();
        game.setCurrentBuilder(DEFAULT_BUILDER);
        vm.expectRevert(AssetMarket.InvalidAssetError.selector);
        vm.prank(address(players[0]));
        game.transfer(1, assetCount, 1);
    }

    function test_transfer_cannotSendToInvalidPlayer() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setCurrentBuilder(DEFAULT_BUILDER);
        vm.expectRevert(Game.InvalidPlayerError.selector);
        vm.prank(address(players[0]));
        game.transfer(2, GOLD_IDX, 1);
    }

    function test_transfer_cannotBeCalledByNonPlayer() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setCurrentBuilder(DEFAULT_BUILDER);
        vm.expectRevert(Game.InvalidPlayerError.selector);
        vm.prank(makeAddr('nobody'));
        game.transfer(2, GOLD_IDX, 1);
    }

    function test_transfer_adjustsBalances() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setCurrentBuilder(DEFAULT_BUILDER);
        uint8 assetCount = game.assetCount();
        uint8 asset = uint8((assetCount + T.randomUint256()) % assetCount);
        game.mintAssetTo(players[0], asset, 100);
        game.mintAssetTo(players[1], asset, 100);
        vm.prank(address(players[0]));
        game.transfer(1, asset, 33);
        assertEq(game.balanceOf(0, asset), 67);
        assertEq(game.balanceOf(1, asset), 133);
    }

    function test_transfer_cannotTransferMoreThanBalance() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setCurrentBuilder(DEFAULT_BUILDER);
        uint8 assetCount = game.assetCount();
        uint8 asset = uint8((assetCount + T.randomUint256()) % assetCount);
        game.mintAssetTo(players[0], asset, 100);
        game.mintAssetTo(players[1], asset, 100);
        vm.expectRevert(abi.encodeWithSelector(Game.InsufficientBalanceError.selector, 0, asset));
        vm.prank(address(players[0]));
        game.transfer(1, asset, 101);
    }

    function test_grantTurn_cannotBeCalledByNonBuilderDuringDefaultBlock() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(GrantTurnOnTurnPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        vm.expectEmit(true, true, true, true);
        emit Game.PlayerTurnFailedWarning(1, abi.encodeWithSelector(Game.AccessError.selector));
        vm.expectEmit(true, true, true, true);
        emit Game.DefaultBlockBuilt(0);
        game.__buildBlock(NULL_PLAYER, 0);
    }
    
    function test_grantTurn_succeedsWithWarningIfPlayerFails() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        TestPlayer(address(players[0])).setRevertOnTurn(RevertMode.Revert);
        game.setCurrentBuilder(players[1]);
        vm.expectEmit(true, true, true, true);
        emit Game.PlayerTurnFailedWarning(0, abi.encodeWithSelector(TestError.selector));
        vm.prank(address(players[1]));
        game.grantTurn(0);
    }

    function test_sameStateForPlayersDuringBlockAuctionAndBuilding() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(StateTrackingPlayer).creationCode,
            type(StateTrackingPlayer).creationCode
        ]));
        game.mintAssetTo(players[1], GOLD_IDX, 1);
        vm.recordLogs();
        game.__auctionBlock();
        game.__buildBlock(players[1], 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // There should be 2 matching emits from turn() from player 0 and from buildBlock() from player 1.
        bytes32[2] memory player0TurnStateHashes;
        bytes32[2] memory player1BuildBlockStateHashes;
        uint256 player0TurnStateHashesLen;
        uint256 player1BuildBlockStateHashesLen;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.topics[0] == BUILD_BLOCK_EVENT_SIGNATURE) {
                (uint8 playerIdx, bytes32 h) = abi.decode(log.data, (uint8, bytes32));
                if (playerIdx == 1) {
                    player1BuildBlockStateHashes[player1BuildBlockStateHashesLen++] = h;
                }
            } else if (log.topics[0] == TURN_STATE_EVENT_SIGNATURE) {
                (uint8 playerIdx, uint8 builderIdx, bytes32 h) = abi.decode(log.data, (uint8, uint8, bytes32));
                if (playerIdx == 0 && builderIdx == 1) {
                    player0TurnStateHashes[player0TurnStateHashesLen++] = h;
                }
            }
        }
        assertEq(player0TurnStateHashesLen, player0TurnStateHashes.length);
        assertEq(player1BuildBlockStateHashesLen, player1BuildBlockStateHashes.length);
        assertEq(player0TurnStateHashes[0], player0TurnStateHashes[1]);
        assertEq(player1BuildBlockStateHashes[0], player1BuildBlockStateHashes[1]);
    }

    function test_quoteBuy_revertsWithInvalidAsset() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 assetCount = game.assetCount();
        uint8 fromAsset = uint8((assetCount + T.randomUint256()) % assetCount);
        uint8 toAsset = uint8((fromAsset + 1) % assetCount);
        vm.expectRevert(AssetMarket.InvalidAssetError.selector);
        game.quoteBuy(fromAsset, assetCount, 1);
        vm.expectRevert(AssetMarket.InvalidAssetError.selector);
        game.quoteBuy(assetCount, toAsset, 1);
    }

    function test_quoteSell_revertsWithInvalidAsset() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 assetCount = game.assetCount();
        uint8 fromAsset = uint8((assetCount + T.randomUint256()) % assetCount);
        uint8 toAsset = uint8((fromAsset + 1) % assetCount);
        vm.expectRevert(AssetMarket.InvalidAssetError.selector);
        game.quoteSell(fromAsset, assetCount, 1);
        vm.expectRevert(AssetMarket.InvalidAssetError.selector);
        game.quoteSell(assetCount, toAsset, 1);
    }

    function test_quoteBuy_cannotBuyEntireReserve() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 assetCount = game.assetCount();
        uint8 fromAsset = uint8((assetCount + T.randomUint256()) % assetCount);
        uint8 toAsset = uint8((fromAsset + 1) % assetCount);
        uint256[] memory reserves = game.marketState();
        uint256 buyAmount = reserves[toAsset];
        vm.expectRevert(AssetMarket.InsufficientLiquidityError.selector);
        game.quoteBuy(fromAsset, toAsset, buyAmount);
    }

    function test_quoteBuy_canQuote() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 assetCount = game.assetCount();
        uint8 fromAsset = uint8((assetCount + T.randomUint256()) % assetCount);
        uint8 toAsset = uint8((fromAsset + 1) % assetCount);
        uint256[] memory reserves = game.marketState();
        uint256 buyAmount = reserves[toAsset] / 2;
        uint256 sellAmount = game.quoteBuy(fromAsset, toAsset, buyAmount);
        assertGe(sellAmount, reserves[fromAsset] * buyAmount / reserves[toAsset]);
    }

    function test_quoteSell_canQuote() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 assetCount = game.assetCount();
        uint8 fromAsset = uint8((assetCount + T.randomUint256()) % assetCount);
        uint8 toAsset = uint8((fromAsset + 1) % assetCount);
        uint256[] memory reserves = game.marketState();
        uint256 sellAmount = reserves[fromAsset] / 2;
        uint256 buyAmount = game.quoteSell(fromAsset, toAsset, sellAmount);
        assertLe(buyAmount, reserves[toAsset] * sellAmount / reserves[fromAsset]);
    }

    function test_buy_cannotBeCalledOutsideOfBlock() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 assetCount = game.assetCount();
        uint8 fromAsset = uint8((assetCount + T.randomUint256()) % assetCount);
        uint8 toAsset = uint8((fromAsset + 1) % assetCount);
        vm.expectRevert(Game.DuringBlockError.selector);
        game.buy(fromAsset, toAsset, 1);
    }

    function test_sell_cannotBeCalledOutsideOfBlock() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 assetCount = game.assetCount();
        uint8 fromAsset = uint8((assetCount + T.randomUint256()) % assetCount);
        uint8 toAsset = uint8((fromAsset + 1) % assetCount);
        vm.expectRevert(Game.DuringBlockError.selector);
        game.sell(fromAsset, toAsset, 1);
    }

    function test_buy_mustBeCalledByPlayer() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setCurrentBuilder(players[1]);
        uint8 assetCount = game.assetCount();
        uint8 fromAsset = uint8((assetCount + T.randomUint256()) % assetCount);
        uint8 toAsset = uint8((fromAsset + 1) % assetCount);
        vm.expectRevert(Game.InvalidPlayerError.selector);
        game.buy(fromAsset, toAsset, 1);
    }

    function test_sell_mustBeCalledByPlayer() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setCurrentBuilder(players[1]);
        uint8 assetCount = game.assetCount();
        uint8 fromAsset = uint8((assetCount + T.randomUint256()) % assetCount);
        uint8 toAsset = uint8((fromAsset + 1) % assetCount);
        vm.expectRevert(Game.InvalidPlayerError.selector);
        game.sell(fromAsset, toAsset, 1);
    }

    function test_buy_revertsWithInvalidAsset() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setCurrentBuilder(players[1]);
        uint8 assetCount = game.assetCount();
        uint8 fromAsset = uint8((assetCount + T.randomUint256()) % assetCount);
        uint8 toAsset = uint8((fromAsset + 1) % assetCount);
        vm.expectRevert(AssetMarket.InvalidAssetError.selector);
        vm.prank(address(players[0]));
        game.buy(assetCount, toAsset, 1);
        vm.expectRevert(AssetMarket.InvalidAssetError.selector);
        vm.prank(address(players[0]));
        game.buy(fromAsset, assetCount, 1);
    }

    function test_sell_revertsWithInvalidAsset() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setCurrentBuilder(players[1]);
        uint8 assetCount = game.assetCount();
        uint8 fromAsset = uint8((assetCount + T.randomUint256()) % assetCount);
        uint8 toAsset = uint8((fromAsset + 1) % assetCount);
        vm.expectRevert(AssetMarket.InvalidAssetError.selector);
        vm.prank(address(players[0]));
        game.sell(assetCount, toAsset, 1);
        vm.expectRevert(AssetMarket.InvalidAssetError.selector);
        vm.prank(address(players[0]));
        game.sell(fromAsset, assetCount, 1);
    }

    function test_buy_adjustsBalances() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setCurrentBuilder(players[1]);
        uint8 assetCount = game.assetCount();
        uint8 fromAsset = uint8((assetCount + T.randomUint256()) % assetCount);
        uint8 toAsset = uint8((fromAsset + 1) % assetCount);
        game.mintAssetTo(players[0], fromAsset, 100);
        game.mintAssetTo(players[0], toAsset, 100);
        game.mintAssetTo(players[1], fromAsset, 100);
        game.mintAssetTo(players[1], toAsset, 100);
        uint256 buyAmount = 4;
        vm.prank(address(players[0]));
        uint256 sellAmount = game.buy(fromAsset, toAsset, buyAmount);
        assertEq(game.balanceOf(0, fromAsset), 100 - sellAmount);
        assertEq(game.balanceOf(0, toAsset), 100 + buyAmount);
        assertEq(game.balanceOf(1, fromAsset), 100);
        assertEq(game.balanceOf(1, toAsset), 100);
    }

    function test_sell_adjustBalances() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setCurrentBuilder(players[1]);
        uint8 assetCount = game.assetCount();
        uint8 fromAsset = uint8((assetCount + T.randomUint256()) % assetCount);
        uint8 toAsset = uint8((fromAsset + 1) % assetCount);
        game.mintAssetTo(players[0], fromAsset, 100);
        game.mintAssetTo(players[0], toAsset, 100);
        game.mintAssetTo(players[1], fromAsset, 100);
        game.mintAssetTo(players[1], toAsset, 100);
        uint256 sellAmount = 4;
        vm.prank(address(players[0]));
        uint256 buyAmount = game.sell(fromAsset, toAsset, sellAmount);
        assertEq(game.balanceOf(0, fromAsset), 100 - sellAmount);
        assertEq(game.balanceOf(0, toAsset), 100 + buyAmount);
        assertEq(game.balanceOf(1, fromAsset), 100);
        assertEq(game.balanceOf(1, toAsset), 100);
    }

    function test_buy_cannotSellMoreThanCallerBalance() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setCurrentBuilder(players[1]);
        uint8 assetCount = game.assetCount();
        uint8 fromAsset = uint8((assetCount + T.randomUint256()) % assetCount);
        uint8 toAsset = uint8((fromAsset + 1) % assetCount);
        game.mintAssetTo(players[0], fromAsset, 100);
        game.mintAssetTo(players[0], toAsset, 100);
        uint256 buyAmount = game.quoteSell(fromAsset, toAsset, 101);
        vm.expectRevert(abi.encodeWithSelector(Game.InsufficientBalanceError.selector, 0, fromAsset));
        vm.prank(address(players[0]));
        game.buy(fromAsset, toAsset, buyAmount);
    }

    function test_sell_cannotSellMoreThanCallerBalance() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setCurrentBuilder(players[1]);
        uint8 assetCount = game.assetCount();
        uint8 fromAsset = uint8((assetCount + T.randomUint256()) % assetCount);
        uint8 toAsset = uint8((fromAsset + 1) % assetCount);
        game.mintAssetTo(players[0], fromAsset, 100);
        game.mintAssetTo(players[0], toAsset, 100);
        vm.expectRevert(abi.encodeWithSelector(Game.InsufficientBalanceError.selector, 0, fromAsset));
        vm.prank(address(players[0]));
        game.sell(fromAsset, toAsset, 101);
    }

    function _createGame(bytes[] memory playerCreationCodes)
        private returns (TestGame game, IPlayer[] memory players)
    {
        uint256[] memory salts;
        (salts, players) = _minePlayers(Game(_getNextDeployAddress()), playerCreationCodes);
        game = new TestGame(sc2, playerCreationCodes, salts);
    }

    function _minePlayers(Game game, bytes[] memory playerCreationCodes)
        private view returns (uint256[] memory salts, IPlayer[] memory players)
    {
        salts = new uint256[](playerCreationCodes.length);
        players = new IPlayer[](playerCreationCodes.length);
        for (uint256 i; i < playerCreationCodes.length; ++i) {
            (salts[i], players[i]) = _findPlayerSaltAndAddress(
                game,
                playerCreationCodes[i],
                uint8(i),
                uint8(playerCreationCodes.length)
            );
        }
    }

    function _findPlayerSaltAndAddress(
        Game game,
        bytes memory creationCode,
        uint8 playerIdx,
        uint8 playerCount
    )
        internal view returns (uint256 salt, IPlayer player)
    {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(creationCode, abi.encode(playerIdx, playerCount)));
        unchecked {
            for (salt = T.randomUint256(); true; ++salt) {
                uint256 create2Salt = uint256(keccak256(abi.encode(salt, game)));
                address addr = T.getCreate2Address(initCodeHash, address(sc2), create2Salt);
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

contract TestGame is Game {
    IPlayer public mockWinner;
    IPlayer public mockBuilder;
    uint256 public mockBuilderBid;

    constructor(SafeCreate2 sc2, bytes[] memory playerCreationCodes, uint256[] memory deploySalts)
        Game(msg.sender, sc2, playerCreationCodes, deploySalts)
    {}

    function mintAssetTo(IPlayer player, uint8 assetIdx, uint256 assetAmount) external {
        _assertValidPlayer(player);
        _mintAssetTo(getIndexFromPlayer(player), assetIdx, assetAmount);
    }

    function burnAssetFrom(IPlayer player, uint8 assetIdx, uint256 assetAmount) external {
        _assertValidPlayer(player);
        _burnAssetFrom(getIndexFromPlayer(player), assetIdx, assetAmount);
    }

    function setRound(uint16 r) external {
        _round = r;
    }

    function setMockWinner(IPlayer winner) external {
        _assertValidPlayer(winner);
        mockWinner = winner;
    }

    function setMockBlockAuctionWinner(IPlayer builder, uint256 bid) external {
        _assertValidPlayer(builder);
        mockBuilder = builder;
        mockBuilderBid = bid;
    }

    function setCurrentBuilder(IPlayer builder) external {
        _assertValidPlayer(builder);
        _builder = builder;
    }

    function __distributeIncome() external virtual {
        _distributeIncome(_getAllPlayers());
    }

    function __buildPlayerBlock(IPlayer builder) external returns (uint256 bid) {
        _assertValidPlayer(builder);
        return _buildPlayerBlock(_getAllPlayers(), getIndexFromPlayer(builder));
    }

    function __buildBlock(IPlayer builder, uint256 bid) external {
        _assertValidPlayer(builder);
        return _buildBlock(round(), _getAllPlayers(), getIndexFromPlayer(builder), bid);
    }

    function __auctionBlock() external returns (uint8 builderIdx, uint256 builderBid) {
        return _auctionBlock(_getAllPlayers());
    }

    function _buildDefaultBlock(IPlayer[] memory players, uint16 round_) internal override {
        Game._buildDefaultBlock(players, round_);
    }

    function _safeCallTurn(IPlayer player, uint8 builderIdx)
        internal override returns (bool success)
    {
        return Game._safeCallTurn(player, builderIdx);
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
        assert(
            player == NULL_PLAYER
            || player == DEFAULT_BUILDER
            || _playerByIdx[getIndexFromPlayer(player)] == player
        );
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

    function turn(uint8 builderIdx) public virtual {
        emit Turning(Game(msg.sender).round(), PLAYER_IDX, builderIdx);
    }

    function buildBlock() public virtual returns (uint256) {
        emit Building(Game(msg.sender).round(), PLAYER_IDX);
        return 0;
    }
}

contract DonatingPlayer is NoopPlayer {
    constructor(uint8 playerIdx, uint8 playerCount) NoopPlayer(playerIdx, playerCount) {}

    function turn(uint8 builderIdx) public override {
        super.turn(builderIdx);
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
}

contract RevertingPlayer is NoopPlayer {
    constructor(uint8 playerIdx, uint8 playerCount) NoopPlayer(playerIdx, playerCount) {}
    function turn(uint8) public override pure { T.throwInvalid(); }
    function buildBlock() public override pure returns (uint256) { T.throwInvalid(); }
}

contract DoubleIncludePlayer is NoopPlayer {
    constructor(uint8 playerIdx, uint8 playerCount) NoopPlayer(playerIdx, playerCount) {}
    
    function buildBlock() public override returns (uint256) {
        super.buildBlock();
        TestGame game = TestGame(msg.sender);
        game.grantTurn(0);
        game.grantTurn(0);
        return 1;
    }
}

contract GrantTurnOnTurnPlayer is NoopPlayer {
    constructor(uint8 playerIdx, uint8 playerCount) NoopPlayer(playerIdx, playerCount) {}
    
    function turn(uint8 builderIdx) public override {
        super.turn(builderIdx);
        Game(msg.sender).grantTurn((PLAYER_IDX + 1) % PLAYER_COUNT);
    }
}

contract StateTrackingPlayer is NoopPlayer {
    constructor(uint8 playerIdx, uint8 playerCount) NoopPlayer(playerIdx, playerCount) {}

    function turn(uint8 builderIdx) public override {
        emit TurnState(PLAYER_IDX, builderIdx, _getStateHash());
    }

    function buildBlock() public override returns (uint256) {
        emit BuildBlockState(PLAYER_IDX, _getStateHash());
        TestGame game = TestGame(msg.sender);
        for (uint8 i; i < PLAYER_COUNT; ++i) game.grantTurn(i);
        return 1;
    }

    function _getStateHash() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                msg.data,
                msg.sender,
                msg.value,
                gasleft(),
                address(this).balance,
                isAddressCold(address(bytes20(keccak256(abi.encode(address(this), msg.data)))))
            )
        );
    }
}

contract TestPlayer is NoopPlayer {
    struct AssetOwed {
        IPlayer player;
        uint8 assetIdx;
        uint256 amount;
    }

    struct PreparedCall {
        address target;
        bytes callData;
    }

    IPlayer public ignoredPlayer;
    uint256 public bid;
    RevertMode public revertOnBuild;
    RevertMode public revertOnTurn;
    AssetOwed[] public mints;
    AssetOwed[] public burns;
    PreparedCall public preparedCall;

    constructor(uint8 playerIdx, uint8 playerCount) NoopPlayer(playerIdx, playerCount) {}

    function turn(uint8 builderIdx) public override {
        super.turn(builderIdx);
        TestGame game = TestGame(msg.sender);
        if (revertOnTurn == RevertMode.Revert) revert TestError();
        else if (revertOnTurn == RevertMode.Invalid) T.throwInvalid();
        for (uint256 i; i < mints.length; ++i) {
            AssetOwed memory ao = mints[i];
            game.mintAssetTo(ao.player, ao.assetIdx, ao.amount);
        }
        for (uint256 i; i < burns.length; ++i) {
            AssetOwed memory ao = burns[i];
            game.burnAssetFrom(ao.player, ao.assetIdx, ao.amount);
        }
        if (preparedCall.target != address(0)) {
            (bool s, bytes memory r) = preparedCall.target.call(preparedCall.callData);
            if (!s) r.rawRevert();
        }
    }

    function buildBlock() public override returns (uint256) {
        super.buildBlock();
        TestGame game = TestGame(msg.sender);
        if (revertOnBuild == RevertMode.Revert) revert TestError();
        else if (revertOnBuild == RevertMode.Invalid) T.throwInvalid();
        for (uint8 i; i < PLAYER_COUNT; ++i) {
            if (ignoredPlayer != NULL_PLAYER && getIndexFromPlayer(ignoredPlayer) == i) continue;
            game.grantTurn(i);
        }
        return bid;
    }

    function setCallOnTurn(address target, bytes calldata cd) external {
        preparedCall = PreparedCall(target, cd);
    }

    function addMintOnTurn(IPlayer player, uint8 assetIdx, uint256 amount) external {
        mints.push(AssetOwed(player, assetIdx, amount));
    }

    function addBurnOnTurn(IPlayer player, uint8 assetIdx, uint256 amount) external {
        burns.push(AssetOwed(player, assetIdx, amount));
    }
   
    function setBid(uint256 bid_) external {
        bid = bid_;
    }

    function setRevertOnBuild(RevertMode mode) external {
        revertOnBuild = mode;
    }

    function setRevertOnTurn(RevertMode mode) external {
        revertOnTurn = mode;
    }

    function ignorePlayer(IPlayer player) external {
        ignoredPlayer = player;
    }
}