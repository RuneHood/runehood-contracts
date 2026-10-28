// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {CarvyRuneToken} from "./CarvyRuneToken.sol";

/// @title CarvyBridge
/// @notice Moves Carvy Runes 1:1 between this chain and Bitcoin.
///  - Out: holder burns tokens here; the custody co-signer (an Internet Computer canister using threshold ECDSA)
///    watches `BridgeOut` and releases the same amount of the native Rune from the Rune's 2-of-2 Bitcoin address.
///  - In: holder sends the native Rune to the Rune's custody address; the co-signer signs a `BridgeIn` voucher
///    (EIP-712) for the exact Bitcoin outpoint, and anyone can submit it here to mint. Each outpoint mints once.
///  Signer rotation is protected by a 48h timelock so any change is public two days before it can take effect.
contract CarvyBridge is EIP712, Ownable2Step {
    bytes32 public constant BRIDGE_IN_TYPEHASH =
        keccak256("BridgeIn(address token,address to,uint256 amount,bytes32 btcTxid,uint32 vout)");
    uint256 public constant SIGNER_DELAY = 48 hours;

    address public signer;
    address public pendingSigner;
    uint256 public pendingSignerAt;
    address public factory;

    mapping(address => bool) public isCarvyRune;
    mapping(bytes32 => bool) public processed; // keccak(btcTxid, vout)
    uint256 public outNonce;

    event BridgeOut(address indexed token, address indexed from, uint256 amount, string btcAddress, uint256 indexed nonce);
    event BridgeIn(address indexed token, address indexed to, uint256 amount, bytes32 btcTxid, uint32 vout);
    event SignerProposed(address signer, uint256 activeAt);
    event SignerChanged(address signer);

    error NotFactory();
    error NotRune();
    error BadAddress();
    error AlreadyProcessed();
    error BadSignature();
    error Timelocked();
    error ZeroAmount();

    constructor(address signer_, address owner_) EIP712("CarvyBridge", "1") Ownable(owner_) {
        signer = signer_;
        emit SignerChanged(signer_);
    }

    function setFactory(address f) external onlyOwner {
        if (factory != address(0)) revert NotFactory(); // one-time
        factory = f;
    }

    function register(address token) external {
        if (msg.sender != factory) revert NotFactory();
        isCarvyRune[token] = true;
    }

    /// @param btcAddress Taproot (bc1p…) or SegWit (bc1q…) address that receives the native Rune.
    function bridgeOut(address token, uint256 amount, string calldata btcAddress) external {
        if (!isCarvyRune[token]) revert NotRune();
        if (amount == 0) revert ZeroAmount();
        bytes memory a = bytes(btcAddress);
        if (a.length < 26 || a.length > 90 || a[0] != "b" || a[1] != "c" || a[2] != "1") revert BadAddress();
        CarvyRuneToken(token).bridgeBurn(msg.sender, amount);
        emit BridgeOut(token, msg.sender, amount, btcAddress, ++outNonce);
    }

    function bridgeIn(address token, address to, uint256 amount, bytes32 btcTxid, uint32 vout, bytes calldata sig) external {
        if (!isCarvyRune[token]) revert NotRune();
        bytes32 key = keccak256(abi.encode(btcTxid, vout));
        if (processed[key]) revert AlreadyProcessed();
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(BRIDGE_IN_TYPEHASH, token, to, amount, btcTxid, vout)));
        if (ECDSA.recover(digest, sig) != signer) revert BadSignature();
        processed[key] = true;
        CarvyRuneToken(token).bridgeMint(to, amount);
        emit BridgeIn(token, to, amount, btcTxid, vout);
    }

    function proposeSigner(address s) external onlyOwner {
        pendingSigner = s;
        pendingSignerAt = block.timestamp + SIGNER_DELAY;
        emit SignerProposed(s, pendingSignerAt);
    }

    function acceptSigner() external {
        if (pendingSigner == address(0) || block.timestamp < pendingSignerAt) revert Timelocked();
        signer = pendingSigner;
        pendingSigner = address(0);
        emit SignerChanged(signer);
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
