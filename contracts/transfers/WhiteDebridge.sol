// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "../interfaces/IWhiteDebridge.sol";
import "../interfaces/IWhiteAggregator.sol";
import "../periphery/WrappedAsset.sol";

contract WhiteDebridge is AccessControl, IWhiteDebridge {
    using SafeERC20 for IERC20;

    struct DebridgeInfo {
        address tokenAddress; // asset address on the current chain
        uint256 chainId; // native chain id
        uint256 minAmount; // minimal amount to transfer
        uint256 transferFee; // transfer fee rate
        uint256 collectedFees; // total collected fees that can be used to buy LINK
        mapping(uint256 => bool) isSupported; // wheter the chain for the asset is supported
    }

    uint256 public constant DENOMINATOR = 1e18; // accuacy multiplyer
    uint256 public chainId; // current chain id
    uint256 public nonce; // global counter for transfers
    IWhiteAggregator public aggregator; // chainlink aggregator address
    mapping(bytes32 => DebridgeInfo) public getDebridge; // debridgeId (i.e. hash(native chainId, native tokenAddress)) => token
    mapping(bytes32 => bool) public isSubmissionUsed; // submissionId (i.e. hash( debridgeId, amount, receiver, nonce)) => whether is claimed

    event Sent(
        bytes32 sentId,
        bytes32 debridgeId,
        uint256 amount,
        address receiver,
        uint256 nonce,
        uint256 chainIdTo
    ); // emited once the native tokens are locked to be sent to the other chain
    event Minted(uint256 amount, address receiver, bytes32 debridgeId); // emited once the wrapped tokens are minted on the current chain
    event Burnt(
        bytes32 burntId,
        bytes32 debridgeId,
        uint256 amount,
        address receiver,
        uint256 nonce,
        uint256 chainIdTo
    ); // emited once the wrapped tokens are sent to the contract
    event Claimed(uint256 amount, address receiver, bytes32 debridgeId); // emited once the tokens are withdrawn on native chain

    modifier onlyAggregator {
        require(address(aggregator) == msg.sender, "onlyAggregator: bad role");
        _;
    }
    modifier onlyAdmin {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "onlyAdmin: bad role");
        _;
    }

    /* EXTERNAL */

    /// @dev Constructor that initializes the most important configurations.
    /// @param _chainId Current chain id.
    /// @param _minAmount Minimal amount of current chain token to be wrapped.
    /// @param _transferFee Transfer fee rate.
    /// @param _aggregator Submission aggregator address.
    /// @param _supportedChainIds Chain ids where native token of the current chain can be wrapped.
    constructor(
        uint256 _chainId,
        uint256 _minAmount,
        uint256 _transferFee,
        IWhiteAggregator _aggregator,
        uint256[] memory _supportedChainIds
    ) {
        chainId = _chainId;
        bytes32 debridgeId = getDebridgeId(_chainId, address(0));
        _addAsset(
            debridgeId,
            address(0),
            chainId,
            _minAmount,
            _transferFee,
            _supportedChainIds
        );
        aggregator = _aggregator;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @dev Locks asset on the chain and enables minting on the other chain.
    /// @param _debridgeId Asset identifier.
    /// @param _receiver Receiver address.
    /// @param _amount Amount to be transfered (note: the fee can be applyed).
    /// @param _chainIdTo Chain id of the target chain.
    function send(
        bytes32 _debridgeId,
        address _receiver,
        uint256 _amount,
        uint256 _chainIdTo
    ) external payable override {
        DebridgeInfo storage debridge = getDebridge[_debridgeId];
        require(debridge.chainId == chainId, "send: not native chain chain");
        require(
            debridge.isSupported[_chainIdTo],
            "send: wrong targed target chain"
        );
        require(_amount >= debridge.minAmount, "send: amount too low");
        if (debridge.tokenAddress == address(0)) {
            require(_amount == msg.value, "send: amount mismatch");
        } else {
            IERC20(debridge.tokenAddress).safeTransferFrom(
                msg.sender,
                address(this),
                _amount
            );
        }
        uint256 transferFee = (_amount * debridge.transferFee) / DENOMINATOR;
        if (transferFee > 0) {
            debridge.collectedFees += transferFee;
            _amount -= transferFee;
        }
        bytes32 sentId = getSubmisionId(_debridgeId, _amount, _receiver, nonce);
        emit Sent(sentId, _debridgeId, _amount, _receiver, nonce, _chainIdTo);
        nonce++;
    }

    /// @dev Mints wrapped asset on the current chain.
    /// @param _debridgeId Asset identifier.
    /// @param _receiver Receiver address.
    /// @param _amount Amount of the transfered asset (note: without applyed fee).
    /// @param _nonce Submission id.
    function mint(
        bytes32 _debridgeId,
        address _receiver,
        uint256 _amount,
        uint256 _nonce
    ) external override {
        bytes32 mintId =
            getSubmisionId(_debridgeId, _amount, _receiver, _nonce);
        require(aggregator.isMintConfirmed(mintId), "mint: not confirmed");
        require(!isSubmissionUsed[mintId], "mint: already used");
        DebridgeInfo storage debridge = getDebridge[_debridgeId];
        isSubmissionUsed[mintId] = true;
        IWrappedAsset(debridge.tokenAddress).mint(_receiver, _amount);
        emit Minted(_amount, _receiver, _debridgeId);
    }

    /// @dev Burns wrapped asset and allowss to claim it on the other chain.
    /// @param _debridgeId Asset identifier.
    /// @param _receiver Receiver address.
    /// @param _amount Amount of the transfered asset (note: the fee can be applyed).
    function burn(
        bytes32 _debridgeId,
        address _receiver,
        uint256 _amount
    ) external override {
        DebridgeInfo storage debridge = getDebridge[_debridgeId];
        require(debridge.chainId != chainId, "burn: native asset");
        require(_amount >= debridge.minAmount, "burn: amount too low");
        IWrappedAsset wrappedAsset = IWrappedAsset(debridge.tokenAddress);
        wrappedAsset.transferFrom(msg.sender, address(this), _amount);
        wrappedAsset.burn(_amount);
        bytes32 burntId =
            getSubmisionId(_debridgeId, _amount, _receiver, nonce);
        emit Burnt(
            burntId,
            _debridgeId,
            _amount,
            _receiver,
            nonce,
            debridge.chainId
        );
        nonce++;
    }

    /// @dev Unlock the asset on the current chain and transfer to receiver.
    /// @param _debridgeId Asset identifier.
    /// @param _receiver Receiver address.
    /// @param _amount Amount of the transfered asset (note: the fee can be applyed).
    /// @param _nonce Submission id.
    function claim(
        bytes32 _debridgeId,
        address _receiver,
        uint256 _amount,
        uint256 _nonce
    ) external override {
        bytes32 burntId =
            getSubmisionId(_debridgeId, _amount, _receiver, _nonce);
        require(aggregator.isBurntConfirmed(burntId), "claim: not confirmed");
        DebridgeInfo storage debridge = getDebridge[_debridgeId];
        require(debridge.chainId == chainId, "claim: wrong target chain");
        require(!isSubmissionUsed[burntId], "claim: already used");
        isSubmissionUsed[burntId] = true;
        uint256 transferFee = (_amount * debridge.transferFee) / DENOMINATOR;
        if (transferFee > 0) {
            debridge.collectedFees += transferFee;
            _amount -= transferFee;
        }
        if (debridge.tokenAddress == address(0)) {
            payable(_receiver).transfer(_amount);
        } else {
            IERC20(debridge.tokenAddress).safeTransfer(_receiver, _amount);
        }
        emit Claimed(_amount, _receiver, _debridgeId);
    }

    /* ADMIN */

    /// @dev Add support for the asset on the current chain.
    /// @param _tokenAddress Address of the asset on the current chain.
    /// @param _minAmount Minimal amount of current chain token to be wrapped.
    /// @param _transferFee Transfer fee rate.
    /// @param _supportedChainIds Chain ids where native token of the current chain can be wrapped.
    function addNativelAsset(
        address _tokenAddress,
        uint256 _minAmount,
        uint256 _transferFee,
        uint256[] memory _supportedChainIds
    ) external override onlyAdmin() {
        bytes32 debridgeId = getDebridgeId(chainId, _tokenAddress);
        _addAsset(
            debridgeId,
            _tokenAddress,
            chainId,
            _minAmount,
            _transferFee,
            _supportedChainIds
        );
    }

    /// @dev Add support for the asset from the other chain, deploy new wrapped asset.
    /// @param _tokenAddress Address of the asset on the other chain.
    /// @param _chainId Current chain id.
    /// @param _minAmount Minimal amount of the asset to be wrapped.
    /// @param _transferFee Transfer fee rate.
    /// @param _supportedChainIds Chain ids where the token of the current chain can be transfered.
    /// @param _name Wrapped asset name.
    /// @param _symbol Wrapped asset symbol.
    function addExternalAsset(
        address _tokenAddress,
        uint256 _chainId,
        uint256 _minAmount,
        uint256 _transferFee,
        uint256[] memory _supportedChainIds,
        string memory _name,
        string memory _symbol
    ) external override onlyAdmin() {
        bytes32 debridgeId = getDebridgeId(_chainId, _tokenAddress);
        address tokenAddress = address(new WrappedAsset(_name, _symbol));
        _addAsset(
            debridgeId,
            tokenAddress,
            _chainId,
            _minAmount,
            _transferFee,
            _supportedChainIds
        );
    }

    /// @dev Set support for the chains where the token can be transfered.
    /// @param _debridgeId Asset identifier.
    /// @param _chainId Current chain id.
    /// @param _isSupported Whether the token is transferable to the other chain.
    function setChainIdSupport(
        bytes32 _debridgeId,
        uint256 _chainId,
        bool _isSupported
    ) external override onlyAdmin() {
        DebridgeInfo storage debridge = getDebridge[_debridgeId];
        debridge.isSupported[_chainId] = _isSupported;
    }

    /// @dev Set aggregator address.
    /// @param _aggregator Submission aggregator address.
    function setAggregator(IWhiteAggregator _aggregator) external onlyAdmin() {
        aggregator = _aggregator;
    }

    /// @dev Withdraw fees.
    /// @param _debridgeId Asset identifier.
    /// @param _receiver Receiver address.
    /// @param _amount Submission aggregator address.
    function withdrawFee(
        bytes32 _debridgeId,
        address _receiver,
        uint256 _amount
    ) external onlyAdmin() {
        DebridgeInfo storage debridge = getDebridge[_debridgeId];
        require(debridge.chainId == chainId, "withdrawFee: wrong target chain");
        require(
            debridge.collectedFees >= _amount,
            "withdrawFee: not enough fee"
        );
        debridge.collectedFees -= _amount;
        if (debridge.tokenAddress == address(0)) {
            payable(_receiver).transfer(_amount);
        } else {
            IERC20(debridge.tokenAddress).safeTransfer(_receiver, _amount);
        }
    }

    /* INTERNAL */

    /// @dev Add support for the asset.
    /// @param _debridgeId Asset identifier.
    /// @param _tokenAddress Address of the asset on the other chain.
    /// @param _chainId Current chain id.
    /// @param _minAmount Minimal amount of the asset to be wrapped.
    /// @param _transferFee Transfer fee rate.
    /// @param _supportedChainIds Chain ids where the token of the current chain can be transfered.
    function _addAsset(
        bytes32 _debridgeId,
        address _tokenAddress,
        uint256 _chainId,
        uint256 _minAmount,
        uint256 _transferFee,
        uint256[] memory _supportedChainIds
    ) internal {
        DebridgeInfo storage debridge = getDebridge[_debridgeId];
        debridge.tokenAddress = _tokenAddress;
        debridge.chainId = _chainId;
        debridge.minAmount = _minAmount;
        debridge.transferFee = _transferFee;
        for (uint256 i = 0; i < _supportedChainIds.length; i++) {
            debridge.isSupported[_supportedChainIds[i]] = true;
        }
    }

    /* VIEW */

    function getDebridgeId(uint256 _chainId, address _tokenAddress)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(_chainId, _tokenAddress));
    }

    function getSubmisionId(
        bytes32 _debridgeId,
        uint256 _amount,
        address _receiver,
        uint256 _nonce
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(_debridgeId, _amount, _receiver, _nonce)
            );
    }
}