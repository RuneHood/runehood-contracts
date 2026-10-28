// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

interface ICarvyLaunchpadClaim {
    function claim(address quote) external;
}

/// @title CarvyHolderRewards
/// @notice Pays the creator share of Runes launched in "Holders" fee mode to their holders, pro rata.
///  - This contract is the launchpads' holder-rewards vault: curve fees accrue to it and graduated-pool taxes are
///    paid straight to it. Anyone can pull accrued fees from a launchpad into it.
///  - Every epoch Carvy publishes a Merkle root of cumulative rewards per (holder, asset), computed from on-chain
///    balances of each Holders-mode Rune. Holders claim the difference to what they already claimed, any time.
///  - Roots are cumulative, so a missed claim is never lost.
contract CarvyHolderRewards is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    address public constant NATIVE = address(0);

    bytes32 public merkleRoot;
    uint256 public epoch;
    string public epochURI;
    address public updater;
    mapping(address => mapping(address => uint256)) public claimed; // holder => asset => cumulative claimed

    event RootUpdated(uint256 indexed epoch, bytes32 root, string uri);
    event Claimed(address indexed holder, address indexed asset, uint256 amount, uint256 cumulative);
    event UpdaterChanged(address updater);

    error NotUpdater();
    error BadProof();
    error NothingToClaim();
    error TransferFailed();

    constructor(address owner_, address updater_) Ownable(owner_) {
        updater = updater_;
        emit UpdaterChanged(updater_);
    }

    receive() external payable {}

    function setUpdater(address u) external onlyOwner {
        updater = u;
        emit UpdaterChanged(u);
    }

    function setRoot(bytes32 root, string calldata uri) external {
        if (msg.sender != updater && msg.sender != owner()) revert NotUpdater();
        merkleRoot = root;
        epochURI = uri;
        emit RootUpdated(++epoch, root, uri);
    }

    /// @notice Move fees that accrued to this vault on a launchpad into this contract. Anyone can call it.
    function pull(address launchpad, address quote) external {
        ICarvyLaunchpadClaim(launchpad).claim(quote);
    }

    function leafOf(address holder, address asset, uint256 cumulative) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(holder, asset, cumulative))));
    }

    function claim(address holder, address asset, uint256 cumulative, bytes32[] calldata proof) external nonReentrant {
        if (!MerkleProof.verifyCalldata(proof, merkleRoot, leafOf(holder, asset, cumulative))) revert BadProof();
        uint256 already = claimed[holder][asset];
        if (cumulative <= already) revert NothingToClaim();
        uint256 amount = cumulative - already;
        claimed[holder][asset] = cumulative;
        if (asset == NATIVE) {
            (bool ok,) = holder.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(asset).safeTransfer(holder, amount);
        }
        emit Claimed(holder, asset, amount, cumulative);
    }
}
