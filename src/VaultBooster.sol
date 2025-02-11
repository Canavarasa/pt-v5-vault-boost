// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "forge-std/console2.sol";

import { ILiquidationSource } from "pt-v5-liquidator-interfaces/interfaces/ILiquidationSource.sol";
import { PrizePool, IERC20, TwabController } from "pt-v5-prize-pool/PrizePool.sol";
import { UD60x18, convert } from "prb-math/UD60x18.sol";
import { UD2x18, intoUD60x18 } from "prb-math/UD2x18.sol";
import { Ownable } from "openzeppelin/access/Ownable.sol";
import { SafeERC20 } from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "openzeppelin/utils/math/SafeCast.sol";

/// @notice Emitted when someone tries to call liquidate and isn't the liquidation pair
error OnlyLiquidationPair();

/// @notice Emitted when the initial available exceeds the balance
/// @param initialAvailable The initial available
/// @param balance The actual token balance
error InitialAvailableExceedsBalance(uint144 initialAvailable, uint256 balance);

/// @notice Emitted when the liquidator attempts to liquidate more than the available balance
error InsufficientAvailableBalance(uint256 amountOut, uint256 available);

/// @notice Emitted when the liquidator attempts to liquidate for a token other than the prize token 
error UnsupportedTokenIn();

/// @notice Struct that holds the boost data
struct Boost {
  address liquidationPair;
  UD2x18 multiplierOfTotalSupplyPerSecond;
  uint96 tokensPerSecond;
  uint144 available;
  uint48 lastAccruedAt;
}

/// @title VaultBooster
/// @author G9 Software Inc.
/// @notice Allows someone to liquidate arbitrary tokens for a vault and improve the vault's chance of winning
contract VaultBooster is Ownable, ILiquidationSource {
  using SafeERC20 for IERC20;
  using SafeCast for uint256;

  /// @notice Emitted when a boost is set
  /// @param token The token to liquidate to boost the Vault's chances
  /// @param liquidationPair The pair that will act as the liquidator
  /// @param multiplierOfTotalSupplyPerSecond The multiplier of the total supply per second. Can be used to simulate APR. Can be combined with tokensPerSecond
  /// @param tokensPerSecond The number of tokens to accrue per second. Is a simple straight time*amount allocation. Can be combiend with the multiplier.
  /// @param initialAvailable The initial available balance
  /// @param lastAccruedAt The timestamp at which the boost was set
  event SetBoost(
    IERC20 indexed token,
    address liquidationPair,
    UD2x18 multiplierOfTotalSupplyPerSecond,
    uint96 tokensPerSecond,
    uint144 initialAvailable,
    uint48 lastAccruedAt
  );

  /// @notice Emitted when someone deposits tokens
  /// @param token The token that they deposited
  /// @param from The account that deposited the tokens
  /// @param amount The amount that was deposited.
  event Deposited(
    IERC20 indexed token,
    address indexed from,
    uint256 amount
  );

  /// @notice Emitted when tokens are withdrawn by the owner
  /// @param token The token that was withdrawn
  /// @param from The account that withdraw the tokens
  /// @param amount The amount of tokens that were withdrawn
  event Withdrawn(
    IERC20 indexed token,
    address indexed from,
    uint256 amount
  );

  /// @notice Emitted when tokens are liquidated
  /// @param token The token that was sold
  /// @param from The account that is receiving the tokens
  /// @param amountIn The amount of tokens that were contributed to the prize pool
  /// @param amountOut The amount of tokens that were sold
  /// @param availableBoostBalance The remaining available boost balance for the token
  event Liquidated(
    IERC20 indexed token,
    address indexed from,
    uint256 amountIn,
    uint256 amountOut,
    uint256 availableBoostBalance
  );

  /// @notice Emitted when boost tokens are accrued
  /// @param token The token that accrued
  /// @param availableBoostBalance The new available balance
  event BoostAccrued(
    IERC20 indexed token,
    uint256 availableBoostBalance
  );

  /// @notice The prize pool that this booster will contribute to
  PrizePool public immutable prizePool;

  /// @notice The prize pool's twab controller; copied here to save gas
  TwabController public immutable twabController;
  
  /// @notice The vault that the VaultBooster is boosting
  address public immutable vault;

  /// @notice The boosts that have been set
  mapping(IERC20 => Boost) internal _boosts;

  /// @notice Constructs a new VaultBooster
  /// @param _prizePool The prize pool to contribute to
  /// @param _vault The vault to boost
  /// @param _owner The owner of the VaultBooster contract
  constructor(
    PrizePool _prizePool,
    address _vault,
    address _owner
  ) Ownable(_owner) {
    prizePool = _prizePool;
    twabController = prizePool.twabController();
    vault = _vault;
  }

  /// @notice Retrieves boost details for a token
  /// @param _token The token whose boost details to retrieve
  /// @return The boost details
  function getBoost(IERC20 _token) external returns (Boost memory) {
    _accrue(_token);
    return _boosts[_token];
  }

  /// @notice Allows the owner to configure a boost for a token
  /// @param _token The token that will be liquidated to boost the chances of the vault
  /// @param _liquidationPair The liquidation pair that will facilitate liquidations
  /// @param _multiplierOfTotalSupplyPerSecond The multiplier of the total supply per second, useful for simulating APR. Can be combined with tokensPerSecond.
  /// @param _tokensPerSecond A simple tokensPerSecond*deltaTime accumulator. Can be combined with the multiplier.
  /// @param _initialAvailable The initial available balance. Must be less than or equal to the current balance of the VaultBooster of the given token.
  function setBoost(IERC20 _token, address _liquidationPair, UD2x18 _multiplierOfTotalSupplyPerSecond, uint96 _tokensPerSecond, uint144 _initialAvailable) external onlyOwner {
    if (_initialAvailable > 0) {
      uint256 balance = _token.balanceOf(address(this));
      if (balance < _initialAvailable) {
        revert InitialAvailableExceedsBalance(_initialAvailable, balance);
      }
    }
    _boosts[_token] = Boost({
      liquidationPair: _liquidationPair,
      multiplierOfTotalSupplyPerSecond: _multiplierOfTotalSupplyPerSecond,
      tokensPerSecond: _tokensPerSecond,
      available: _initialAvailable,
      lastAccruedAt: uint48(block.timestamp)
    });

    emit SetBoost(
      _token,
      _liquidationPair,
      _multiplierOfTotalSupplyPerSecond,
      _tokensPerSecond,
      _initialAvailable,
      uint48(block.timestamp)
    );
  }

  /// @notice Deposits tokens into this contract. 
  /// @dev Useful because it ensures `accrue` is called before depositing
  /// @param _token The token to deposit
  /// @param _amount The amount to deposit
  function deposit(IERC20 _token, uint256 _amount) external {
    _accrue(_token);
    _token.safeTransferFrom(msg.sender, address(this), _amount);

    emit Deposited(_token, msg.sender, _amount);
  }

  /// @notice Accrues the boost for the given token
  /// @param _token The token whose boost should be updated
  /// @return The new available balance of the boost
  function accrue(IERC20 _token) external returns (uint256) {
    return _accrue(_token);
  }

  /// @notice allows the owner to withdraw tokens
  /// @param _token The token to withdraw
  /// @param _amount The amount of tokens to withdraw
  function withdraw(IERC20 _token, uint256 _amount) external onlyOwner {
    uint256 availableBoost = _accrue(_token);
    uint256 availableBalance = _token.balanceOf(address(this));
    uint256 remainingBalance = availableBalance - _amount;
    _boosts[IERC20(_token)].available = (availableBoost > remainingBalance ? remainingBalance : availableBoost).toUint144();
    _token.transfer(msg.sender, _amount);

    emit Withdrawn(_token, msg.sender, _amount);
  }

  /// @notice Returns the available amount of tokens for a boost
  /// @param _tokenOut The token whose boost should be checked
  /// @return The available amount boost tokens
  function liquidatableBalanceOf(address _tokenOut) external override returns (uint256) {
    return _accrue(IERC20(_tokenOut));
  }

  /// @notice Allows the liquidation pair to liquidate tokens
  /// @param _account The account that will receive the liquidated tokens
  /// @param _tokenIn The tokens that will be contributed to the prize pool. Must be the prize token
  /// @param _amountIn The amount of tokens to contribute to the prize pool
  /// @param _tokenOut The tokens that are being liquidated
  /// @param _amountOut The amount of tokens to liquidate
  function liquidate(
    address _account,
    address _tokenIn,
    uint256 _amountIn,
    address _tokenOut,
    uint256 _amountOut
  ) external override onlyPrizeToken(_tokenIn) onlyLiquidationPair(_tokenOut) returns (bool) {
    uint256 amountAvailable = _computeAvailable(IERC20(_tokenOut));
    if (_amountOut > amountAvailable) {
      revert InsufficientAvailableBalance(_amountOut, amountAvailable);
    }
    amountAvailable = (amountAvailable - _amountOut);
    _boosts[IERC20(_tokenOut)].available = amountAvailable.toUint144();
    _boosts[IERC20(_tokenOut)].lastAccruedAt = uint48(block.timestamp);
    prizePool.contributePrizeTokens(vault, _amountIn);
    IERC20(_tokenOut).safeTransfer(_account, _amountOut);

    emit Liquidated(
      IERC20(_tokenOut),
      _account,
      _amountIn,
      _amountOut,
      amountAvailable
    );

    return true;
  }

  /// @notice Returns the liquidation target for the given input tokens. Input must be the prize token, and it always returns the prize pool.
  /// @param _tokenIn The token that will be received. Revert if it isn't the prize token.
  /// @return The address of the prize pool
  function targetOf(address _tokenIn) external view override onlyPrizeToken(_tokenIn) returns (address) {
    return address(prizePool);
  }

  /// @notice Accrues boost tokens
  /// @param _tokenOut The token whose boost should be accrued
  /// @return The new available balance of the boost
  function _accrue(IERC20 _tokenOut) internal returns (uint256) {
    uint256 available = _computeAvailable(_tokenOut);
    _boosts[_tokenOut].available = available.toUint144();
    _boosts[_tokenOut].lastAccruedAt = uint48(block.timestamp);

    emit BoostAccrued(_tokenOut, available);

    return available;
  }

  /// @notice Computes the available balance of the boost
  /// @param _tokenOut The token whose boost should be computed
  /// @return The new available balance
  function _computeAvailable(IERC20 _tokenOut) internal view returns (uint256) {
    Boost memory boost = _boosts[_tokenOut];
    uint256 deltaTime = block.timestamp - boost.lastAccruedAt;
    uint256 deltaAmount;
    if (deltaTime == 0) {
      return boost.available;
    }
    if (boost.tokensPerSecond > 0) {
      deltaAmount = boost.tokensPerSecond * deltaTime;
    }
    if (boost.multiplierOfTotalSupplyPerSecond.unwrap() > 0) {
      uint256 totalSupply = twabController.getTotalSupplyTwabBetween(address(vault), uint32(boost.lastAccruedAt), uint32(block.timestamp));
      deltaAmount += convert(boost.multiplierOfTotalSupplyPerSecond.intoUD60x18().mul(convert(deltaTime)).mul(convert(totalSupply)));
    }
    uint256 actualBalance = _tokenOut.balanceOf(address(this));
    uint256 availableBoost = boost.available + deltaAmount;
    return actualBalance > availableBoost ? availableBoost : actualBalance;
  }

  /// @notice Requires the given token to be the prize token
  /// @param _tokenIn The token to be checked as the prize token
  modifier onlyPrizeToken(address _tokenIn) {
    if (IERC20(_tokenIn) != prizePool.prizeToken()) {
      revert UnsupportedTokenIn();
    }
    _;
  }

  /// @notice Ensures that the caller is the liquidation pair for the given token
  /// @param _token The token whose boost's liquidation pair must be the caller
  modifier onlyLiquidationPair(address _token) {
    if (_boosts[IERC20(_token)].liquidationPair != msg.sender) {
      revert OnlyLiquidationPair();
    }
    _;
  }

}
