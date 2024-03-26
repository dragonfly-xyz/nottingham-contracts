// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

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
    Closed
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
    
library LibContest {
    bytes32 constant private REGISTRATION_PREFIX = keccak256(unicode"ᴙɘgiꙅTᴙATioᴎ");

    function hashRegistration(
        address contest,
        uint256 chainId,
        address registrant,
        Confirmation memory confirmation
    )
        internal pure returns (bytes32)
    {
        return keccak256(abi.encode(
            REGISTRATION_PREFIX,
            contest,
            chainId,
            registrant,
            confirmation.expiry,
            confirmation.nonce
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
    error InvalidKeyError();
    error NotWinnerError();
    error AlreadyClaimedError();
    error PlayerSubmissionError();

    event Registered(address indexed player);
    event Retired(address indexed player);
    event SeasonClosed(uint32 indexed season, bytes privateKey);
    event WinnerDeclared(uint32 indexed season, address indexed winner, uint256 prize);
    event SeasonStarted(uint32 indexed season, bytes publicKey);
    event PrizeClaimed(uint32 indexed season, address indexed winner, uint256 prize);
    event CodeCommitted(
        uint32 indexed season,
        address indexed player,
        bytes32 codeHash,
        EncryptedCodeSubmission submission
    );

    uint256 constant MAX_ENCRYPTED_CODE_SIZE = 0x10100;
    uint256 constant ENCRYPTED_AES_KEY_SIZE = 128;

    address public immutable HOST;
    address public immutable ADMIN;
    address public immutable REGISTRAR;

    uint32 public playerCount;
    uint32 public currentSeasonIdx;
    uint96 public unclaimedPrize;
    mapping (uint32 seasonIdx => SeasonInfo info) private _seasons;
    mapping (address player => uint256 block) public playerRegisteredBlock;
    mapping (bytes32 confirmationHash => uint256 block) public confirmationConsumedBlock;

    constructor(address payable host, address retirer, address notary) {
        HOST = host;
        REGISTRAR = notary;
        ADMIN = retirer;
    }

    modifier onlyFrom(address from) {
        if (msg.sender != from) revert AccessError();
        _;
    }

    modifier onlyRegisteredPlayer() {
        if (playerRegisteredBlock[msg.sender] == 0) revert NotRegisteredError();
        _;
    }

    modifier duringSameSeason(uint32 seasonIdx) {
        if (seasonIdx != currentSeasonIdx) revert NotSeasonError();
        _;
    }
    
    function retire(address payable player) external onlyFrom(ADMIN) {
        if (playerRegisteredBlock[player] != 0) {
            playerRegisteredBlock[player] = block.number;
            --playerCount;
            SeasonInfo storage season = _seasons[currentSeasonIdx];
            if (season.playerCodeHashes[player] != 0) {
                season.playerCodeHashes[player] = 0;
                --season.playerCodeCount;
            }
            emit Retired(player);
        }
    }

    function register(Confirmation memory confirmation) external {
        if (playerRegisteredBlock[msg.sender] == 0) {
            _consumeConfirmation(msg.sender, confirmation);
            playerRegisteredBlock[msg.sender] = block.number;
            ++playerCount;
            emit Registered(msg.sender);
        }
    }

    function getSeasonState() external view returns (SeasonState) {
        return _seasons[currentSeasonIdx].state;
    }

    function submitCode(
        uint32 seasonIdx,
        bytes32 codeHash,
        EncryptedCodeSubmission calldata submission
    )
        external
        onlyRegisteredPlayer
        duringSameSeason(seasonIdx)
    {
        if (submission.encryptedAesKey.length != ENCRYPTED_AES_KEY_SIZE
            || submission.encryptedCode.length > MAX_ENCRYPTED_CODE_SIZE)
        {
            revert PlayerSubmissionError();
        }
        SeasonInfo storage season = _seasons[seasonIdx];
        if (season.state != SeasonState.Started) revert SeasonNotActiveError();
        if (season.playerCodeHashes[msg.sender] == 0) ++season.playerCodeCount;
        season.playerCodeHashes[msg.sender] = codeHash;
        emit CodeCommitted(seasonIdx, msg.sender, codeHash, submission);
    }

    function getPlayerCodeHash(uint32 seasonIdx, address player)
        external view returns (bytes32 codeHash)
    {
        if (playerRegisteredBlock[player] == 0) {
            return 0;
        }
        return _seasons[seasonIdx].playerCodeHashes[player];
    }

    function getSeasonPlayerCodeCount(uint32 seasonIdx)
        external view returns (uint32 playerCount_)
    {
        return _seasons[seasonIdx].playerCodeCount;
    }

    function getWinner(uint32 seasonIdx)
        external view returns (address winner, uint96 unclaimedPrize_)
    {
        SeasonInfo storage season = _seasons[seasonIdx];
        return (season.winner, season.unclaimedPrize);
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
            SeasonInfo storage prevSeason = _seasons[seasonIdx - 1];
            if (prevSeason.state != SeasonState.Closed) revert SeasonNotClosedError();
            if (prevWinner != address(0)) {
                uint96 unclaimedPrize_ = unclaimedPrize;
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

    function endSeason(uint32 seasonIdx, bytes calldata seasonPrivKey)
        external
        payable
        onlyFrom(HOST)
    {
        if (seasonPrivKey.length == 0) revert InvalidKeyError();
        SeasonInfo storage season = _seasons[seasonIdx];
        if (season.state != SeasonState.Started) revert SeasonNotActiveError();
        season.state = SeasonState.Closed;
        emit SeasonClosed(seasonIdx, seasonPrivKey);
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

    receive() payable external {}

    function _consumeConfirmation(address registrant, Confirmation memory confirmation) private {
        bytes32 h = LibContest.hashRegistration(
            address(this),
            block.chainid,
            registrant,confirmation
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