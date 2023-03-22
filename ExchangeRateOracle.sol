// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "./IExchangeRateOracle.sol";

contract ExchangeRateOracle is Initializable, OwnableUpgradeable, IExchangeRateOracle {
    using AddressUpgradeable for address;

    // manager for price update
    mapping(address => bool) public _managers;

    //    TODO: should be based on VND
    event ExchangeRateEvent(
        address oracle,
        uint256 fromChainId,
        address indexed fromToken,
        uint256 toChainId,
        address indexed toToken,
        string roundId,
        uint256 rate
    );

    mapping(bytes32 => ExchangeRate) booking;

    modifier onlyManagers() {
        require(_managers[msg.sender], "onlyManagers");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address[] memory managers_) public initializer {
        __Ownable_init();
        for (uint256 i = 0; i < managers_.length; i++) {
            _managers[managers_[i]] = true;
        }
    }

    function setExchangeRate(
        uint256 fromChainId,
        address fromToken,
        uint256 toChainId,
        address toToken,
        string calldata roundId,
        uint256 rate
    ) public onlyManagers {
        address oracle = msg.sender;
        bytes32 key = getKey(fromChainId, fromToken, toChainId, toToken);
        booking[key] = ExchangeRate(
            fromChainId,
            fromToken,
            toChainId,
            toToken,
            roundId,
            rate
        );
        emit ExchangeRateEvent(
            oracle,
            fromChainId,
            fromToken,
            toChainId,
            toToken,
            roundId,
            rate
        );
    }

    function getExchangeRate(
        uint256 fromChainId,
        address fromToken,
        uint256 toChainId,
        address toToken
    ) external view returns (ExchangeRate memory) {
        bytes32 key = getKey(fromChainId, fromToken, toChainId, toToken);
        return booking[key];
    }

    function getKey(
        uint256 fromChainId,
        address fromToken,
        uint256 toChainId,
        address toToken
    ) public pure returns (bytes32) {
        return
        keccak256(abi.encodePacked(fromChainId, fromToken, toChainId, toToken));
    }

    function setManagersBatch(
        address[] calldata managers,
        bool[] calldata flags
    ) external onlyOwner {
        for (uint256 i = 0; i < managers.length; i++) {
            setManager(managers[i], flags[i]);
        }
    }

    function setManager(address manager, bool flag) public onlyOwner {
        require(_managers[manager] != flag, "Not do anythings");
        _managers[manager] = flag;
    }
}