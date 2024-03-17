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
    BUILD_GAS_BASE,
    BUILD_GAS_PER_PLAYER,
    DEFAULT_BUILDER
} from "~/game/Game.sol";
import { AssetMarket } from "~/game/Markets.sol";
import { IPlayer } from "~/game/IPlayer.sol";
import { LibBytes } from "~/game/LibBytes.sol";
import { LibMatchUtils } from "~/game/LibMatchUtils.sol";
import { SafeCreate2 } from "~/game/SafeCreate2.sol";

using LibBytes for bytes;

event PlayerCreated(address self, uint8 playerIdx, uint8 playerCount);
event Turning(uint16 round, uint8 playerIdx, uint8 builderIdx);
event Building(uint16 round, uint8 playerIdx);
error TestError();

bytes32 constant CREATE_BUNDLE_STATE_EVENT_SIGNATURE = keccak256('CreateBundleState(uint8,uint8,bytes32)');
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

    function revertBack(bytes memory revertData) external {
        revertData.rawRevert();
    }

    function throwInvalid() external {
        T.throwInvalid();
    }

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

    function test_canPlayRoundWithEmptyAndRevertingPlayers() external {
        (Game game,) = _createGame(T.toDynArray([
            type(EmptyContract).creationCode,
            hex'fe'
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

    function test_distributeIncome_givesAssetsToEveryPlayer() external {
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
                    assertEq(game.balanceOf(playerIdx, assetIdx), INCOME_AMOUNT);
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

    function test_findWinner_whenAtMaxRoundsAndEveryPlayerHasZeroOfANonGoldAsset_returnsFirstPlayer() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setRound(MAX_ROUNDS);
        uint8 winnerIdx = game.findWinner();
        assertEq(winnerIdx, 0);
    }

    function test_playRound_BidWinnerBuildsBlock() external {
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
            type(DoubleSettlePlayer).creationCode
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
        assertApproxEqAbs(gasUsed, BUILD_GAS_BASE, 32e3);
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

    function test_grantTurn_cannotBeCalledByNonBuilderDuringDefaultBlock() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(CallbackPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        vm.expectEmit(true, true, true, true);
        // This will actually trigger a MinGasError because the turn gas lower than what
        // grantTurn() requires.
        // emit Game.PlayerTurnFailed(1, abi.encodeWithSelector(Game.AccessError.selector));
        emit Game.PlayerTurnFailed(1, abi.encodeWithSelector(Game.MinGasError.selector));
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
        emit Game.PlayerTurnFailed(0, abi.encodeWithSelector(TestError.selector));
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
            } else if (log.topics[0] == CREATE_BUNDLE_STATE_EVENT_SIGNATURE) {
                (uint8 playerIdx, uint8 builderIdx, bytes32 h) =
                    abi.decode(log.data, (uint8, uint8, bytes32));
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
        address[] memory addrs;
        (salts, addrs) = LibMatchUtils.minePlayerSaltsAndAddresses(
            address(game),
            address(sc2),
            bytes32(uint256(1337)),
            playerCreationCodes
        );
        assembly ("memory-safe") { players := addrs }
    }

    function _getNextDeployAddress() internal view returns (address) {
        return LibMatchUtils.getCreateAddress(
            address(this),
            uint32(vm.getNonce(address(this)))
        );
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

    function _findWinner(uint16 round_)
        internal override view returns (IPlayer winner)
    {
        if (mockWinner != NULL_PLAYER) {
            return mockWinner;
        }
        return Game._findWinner(round_);
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
    uint8 public immutable PLAYER_IDX;
    uint8 immutable PLAYER_COUNT;

    constructor(uint8 playerIdx, uint8 playerCount) {
        PLAYER_IDX = playerIdx;
        PLAYER_COUNT = playerCount;
        emit PlayerCreated(address(this), playerIdx, playerCount);
    }

    function createBundle(uint8 builderIdx)
        public virtual returns (PlayerBundle memory bundle)
    {
        emit Turning(Game(msg.sender).round(), PLAYER_IDX, builderIdx);
    }

    function buildBlock(PlayerBundle[] calldata bundles)
        public virtual returns (uint256 bid)
    {
        emit Building(Game(msg.sender).round(), PLAYER_IDX);
        return 0;
    }
}

contract CallbackPlayer is NoopPlayer {
    struct Call {
        address target;
        bytes data;
    }

    event Called(
        bytes4 playerFnSelector,
        address target,
        bytes data,
        bool succeeded,
        bytes resultData
    );

    mapping (bytes4 playerFnSelector => Call[]) _calls;
    
    constructor(uint8 playerIdx, uint8 playerCount) NoopPlayer(playerIdx, playerCount) {}
    
    function setCallback(bytes4 playerFnSelector, address target, bytes calldata data) external {
        _calls[playerFnSelector] = Call(target, data);
    }
    
    function createBundle(uint8 builderIdx)
        public override returns (PlayerBundle memory bundle)
    {
        _doCalls();
    }

    function buildBlock(PlayerBundle[] calldata bundles)
        public override returns (PlayerBundle memory bundle)
    {
        _doCalls();
    }

    function _doCalls() private {
        Call[] storage calls = _calls[msg.sig];
        uint256 n = calls.length;
        for (uint256 i; i < n; ++i) {
            Call memory call_ = calls[i];
            (bool success, bytes memory resultData) = call_.target.call(call_.data);
            emit Called(msg.sig, call_.target, call_.data, success, resultData);
        }
    }
}

contract StateTrackingPlayer is NoopPlayer {
    event CreateBundleState(uint8 playerIdx, uint8 builderIdx, bytes32 h);
    event BuildBlockState(uint8 builderIdx, bytes32 h);

    constructor(uint8 playerIdx, uint8 playerCount) NoopPlayer(playerIdx, playerCount) {}

    function createBundle(uint8 builderIdx) public override {
        emit CreateBundleState(PLAYER_IDX, builderIdx, _getStateHash());
    }

    function buildBlock(PlayerBundle[] calldata bundles)
        public override returns (uint256)
    {
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

contract TestPlayer is CallbackPlayer {
    struct AssetOwed {
        IPlayer player;
        uint8 assetIdx;
        uint256 amount;
    }

    IPlayer public ignoredPlayer;
    uint256 public bid;
    AssetOwed[] public mints;
    AssetOwed[] public burns;

    constructor(uint8 playerIdx, uint8 playerCount) NoopPlayer(playerIdx, playerCount) {}

    function createBundle(uint8 builderIdx)
        public override returns (PlayerBundle memory bundle)
    {
        bundle = super.createBundle(builderIdx);
        TestGame game = TestGame(msg.sender);
        for (uint256 i; i < mints.length; ++i) {
            AssetOwed memory ao = mints[i];
            game.mintAssetTo(ao.player, ao.assetIdx, ao.amount);
        }
        for (uint256 i; i < burns.length; ++i) {
            AssetOwed memory ao = burns[i];
            game.burnAssetFrom(ao.player, ao.assetIdx, ao.amount);
        }
    }

    function buildBlock(PlayerBundle[] calldata bundles)
        public override returns (uint256)
    {
        super.buildBlock();
        TestGame game = TestGame(msg.sender);
        for (uint8 i; i < PLAYER_COUNT; ++i) {
            if (ignoredPlayer != NULL_PLAYER && getIndexFromPlayer(ignoredPlayer) == i) continue;
            game.grantTurn(i);
        }
        return bid;
    }
   
    function setBid(uint256 bid_) external {
        bid = bid_;
    }

    function ignorePlayer(IPlayer player) external {
        ignoredPlayer = player;
    }
}

contract EmptyContract {}