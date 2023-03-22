// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IExchangeRateOracle {
    //    FIXME: optimize storage!
    //    TODO: should check if exchange rate is too old
    struct ExchangeRate {
        uint256 fromChainId;
        address fromToken;
        uint256 toChainId;
        address toToken;
        string roundId;
        uint256 exchangeRate;
    }

    /**
     * @notice Get amount by VND.
     * @return amount
     */
    function getExchangeRate(
        uint256 fromChainId,
        address fromToken,
        uint256 toChainId,
        address toToken
    ) external view returns (ExchangeRate memory);
}
