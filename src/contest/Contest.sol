// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

struct Confirmation {
    uint256 expiry;
    uint256 nonce;
    bytes32 r;
    bytes32 s;
    uint8 v;
}

enum SeasonState {
    Inactive,
    Started,
    Closed,
    Revealed
}

struct SeasonInfo {
    SeasonState state;
    address winner;
    uint96 unclaimedPrize;
    uint32 playerCodeCount;
    mapping (address player => bytes32 codeHash) playerCodeHashes;
}

struct EncryptedCodeSubmission {
    bytes encryptedAesKey;
    bytes encryptedCode;
    bytes12 iv;
}

uint256 constant MAX_ENCRYPTED_CODE_SIZE = 0x10100;
uint256 constant ENCRYPTED_AES_KEY_SIZE = 128;
    
library LibContest {
    bytes32 constant private REGISTRATION_PREFIX = keccak256(unicode"ᴙɘgiꙅTᴙATioᴎ");

    function hashRegistration(
        address contest,
        uint256 chainId,
        address registrant,
        uint256 expiry,
        uint256 nonce
    )
        internal pure returns (bytes32)
    {
        return keccak256(abi.encode(
            REGISTRATION_PREFIX,
            contest,
            chainId,
            registrant,
            expiry,
            nonce
        ));
    }
}

contract Contest {
    error AccessError();
    error ConfirmationConsumedError();
    error InvalidConfirmationError();
    error NotRegisteredError();
    error NotSeasonError();
    error SeasonNotActiveError();
    error SeasonNotClosedError();
    error PreviousSeasonNotRevealedError();
    error InvalidKeyError();
    error InvalidCodeHashError();
    error NotWinnerError();
    error InvalidPlayerError();
    error AlreadyClaimedError();
    error PlayerSubmissionError();
    error AlreadyRegisteredError();

    event Registered(address indexed player);
    event Retired(address indexed player);
    event SeasonClosed(uint32 indexed season);
    event SeasonRevealed(uint32 indexed season, bytes privateKey);
    event WinnerDeclared(uint32 indexed season, address indexed winner, uint256 prize);
    event SeasonStarted(uint32 indexed season, bytes publicKey);
    event PrizeClaimed(uint32 indexed season, address indexed winner, uint256 prize);
    event CodeCommitted(
        uint32 indexed season,
        address indexed player,
        bytes32 codeHash,
        EncryptedCodeSubmission submission
    );
    event OperatorSet(address indexed player, address indexed operator, bool permitted);

    address public immutable HOST;
    address public immutable RETIRER;
    address public immutable REGISTRAR;

    uint32 public playerCount;
    uint32 public currentSeasonIdx;
    uint96 public unclaimedPrize;
    mapping (uint32 seasonIdx => SeasonInfo info) private _seasons;
    mapping (address player => uint256 block) public playerRegisteredBlock;
    mapping (bytes32 confirmationHash => uint256 block) public confirmationConsumedBlock;
    mapping (address player => mapping (address operator => bool isPermitted)) public operators;

    constructor(address host, address retirer, address notary) {
        HOST = host;
        REGISTRAR = notary;
        RETIRER = retirer;
    }

    modifier onlyFrom(address from) {
        if (msg.sender != from) revert AccessError();
        _;
    }

    modifier onlyRegisteredPlayer(address player) {
        if (!isRegisteredPlayer(player)) revert NotRegisteredError();
        _;
    }

    modifier duringSameSeason(uint32 seasonIdx) {
        if (seasonIdx != currentSeasonIdx) revert NotSeasonError();
        _;
    }

    function seasonState(uint32 seasonIdx) external view returns (SeasonState) {
        return _seasons[seasonIdx].state;
    }

    function playerCodeHash(uint32 seasonIdx, address player)
        external view returns (bytes32 codeHash)
    {
        if (playerRegisteredBlock[player] == 0) {
            return 0;
        }
        return _seasons[seasonIdx].playerCodeHashes[player];
    }

    function playerCodeCount(uint32 seasonIdx)
        external view returns (uint32 playerCount_)
    {
        return _seasons[seasonIdx].playerCodeCount;
    }

    function winner(uint32 seasonIdx)
        external view returns (address winner_, uint96 unclaimedPrize_)
    {
        SeasonInfo storage season = _seasons[seasonIdx];
        return (season.winner, season.unclaimedPrize);
    }

    function currentSeasonPrize() external view returns (uint256 prize) {
        return address(this).balance - unclaimedPrize;
    }

    receive() payable external {}

    function setOperator(address operator, bool permitted) external {
        operators[msg.sender][operator] = permitted;
        emit OperatorSet(msg.sender, operator, permitted);
    }
    
    function retire(address player)
        external
        onlyFrom(RETIRER)
        onlyRegisteredPlayer(player)
    {
        playerRegisteredBlock[player] = type(uint256).max;
        --playerCount;
        SeasonInfo storage season = _seasons[currentSeasonIdx];
        if (season.playerCodeHashes[player] != 0) {
            season.playerCodeHashes[player] = 0;
            --season.playerCodeCount;
        }
        emit Retired(player);
    }

    function register(address player, Confirmation memory confirmation) external {
        if (playerRegisteredBlock[player] != 0) revert AlreadyRegisteredError();
        _consumeConfirmation(player, confirmation);
        playerRegisteredBlock[player] = block.number;
        ++playerCount;
        emit Registered(player);
    }

    function submitCode(
        uint32 seasonIdx,
        address player,
        bytes32 codeHash,
        EncryptedCodeSubmission calldata submission
    )
        external
        onlyRegisteredPlayer(player)
        duringSameSeason(seasonIdx)
    {
        if (msg.sender != player) {
            if (!operators[player][msg.sender]) revert AccessError();
        }
        if (codeHash == 0) revert InvalidCodeHashError();
        if (submission.encryptedAesKey.length != ENCRYPTED_AES_KEY_SIZE
            || submission.encryptedCode.length > MAX_ENCRYPTED_CODE_SIZE)
        {
            revert PlayerSubmissionError();
        }
        SeasonInfo storage season = _seasons[seasonIdx];
        if (season.state != SeasonState.Started) revert SeasonNotActiveError();
        if (season.playerCodeHashes[player] == 0) ++season.playerCodeCount;
        season.playerCodeHashes[player] = codeHash;
        emit CodeCommitted(seasonIdx, player, codeHash, submission);
    }

    function startSeason(
        uint32 seasonIdx,
        bytes calldata seasonPubKey,
        address prevWinner
    )
        external
        payable
        onlyFrom(HOST)
    {
        if (seasonPubKey.length == 0) revert InvalidKeyError();
        if (seasonIdx == 0) {
            // Initial season.
            if (currentSeasonIdx != 0 || _seasons[0].state != SeasonState.Inactive) {
                revert NotSeasonError();
            }
        } else {
            if (currentSeasonIdx != seasonIdx - 1) revert NotSeasonError();
            SeasonInfo storage prevSeason = _seasons[seasonIdx - 1];
            if (prevSeason.state != SeasonState.Revealed) revert PreviousSeasonNotRevealedError();
            if (prevWinner != address(0)) {
                if (!isRegisteredPlayer(prevWinner)) revert InvalidPlayerError();
                uint96 unclaimedPrize_ = unclaimedPrize;
                // msg.value counts towards next season.
                uint96 prize = uint96(address(this).balance - msg.value) - unclaimedPrize_;
                unclaimedPrize = unclaimedPrize_ + prize;
                prevSeason.unclaimedPrize = prize;
                prevSeason.winner = prevWinner;
                emit WinnerDeclared(seasonIdx - 1, prevWinner, prize);
            }
        }
        _seasons[seasonIdx].state = SeasonState.Started;
        currentSeasonIdx = seasonIdx;
        emit SeasonStarted(seasonIdx, seasonPubKey);
    }

    function closeSeason(uint32 seasonIdx)
        external
        payable
        onlyFrom(HOST)
    {
        SeasonInfo storage season = _seasons[seasonIdx];
        if (season.state != SeasonState.Started) revert SeasonNotActiveError();
        season.state = SeasonState.Closed;
        emit SeasonClosed(seasonIdx);
    }

    function revealSeasonKey(uint32 seasonIdx, bytes calldata seasonPrivKey)
        external
        payable
        onlyFrom(HOST)
    {
        if (seasonPrivKey.length == 0) revert InvalidKeyError();
        SeasonInfo storage season = _seasons[seasonIdx];
        if (season.state != SeasonState.Closed) revert SeasonNotClosedError();
        season.state = SeasonState.Revealed;
        emit SeasonRevealed(seasonIdx, seasonPrivKey);
    }

    function claim(uint32 seasonIdx, address payable recipient) external {
        SeasonInfo storage season = _seasons[seasonIdx];
        if (season.winner != msg.sender) revert NotWinnerError();
        uint96 prize = season.unclaimedPrize;
        if (prize == 0) revert AlreadyClaimedError();
        season.unclaimedPrize = 0;
        unclaimedPrize -= prize; 
        _transferEth(recipient, prize);
        emit PrizeClaimed(seasonIdx, msg.sender, prize);
    }

    function isRegisteredPlayer(address player) public view returns (bool) {
        uint256 registeredBlock = playerRegisteredBlock[player];
        return registeredBlock != 0 && registeredBlock <= block.number;
    }

    function _consumeConfirmation(address registrant, Confirmation memory confirmation) private {
        if (confirmation.expiry < block.timestamp) revert InvalidConfirmationError();
        bytes32 h = LibContest.hashRegistration(
            address(this),
            block.chainid,
            registrant,
            confirmation.expiry,
            confirmation.nonce
        );
        if (confirmationConsumedBlock[h] != 0) revert ConfirmationConsumedError();
        confirmationConsumedBlock[h] = block.number;
        address signer = ecrecover(h, confirmation.v, confirmation.r, confirmation.s);
        if (signer == address(0) || signer != REGISTRAR) revert InvalidConfirmationError();
    }

    function _transferEth(address payable recipient, uint256 amount) private {
        (bool s, bytes memory r) = recipient.call{value: amount}("");
        if (!s) {
            assembly ("memory-safe") { 
                revert(add(r, 0x20), mload(r))
            }
        }
    }
}