// SPDX-License-Identifer: MIT
pragma solidity ^0.8;

import {
    ENCRYPTED_AES_KEY_SIZE,
    MAX_ENCRYPTED_CODE_SIZE,
    Confirmation,
    Contest,
    EncryptedCodeSubmission,
    LibContest,
    SeasonState
} from '~/contest/Contest.sol';
import { Test } from 'forge-std/Test.sol';
import { LibTestUtils as T } from '../LibTestUtils.sol';

contract ContestTest is Test {
    Contest contest;
    address host;
    address retirer;
    address registrar;
    uint256 registrarPrivateKey;

    function setUp() external {
        host = makeAddr('host');
        retirer = makeAddr('retirer');
        registrarPrivateKey = T.randomUint256();
        registrar = vm.addr(registrarPrivateKey);
        contest = new Contest(host, retirer, registrar);
        vm.deal(host, 100 ether);
    }

    function testFuzz_nonAdminCannotCallAdminFunctions(address caller) external {
        vm.assume(caller != retirer);
        vm.expectRevert(Contest.AccessError.selector);
        vm.prank(caller);
        contest.retire(makeAddr('player'));
    }

    function testFuzz_nonHostCannotCallHostFunctions(address caller) external {
        vm.assume(caller != host);
        vm.expectRevert(Contest.AccessError.selector);
        vm.prank(caller);
        contest.startSeason(0, '', address(0));
        vm.expectRevert(Contest.AccessError.selector);
        vm.prank(caller);
        contest.closeSeason(0);
        vm.expectRevert(Contest.AccessError.selector);
        vm.prank(caller);
        contest.revealSeasonKey(0, '');
    }

    function test_canSetOperator() external {
        address operator = makeAddr('operator');
        address player = makeAddr('player');
        assertFalse(contest.operators(player, operator));
        vm.prank(player);
        _expectEmitAll();
        emit Contest.OperatorSet(player, operator, true);
        contest.setOperator(operator, true);
        assertTrue(contest.operators(player, operator));
        vm.prank(player);
        _expectEmitAll();
        emit Contest.OperatorSet(player, operator, false);
        contest.setOperator(operator, false);
        assertFalse(contest.operators(player, operator));
    }

    function test_canRegister() external {
        address player = makeAddr('player');
        assertFalse(contest.isRegisteredPlayer(player));
        _expectEmitAll();
        emit Contest.Registered(player);
        contest.register(player, _createRegistrationConfirmation(player));
        assertTrue(contest.isRegisteredPlayer(player));
    }

    function test_cannotRegisterTwice() external {
        address player = makeAddr('player');
        contest.register(player, _createRegistrationConfirmation(player));
        assertTrue(contest.isRegisteredPlayer(player));
        vm.expectRevert(Contest.AlreadyRegisteredError.selector);
        contest.register(player, _createRegistrationConfirmation(player));
    }
    
    function test_cannotReuseConfirmation() external {
        address player = makeAddr('player');
        Confirmation memory conf = _createRegistrationConfirmation(player);
        contest.register(player, conf);
        vm.expectRevert(Contest.InvalidConfirmationError.selector);
        contest.register(makeAddr('player2'), conf);
    }

    function test_cannotRegisterAfterBeingRetired() external {
        address player = makeAddr('player');
        contest.register(player, _createRegistrationConfirmation(player));
        vm.prank(retirer);
        contest.retire(player);
        vm.expectRevert(Contest.AlreadyRegisteredError.selector);
        contest.register(player, _createRegistrationConfirmation(player));
    }

    function test_retireMarksPlayerAsInvalid() external {
        address player = makeAddr('player');
        contest.register(player, _createRegistrationConfirmation(player));
        assertTrue(contest.isRegisteredPlayer(player));
        vm.prank(retirer);
        _expectEmitAll();
        emit Contest.Retired(player);
        contest.retire(player);
        assertFalse(contest.isRegisteredPlayer(player));
    }

    function test_cannotSubmitCodeBeforeStarting() external {
        address player = _registerPlayer();
        bytes32 codeHash = T.randomBytes32();
        EncryptedCodeSubmission memory sub = _createSubmission();
        uint32 seasonIdx = contest.currentSeasonIdx();
        vm.prank(player);
        vm.expectRevert(Contest.SeasonNotActiveError.selector);
        contest.submitCode(seasonIdx, player, codeHash, sub);
    }

    function test_cannotSubmitCodeIfNotPlayerOrOperator() external {
        (address player,) = _registerPlayerAndOperator();
        bytes32 codeHash = T.randomBytes32();
        EncryptedCodeSubmission memory sub = _createSubmission();
        uint32 seasonIdx = contest.currentSeasonIdx();
        vm.prank(makeAddr('charlie'));
        vm.expectRevert(Contest.AccessError.selector);
        contest.submitCode(seasonIdx, player, codeHash, sub);
    }

    function test_cannotSubmitMalformedSubmission() external {
        (address player,) = _registerPlayerAndOperator();
        bytes32 codeHash = T.randomBytes32();
        EncryptedCodeSubmission memory sub = _createSubmission();
        uint32 seasonIdx = contest.currentSeasonIdx();
        vm.prank(player);
        vm.expectRevert(Contest.InvalidCodeHashError.selector);
        contest.submitCode(seasonIdx, player, bytes32(0), sub);
        sub.encryptedAesKey = T.randomBytes(ENCRYPTED_AES_KEY_SIZE - 1);
        vm.prank(player);
        vm.expectRevert(Contest.PlayerSubmissionError.selector);
        contest.submitCode(seasonIdx, player, codeHash, sub);
        sub = _createSubmission();
        sub.encryptedCode = T.randomBytes(MAX_ENCRYPTED_CODE_SIZE + 1);
        vm.prank(player);
        vm.expectRevert(Contest.PlayerSubmissionError.selector);
        contest.submitCode(seasonIdx, player, codeHash, sub);
    }

    function test_canSubmitCodeAsPlayer() external {
        (address player,) = _registerPlayerAndOperator();
        _startSeason();
        bytes32 codeHash = T.randomBytes32();
        EncryptedCodeSubmission memory sub = _createSubmission();
        uint32 seasonIdx = contest.currentSeasonIdx();
        vm.prank(player);
        _expectEmitAll();
        emit Contest.CodeCommitted(seasonIdx, player, codeHash, sub);
        contest.submitCode(seasonIdx, player, codeHash, sub);
        assertEq(contest.playerCodeHash(seasonIdx, player), codeHash);
        assertEq(contest.playerCodeCount(seasonIdx), 1);
    }

    function test_canSubmitCodeAsOperator() external {
        (address player, address operator) = _registerPlayerAndOperator();
        _startSeason();
        bytes32 codeHash = T.randomBytes32();
        EncryptedCodeSubmission memory sub = _createSubmission();
        uint32 seasonIdx = contest.currentSeasonIdx();
        vm.prank(operator);
        _expectEmitAll();
        emit Contest.CodeCommitted(seasonIdx, player, codeHash, sub);
        contest.submitCode(seasonIdx, player, codeHash, sub);
        assertEq(contest.playerCodeHash(seasonIdx, player), codeHash);
    }

    function test_canSubmitCodeAgain() external {
        (address player, address operator) = _registerPlayerAndOperator();
        _startSeason();
        uint32 seasonIdx = contest.currentSeasonIdx();
        bytes32 codeHash = T.randomBytes32();
        EncryptedCodeSubmission memory sub = _createSubmission();
        vm.prank(operator);
        _expectEmitAll();
        emit Contest.CodeCommitted(seasonIdx, player, codeHash, sub);
        contest.submitCode(seasonIdx, player, codeHash, sub);
        assertEq(contest.playerCodeHash(seasonIdx, player), codeHash);
        codeHash = T.randomBytes32();
        sub = _createSubmission();
        vm.prank(operator);
        _expectEmitAll();
        emit Contest.CodeCommitted(seasonIdx, player, codeHash, sub);
        contest.submitCode(seasonIdx, player, codeHash, sub);
        assertEq(contest.playerCodeHash(seasonIdx, player), codeHash);
        assertEq(contest.playerCodeCount(seasonIdx), 1);
    }

    function test_retireClearsSubmissionStates() external {
        address player = _registerPlayer();
        _startSeason();
        uint32 seasonIdx = contest.currentSeasonIdx();
        bytes32 codeHash = T.randomBytes32();
        EncryptedCodeSubmission memory sub = _createSubmission();
        vm.prank(player);
        contest.submitCode(seasonIdx, player, codeHash, sub);
        assertEq(contest.playerCodeHash(seasonIdx, player), codeHash);
        assertEq(contest.playerCodeCount(seasonIdx), 1);
        vm.prank(retirer);
        contest.retire(player);
        assertEq(contest.playerCodeHash(seasonIdx, player), bytes32(0));
        assertEq(contest.playerCodeCount(seasonIdx), 0);
    }

    function test_canStartFirstSeason() external {
        uint32 seasonIdx = contest.currentSeasonIdx();
        bytes memory pubKey = T.randomBytes(1800);
        assertEq(uint8(contest.seasonState(0)), uint8(SeasonState.Inactive));
        vm.prank(host);
        _expectEmitAll();
        emit Contest.SeasonStarted(seasonIdx, pubKey);
        contest.startSeason{value: 1}(seasonIdx, pubKey, address(0));
        assertEq(contest.currentSeasonIdx(), 0);
        assertEq(uint8(contest.seasonState(0)), uint8(SeasonState.Started));
        assertEq(uint8(contest.seasonState(1)), uint8(SeasonState.Inactive));
        (address winner, uint256 prize) = contest.winner(seasonIdx);
        // Winner should not count when starting season 0.
        assertEq(winner, address(0));
        assertEq(prize, 0);
    }

    function test_canStartSeasonWithoutPriorWinner() external {
        _startSeason(address(0), 123);
        _skipSeason(address(0), 234);
        assertEq(contest.currentSeasonPrize(), 123 + 234);
        assertEq(contest.unclaimedPrize(), 0);
        (address winner, uint256 prize) = contest.winner(0);
        assertEq(winner, address(0));
        assertEq(prize, 0);
    }

    function test_cannotStartDistantSeasonImmediately() external {
        vm.prank(host);
        vm.expectRevert(Contest.PreviousSeasonNotRevealedError.selector);
        contest.startSeason(1, T.randomBytes(1800), address(0));
        vm.prank(host);
        vm.expectRevert(Contest.NotSeasonError.selector);
        contest.startSeason(2, T.randomBytes(1800), address(0));
    }

    function test_cannotStartDistantSeason() external {
        _startSeason();
        _skipSeason();
        assertEq(contest.currentSeasonIdx(), 1);
        vm.prank(host);
        vm.expectRevert(Contest.NotSeasonError.selector);
        contest.startSeason(3, T.randomBytes(1800), address(0));
    }

    function test_cannotStartPriorSeasonZero() external {
        _startSeason();
        _skipSeason();
        assertEq(contest.currentSeasonIdx(), 1);
        vm.prank(host);
        vm.expectRevert(Contest.NotSeasonError.selector);
        contest.startSeason(0, T.randomBytes(1800), address(0));
    }

    function test_cannotStartPriorSeasonNotzero() external {
        _startSeason();
        _skipSeason();
        _skipSeason();
        assertEq(contest.currentSeasonIdx(), 2);
        vm.prank(host);
        vm.expectRevert(Contest.NotSeasonError.selector);
        contest.startSeason(1, T.randomBytes(1800), address(0));
    }

    function test_cannotStartNotRevealedSeason() external {
        _startSeason();
        _skipSeason();
        assertEq(contest.currentSeasonIdx(), 1);
        vm.prank(host);
        contest.closeSeason(1);
        vm.prank(host);
        vm.expectRevert(Contest.PreviousSeasonNotRevealedError.selector);
        contest.startSeason(2, T.randomBytes(1800), address(0));
    }

    function test_winnerCanClaimPrize() external {
        uint256 prize = (T.randomUint256() % 1337) | 1;
        _startSeason(address(0), prize);
        address player = _registerPlayer();
        _skipSeason(player);
        {
            (address winner, uint256 prize_) = contest.winner(0);
            assertEq(winner, player);
            assertEq(prize_, prize);
        }
        vm.prank(player);
        contest.claim(0, payable(player));
        assertEq(player.balance, prize);
    }

    function test_operatorCannotClaimPrize() external {
        uint256 prize = (T.randomUint256() % 1337) | 1;
        _startSeason(address(0), prize);
        (address player, address operator) = _registerPlayerAndOperator();
        payable(contest).transfer(prize);
        _skipSeason(player);
        vm.prank(operator);
        vm.expectRevert(Contest.NotWinnerError.selector);
        contest.claim(0, payable(player));
    }

    function test_nonWinnerCannotClaimPrize() external {
        uint256 prize = (T.randomUint256() % 1337) | 1;
        _startSeason(address(0), prize);
        address winner = _registerPlayer();
        address notWinner = _registerPlayer();
        _skipSeason(winner);
        vm.prank(notWinner);
        vm.expectRevert(Contest.NotWinnerError.selector);
        contest.claim(0, payable(winner));
    }

    function test_cannotClaimNextSeasonPrize() external {
        uint256 prize0 = (T.randomUint256() % 1337) | 1;
        uint256 prize1 = (T.randomUint256() % 1337) | 1;
        address winner = _registerPlayer();
        _startSeason(address(0), prize0);
        _skipSeason(winner, prize1);
        assertEq(address(contest).balance, prize0 + prize1);
        assertEq(contest.unclaimedPrize(), prize0);
        vm.prank(winner);
        contest.claim(0, payable(winner));
        assertEq(address(contest).balance, prize1);
        assertEq(contest.unclaimedPrize(), 0);
    }

    function testFuzz_winnerCanClaimPrizeEvenIfPastWinnerDidnt(bool[8] memory willClaim) external {
        _startSeason();
        for (uint32 szn; szn < willClaim.length; ++szn) {
            address player = _registerPlayer();
            uint256 prize = (T.randomUint256() % 1337) | 1;
            payable(contest).transfer(prize);
            _skipSeason(player);
            if (willClaim[szn]) {
                vm.prank(player);
                contest.claim(szn, payable(player));
                assertEq(player.balance, prize);
            }
        }
        assertEq(address(contest).balance, contest.unclaimedPrize());
        // Claim later.
        for (uint32 szn; szn < willClaim.length; ++szn) {
            (address winner, uint256 prize) = contest.winner(szn);
            if (!willClaim[szn]) {
                vm.prank(winner);
                contest.claim(szn, payable(winner));
                assertEq(winner.balance, prize);
            } else {
                assertEq(prize, 0);
                // Try to double claim.
                vm.prank(winner);
                vm.expectRevert(Contest.AlreadyClaimedError.selector);
                contest.claim(szn, payable(winner));
            }
        }
        assertEq(address(contest).balance, 0);
        assertEq(contest.unclaimedPrize(), 0);
    }

    function test_nextSeasonPrizeIsBalanceMinusUnclaimedPrizes() external {
        _startSeason(address(0), 123);
        assertEq(contest.unclaimedPrize(), 0);
        assertEq(address(contest).balance, 123);
        address player = _registerPlayer();
        _skipSeason(player, 234);
        assertEq(contest.unclaimedPrize(), 123);
        assertEq(address(contest).balance, 123 + 234);
        _skipSeason(player, 567);
        assertEq(contest.unclaimedPrize(), 123 + 234);
        assertEq(address(contest).balance, 123 + 234 + 567);
        vm.prank(player);
        contest.claim(1, payable(player));
        assertEq(contest.unclaimedPrize(), 123);
        assertEq(contest.currentSeasonPrize(), 567);
    }

    function test_canCloseSeason() external {
        _startSeason();
        vm.prank(host);
        _expectEmitAll();
        emit Contest.SeasonClosed(0);
        contest.closeSeason(0);
    }

    function test_cannotCloseSeasonTwice() external {
        _startSeason();
        vm.prank(host);
        contest.closeSeason(0);
        vm.prank(host);
        vm.expectRevert(Contest.SeasonNotActiveError.selector);
        contest.closeSeason(0);
    }

    function test_cannotCloseRevealedSeason() external {
        _startSeason();
        vm.prank(host);
        contest.closeSeason(0);
        vm.prank(host);
        contest.revealSeasonKey(0, T.randomBytes(1024));
        vm.prank(host);
        vm.expectRevert(Contest.SeasonNotActiveError.selector);
        contest.closeSeason(0);
    }

    function test_cannotCloseInactiveSeason() external {
        _startSeason();
        vm.prank(host);
        contest.closeSeason(0);
        vm.prank(host);
        contest.revealSeasonKey(0, T.randomBytes(1024));
        vm.prank(host);
        vm.expectRevert(Contest.SeasonNotActiveError.selector);
        contest.closeSeason(1);
    }

    function test_canRevealSeason() external {
        _startSeason();
        vm.prank(host);
        contest.closeSeason(0);
        vm.prank(host);
        bytes memory sk = T.randomBytes(1024);
        _expectEmitAll();
        emit Contest.SeasonRevealed(0, sk);
        contest.revealSeasonKey(0, sk);
    }

    function test_cannotRevealSeasonTwice() external {
        _startSeason();
        vm.prank(host);
        contest.closeSeason(0);
        vm.prank(host);
        contest.revealSeasonKey(0, T.randomBytes(1024));
        vm.prank(host);
        vm.expectRevert(Contest.SeasonNotClosedError.selector);
        contest.revealSeasonKey(0, T.randomBytes(1024));
    }

    function test_cannotRevealInactiveSeason() external {
        _startSeason();
        vm.prank(host);
        contest.closeSeason(0);
        vm.prank(host);
        contest.revealSeasonKey(0, T.randomBytes(1024));
        vm.prank(host);
        vm.expectRevert(Contest.SeasonNotClosedError.selector);
        contest.revealSeasonKey(1, T.randomBytes(1024));
    }

    function test_cannotRevealStartedSeason() external {
        _startSeason();
        vm.prank(host);
        vm.expectRevert(Contest.SeasonNotClosedError.selector);
        contest.revealSeasonKey(0, T.randomBytes(1024));
    }

    function test_isRegisteredPlayerDoesNotCountRetired() external {
        address player1 = _registerPlayer();
        address player2 = _registerPlayer();
        assertTrue(contest.isRegisteredPlayer(player1));
        assertTrue(contest.isRegisteredPlayer(player2));
        vm.prank(retirer);
        contest.retire(player2);
        assertFalse(contest.isRegisteredPlayer(player2));
    }

    function _startSeason() private returns (address winner) {
        _startSeason(winner = makeAddr('winner'), 0);
    }

    function _startSeason(address prevWinner, uint256 prize) private {
        uint32 seasonIdx = contest.currentSeasonIdx();
        vm.prank(host);
        contest.startSeason{value: prize}(seasonIdx, T.randomBytes(1800), prevWinner);
    }

    function _skipSeason() private {
        _skipSeason(address(0));
    }

    function _skipSeason(address winner) private {
        _skipSeason(winner, 0);
    }

    function _skipSeason(address winner, uint256 nextSeasonPrize) private {
        uint32 seasonIdx = contest.currentSeasonIdx();
        SeasonState state = contest.seasonState(seasonIdx);
        require(state != SeasonState.Inactive, 'current season not active (call _startSeason())');
        if (state == SeasonState.Started) {
            vm.prank(host);
            contest.closeSeason(seasonIdx);
            state = SeasonState.Closed;
        }
        if (state == SeasonState.Closed) {
            vm.prank(host);
            contest.revealSeasonKey(seasonIdx, T.randomBytes(1800));
            state = SeasonState.Revealed;
        }
        vm.prank(host);
        contest.startSeason{value: nextSeasonPrize}(seasonIdx + 1, T.randomBytes(1800), winner);
    }

    function _registerPlayer() private returns (address player) {
        player = T.randomAddress();
        contest.register(player, _createRegistrationConfirmation(player));
    }

    function _registerPlayerAndOperator() private returns (address player, address operator) {
        player = _registerPlayer();
        operator = T.randomAddress();
        vm.prank(player);
        contest.setOperator(operator, true);
    }

    function _createSubmission()
        private view returns (EncryptedCodeSubmission memory sub)
    {
        sub = EncryptedCodeSubmission({
            encryptedAesKey: T.randomBytes(ENCRYPTED_AES_KEY_SIZE),
            encryptedCode: T.randomBytes(MAX_ENCRYPTED_CODE_SIZE),
            iv: bytes12(T.randomBytes32())
        });
    }

    function _createRegistrationConfirmation(address player)
        private
        view returns (Confirmation memory conf)
    {
        conf.expiry = block.timestamp + 1;
        conf.nonce = T.randomUint256();
        bytes32 digest = LibContest.hashRegistration(
            address(contest),
            block.chainid,
            player,
            conf.expiry,
            conf.nonce
        );
        (conf.v, conf.r, conf.s) = vm.sign(registrarPrivateKey, digest);
    }

    function _expectEmitAll() private {
        vm.expectEmit(true, true, true, true);
    }
}