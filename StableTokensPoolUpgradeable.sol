// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-IERC20PermitUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";

import "./IExchangeRateOracle.sol";

import "./MultiSig.sol";

contract StableTokensPoolUpgradeable is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;

    address public multiSig;
    uint256 evmChainId;
    IERC20Upgradeable public tokenA;
    IERC20Upgradeable public tokenB;

    IExchangeRateOracle public oracle;
    uint256 public txFee; // 0.08 = 8
    uint256 public totalTokenAFee;
    uint256 public totalTokenBFee;
    uint256 public txIndex;

    // *** EVENTS *** //
    event TokenSwapped(
        address user,
        address fromToken,
        uint256 fromAmount,
        address recipient,
        address toToken,
        uint256 toAmount,
        uint256 txIndex,
        uint256 exchangeRate,
        uint256 txFee,
        uint256 feeAmount
    );

    event LiquidityAdded(address user, address tokenIn, uint256 amountIn);

    event LiquidityRemoved(
        address user,
        address to,
        address tokenA,
        uint256 amountA,
        address tokenB,
        uint256 amountB
    );

    modifier onlyMultiSig() {
        require(isMultiSig(msg.sender), "Caller is not multi-sig wallet");
        _;
    }

    modifier onlyMultiSigOwner() {
        require(
            isMultiSigOwner(msg.sender),
            "Caller is not owner of multi-sig wallet"
        );
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function isMultiSig(address _account) public view returns (bool) {
        return multiSig == _account;
    }

    function isMultiSigOwner(address _account) private view returns (bool) {
        return MultiSig(multiSig).isOwner(_account);
    }

    function initialize(
        address _tokenA,
        address _tokenB,
        address _multiSig,
        uint256 _evmChainId,
        IExchangeRateOracle _oracle
    ) public initializer {
        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
        tokenA = IERC20Upgradeable(_tokenA);
        tokenB = IERC20Upgradeable(_tokenB);
        multiSig = _multiSig;
        require(_evmChainId == block.chainid, "invalid evmChainId");
        evmChainId = _evmChainId;
        txFee = 8;
        txIndex = 1;
        oracle = _oracle;
    }

    function addLiquidity(
        address tokenIn,
        uint256 amountIn
    ) external whenNotPaused {
        IERC20Upgradeable erc20TokenIn = IERC20Upgradeable(tokenIn);

        require(amountIn > 0, "StableTokensPool: INVALID_AMOUNT");
        require(
            erc20TokenIn == tokenA || erc20TokenIn == tokenB,
            "StableTokensPool: INVALID_TOKEN"
        );
        // check allowance
        require(
            erc20TokenIn.allowance(msg.sender, address(this)) >= amountIn,
            "StableTokensPool: NOT_ALLOWANCE"
        );

        erc20TokenIn.safeTransferFrom(msg.sender, address(this), amountIn);

        emit LiquidityAdded(msg.sender, tokenIn, amountIn);
    }

    function removeLiquidity(
        uint256 amountA,
        uint256 amountB,
        address to
    ) external onlyMultiSig whenNotPaused {
        require(amountA > 0 || amountB > 0, "StableTokensPool: INVALID_AMOUNT");
        require(
            tokenA.balanceOf(address(this)) >= amountA,
            "StableTokensPool: INSUFFICIENT_AMOUNT_A"
        );
        require(
            tokenB.balanceOf(address(this)) >= amountB,
            "StableTokensPool: INSUFFICIENT_AMOUNT_B"
        );

        // transfer tokens to user's wallet
        tokenA.safeTransfer(to, amountA);
        tokenB.safeTransfer(to, amountB);

        emit LiquidityRemoved(
            msg.sender,
            to,
            address(tokenA),
            amountA,
            address(tokenB),
            amountB
        );
    }

    function swap(
        uint256 amountIn,
        address tokenIn,
        address to,
        uint256 currentExchangeRate
    ) external whenNotPaused returns (uint256 amountOut, address tokenOut) {
        (amountOut, tokenOut, ) = _swap(
            amountIn,
            tokenIn,
            to,
            currentExchangeRate
        );
    }

    function swapWithPermit(
        uint256 amountIn,
        address tokenIn,
        address to,
        uint256 currentExchangeRate,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external whenNotPaused returns (uint256 amountOut, address tokenOut) {
        IERC20PermitUpgradeable(tokenIn).permit(
            msg.sender,
            address(this),
            amountIn,
            deadline,
            v,
            r,
            s
        );

        (amountOut, tokenOut, ) = _swap(
            amountIn,
            tokenIn,
            to,
            currentExchangeRate
        );
    }

    function swapExactOutput(
        uint256 amountOut,
        address tokenOut,
        address to,
        uint256 currentExchangeRate
    )
        external
        whenNotPaused
        returns (uint256 amountInWithFee, address tokenIn)
    {
        (amountInWithFee, tokenIn, ) = _swapExactOutput(
            amountOut,
            tokenOut,
            to,
            currentExchangeRate
        );
    }

    function getExchangeRate() external view returns (uint256) {
        return _getExchangeRate();
    }

    function _getExchangeRate() private view returns (uint256) {
        /// @dev 1 token A = 24000 token B
        address fromToken = address(tokenA);
        address toToken = address(tokenB);
        IExchangeRateOracle.ExchangeRate memory data = IExchangeRateOracle(
            oracle
        ).getExchangeRate(evmChainId, fromToken, evmChainId, toToken);
        return data.exchangeRate;
    }

    function setTxFee(uint256 _txFee) external onlyMultiSigOwner {
        txFee = _txFee;
    }

    function pause() external onlyMultiSigOwner {
        _pause();
    }

    function unpause() external onlyMultiSig {
        _unpause();
    }

    function withdrawFee(
        uint256 amountA,
        uint256 amountB,
        address to
    ) external onlyOwner {
        require(amountA > 0 || amountB > 0, "StableTokensPool: INVALID_AMOUNT");
        require(
            totalTokenAFee >= amountA && totalTokenBFee >= amountB,
            "StableTokensPool: INVALID_AMOUNT_FEE"
        );

        if (amountA > 0) {
            tokenA.safeTransfer(to, amountA);
        }
        if (amountB > 0) {
            tokenB.safeTransfer(to, amountB);
        }
    }

    function reserves()
        external
        view
        returns (uint256 amountA, uint256 amountB)
    {
        amountA = tokenA.balanceOf(address(this));
        amountB = tokenB.balanceOf(address(this));
    }

    function getAmountOut(
        uint256 amountIn,
        address tokenIn
    )
        external
        view
        returns (uint256 amountOut, address tokenOut, uint256 totalFee)
    {
        return _getAmountOut(amountIn, tokenIn);
    }

    function getAmountIn(
        uint256 amountOut,
        address tokenOut
    )
        external
        view
        returns (uint256 amountInWithFee, address tokenIn, uint256 totalFee)
    {
        return _getAmountIn(amountOut, tokenOut);
    }

    // *** PRIVATE FUNCTIONS *** //

    function _swap(
        uint256 amountIn,
        address tokenIn,
        address to,
        uint256 currentExchangeRate
    ) private returns (uint256 amountOut, address tokenOut, uint256 totalFee) {
        uint256 exchangeRate = _getExchangeRate();
        require(
            exchangeRate == currentExchangeRate,
            "StableTokensPool: EXCHANGE_RATE_CHANGED"
        );

        (amountOut, tokenOut, totalFee) = _getAmountOut(amountIn, tokenIn);

        IERC20Upgradeable(tokenIn).safeTransferFrom(
            msg.sender,
            address(this),
            amountIn
        );
        IERC20Upgradeable(tokenOut).safeTransfer(to, amountOut);

        if (tokenIn == address(tokenA)) {
            totalTokenAFee += totalFee;
        } else {
            totalTokenBFee += totalFee;
        }
        txIndex += 1;

        emit TokenSwapped(
            msg.sender,
            tokenIn,
            amountIn,
            to,
            tokenOut,
            amountOut,
            txIndex,
            currentExchangeRate,
            txFee,
            totalFee
        );
    }

    function _getAmountOut(
        uint256 amountIn,
        address tokenIn
    )
        private
        view
        returns (uint256 amountOut, address tokenOut, uint256 totalFee)
    {
        IERC20Upgradeable erc20TokenIn = IERC20Upgradeable(tokenIn);
        ERC20Upgradeable erc20TokenA = ERC20Upgradeable(address(tokenA));
        ERC20Upgradeable erc20TokenB = ERC20Upgradeable(address(tokenB));

        require(amountIn > 0, "StableTokensPool: INSUFFICIENT_AMOUNT_IN");
        require(
            erc20TokenIn == tokenA || erc20TokenIn == tokenB,
            "StableTokensPool: INVALID_TOKEN"
        );

        totalFee = (amountIn * txFee) / 10000;
        uint256 amountInWithFee = amountIn - totalFee;

        uint256 exchangeRate = _getExchangeRate() / (10 ** 18);
        if (erc20TokenIn == tokenA) {
            amountOut =
                (amountInWithFee *
                    exchangeRate *
                    10 ** erc20TokenB.decimals()) /
                10 ** erc20TokenA.decimals();
            tokenOut = address(tokenB);
        } else {
            amountOut =
                (amountInWithFee * 10 ** erc20TokenA.decimals()) /
                (exchangeRate * 10 ** erc20TokenB.decimals());
            tokenOut = address(tokenA);
        }

        require(
            IERC20Upgradeable(tokenOut).balanceOf(address(this)) >= amountOut,
            "StableTokensPool: INSUFFICIENT_AMOUNT_OUT"
        );
    }

    function _swapExactOutput(
        uint256 amountOut,
        address tokenOut,
        address to,
        uint256 currentExchangeRate
    )
        private
        returns (uint256 amountInWithFee, address tokenIn, uint256 totalFee)
    {
        uint256 exchangeRate = _getExchangeRate();
        require(
            exchangeRate == currentExchangeRate,
            "StableTokensPool: EXCHANGE_RATE_CHANGED"
        );

        (amountInWithFee, tokenIn, totalFee) = _getAmountIn(
            amountOut,
            tokenOut
        );

        IERC20Upgradeable(tokenIn).safeTransferFrom(
            msg.sender,
            address(this),
            amountInWithFee
        );
        IERC20Upgradeable(tokenOut).safeTransfer(to, amountOut);

        if (tokenIn == address(tokenA)) {
            totalTokenAFee += totalFee;
        } else {
            totalTokenBFee += totalFee;
        }
        txIndex += 1;

        emit TokenSwapped(
            msg.sender,
            tokenIn,
            amountInWithFee,
            to,
            tokenOut,
            amountOut,
            txIndex,
            currentExchangeRate,
            txFee,
            totalFee
        );
    }

    function _getAmountIn(
        uint256 amountOut,
        address tokenOut
    )
        private
        view
        returns (uint256 amountInWithFee, address tokenIn, uint256 totalFee)
    {
        IERC20Upgradeable erc20TokenOut = IERC20Upgradeable(tokenOut);
        ERC20Upgradeable erc20TokenA = ERC20Upgradeable(address(tokenA));
        ERC20Upgradeable erc20TokenB = ERC20Upgradeable(address(tokenB));

        require(amountOut > 0, "StableTokensPool: INSUFFICIENT_AMOUNT_OUT");
        require(
            erc20TokenOut == tokenA || erc20TokenOut == tokenB,
            "StableTokensPool: INVALID_TOKEN"
        );
        require(
            IERC20Upgradeable(tokenOut).balanceOf(address(this)) >= amountOut,
            "StableTokensPool: INSUFFICIENT_AMOUNT_OUT"
        );

        uint256 exchangeRate = _getExchangeRate() / (10 ** 18);
        uint256 amountIn = 0;
        if (erc20TokenOut == tokenB) {
            amountIn =
                (amountOut * 10 ** erc20TokenA.decimals()) /
                (exchangeRate * 10 ** erc20TokenB.decimals());
            tokenIn = address(tokenA);
        } else {
            amountIn =
                (amountOut * exchangeRate * 10 ** erc20TokenB.decimals()) /
                (10 ** erc20TokenA.decimals());
            tokenIn = address(tokenB);
        }

        totalFee = (amountIn * txFee) / 10000;
        amountInWithFee = amountIn + totalFee;
    }

    function _authorizeUpgrade(address) internal override onlyMultiSig {}
}
