// SPDX-License-Identifier: MIT
// Copyright 2021 Primitive Finance
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of
// this software and associated documentation files (the "Software"), to deal in
// the Software without restriction, including without limitation the rights to
// use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is furnished to do
// so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

pragma solidity ^0.6.2;

/**
 * @title   Library for Swap Logic for Uniswap AMM.
 * @notice  Primitive Router Lib - @primitivefi/v1-connectors@2.0.0
 * @author  Primitive
 */

// Uniswap
import {
    IUniswapV2Router02
} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
// Primitive
import {
    IOption
} from "@primitivefi/contracts/contracts/option/interfaces/ITrader.sol";
import {
    TraderLib,
    IERC20
} from "@primitivefi/contracts/contracts/option/libraries/TraderLib.sol";
import {IWETH} from "../interfaces/IWETH.sol";
// Open Zeppelin
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {
  IRegistry
} from "@primitivefi/contracts/contracts/option/interfaces/IRegistry.sol";

library PrimitiveRouterLib {
    using SafeERC20 for IERC20; // Reverts when `transfer` or `transferFrom` erc20 calls don't return proper data
    using SafeMath for uint256; // Reverts on math underflows/overflows

    event Minted(
        address indexed from,
        address indexed optionToken,
        uint256 longQuantity,
        uint256 shortQuantity
    );

    event Exercised(
        address indexed from,
        address indexed optionToken,
        uint256 quantity
    );

    function realOption(
      IOption option,
      IRegistry registry
    ) internal returns (bool) {
      return(
        address(option) == registry.getOptionAddress(
          option.getUnderlyingTokenAddress(),
          option.getStrikeTokenAddress(),
          option.getBaseValue(),
          option.getQuoteValue(),
          option.getExpiryTime()
        )
        &&
        address(option) != address(0)
      );
    }

    /**
     * @dev    Calculates the effective premium, denominated in underlyingTokens, to "buy" `quantity` of optionTokens.
     * @notice UniswapV2 adds a 0.3009027% fee which is applied to the premium as 0.301%.
     *         IMPORTANT: If the pair's reserve ratio is incorrect, there could be a 'negative' premium.
     *         Buying negative premium options will pay out redeemTokens.
     *         An 'incorrect' ratio occurs when the (reserves of redeemTokens / strike ratio) >= reserves of underlyingTokens.
     *         Implicitly uses the `optionToken`'s underlying and redeem tokens for the pair.
     * @param  router The UniswapV2Router02 contract.
     * @param  optionToken The optionToken to get the premium cost of purchasing.
     * @param  quantity The quantity of long option tokens that will be purchased.
     */
    function getOpenPremium(
        IUniswapV2Router02 router,
        IOption optionToken,
        uint256 quantity
    )
        internal
        view
        returns (
            /* override */
            uint256,
            uint256
        )
    {
        // longOptionTokens are opened by doing a swap from redeemTokens to underlyingTokens effectively.
        address[] memory path = new address[](2);
        path[0] = optionToken.redeemToken();
        path[1] = optionToken.getUnderlyingTokenAddress();

        // `quantity` of underlyingTokens are output from the swap.
        // They are used to mint options, which will mint `quantity` * quoteValue / baseValue amount of redeemTokens.
        uint256 redeemsMinted =
            getProportionalShortOptions(optionToken, quantity);

        // The loanRemainderInUnderlyings will be the amount of underlyingTokens that are needed from the original
        // transaction caller in order to pay the flash swap.
        // IMPORTANT: THIS IS EFFECTIVELY THE PREMIUM PAID IN UNDERLYINGTOKENS TO PURCHASE THE OPTIONTOKEN.
        uint256 loanRemainderInUnderlyings;

        // Economically, negativePremiumPaymentInRedeems value should always be 0.
        // In the case that we minted more redeemTokens than are needed to pay back the flash swap,
        // (short -> underlying is a positive trade), there is an effective negative premium.
        // In that case, this function will send out `negativePremiumAmount` of redeemTokens to the original caller.
        // This means the user gets to keep the extra redeemTokens for free.
        // Negative premium amount is the opposite difference of the loan remainder: (paid - flash loan amount)
        uint256 negativePremiumPaymentInRedeems;

        // Need to return tokens from the flash swap by returning shortOptionTokens and any remainder of underlyingTokens.

        // Since the borrowed amount is underlyingTokens, and we are paying back in redeemTokens,
        // we need to see how much redeemTokens must be returned for the borrowed amount.
        // We can find that value by doing the normal swap math, getAmountsIn will give us the amount
        // of redeemTokens are needed for the output amount of the flash loan.
        // IMPORTANT: amountsIn[0] is how many short tokens we need to pay back.
        // This value is most likely greater than the amount of redeemTokens minted.
        uint256[] memory amountsIn = router.getAmountsIn(quantity, path);

        uint256 redeemsRequired = amountsIn[0]; // the amountIn of redeemTokens based on the amountOut of `quantity`.
        // If redeemsMinted is greater than redeems required, there is a cost of 0, implying a negative premium.
        uint256 redeemCostRemaining =
            redeemsRequired > redeemsMinted
                ? redeemsRequired.sub(redeemsMinted)
                : 0;
        // If there is a negative premium, calculate the quantity of remaining redeemTokens after the `redeemsMinted` is spent.
        negativePremiumPaymentInRedeems = redeemsMinted > redeemsRequired
            ? redeemsMinted.sub(redeemsRequired)
            : 0;

        // In most cases, there will be an outstanding cost (assuming we minted less redeemTokens than the
        // required amountIn of redeemTokens for the swap).
        if (redeemCostRemaining > 0) {
            // The user won't want to pay back the remaining cost in redeemTokens,
            // because they borrowed underlyingTokens to mint them in the first place.
            // So instead, we get the quantity of underlyingTokens that could be paid instead.
            // We can calculate this using normal swap math.
            // getAmountsOut will return the quantity of underlyingTokens that are output,
            // based on some input of redeemTokens.
            // The input redeemTokens is the remaining redeemToken cost, and the output
            // underlyingTokens is the proportional amount of underlyingTokens.
            // amountsOut[1] is then the outstanding flash loan value denominated in underlyingTokens.
            uint256[] memory amountsOut =
                router.getAmountsOut(redeemCostRemaining, path);

            // Returning withdrawn tokens to the pair has a fee of .003 / .997 = 0.3009027% which must be applied.
            loanRemainderInUnderlyings = (
                amountsOut[1].mul(100000).add(amountsOut[1].mul(301))
            )
                .div(100000);
        }
        return (loanRemainderInUnderlyings, negativePremiumPaymentInRedeems);
    }

    /**
     * @dev     Swaps msg.value of strikeTokens (ethers) to underlyingTokens.
     *          Uses the strike ratio as the exchange rate. Strike ratio = base / quote.
     *          Msg.value (quote units) * base / quote = base units (underlyingTokens) to withdraw.
     * @notice  This function is for options with WETH as the strike asset.
     *          Burns option tokens, accepts ethers, and pushes out underlyingTokens.
     * @param   optionToken The address of the option contract.
     * @param   receiver The underlyingTokens are sent to the receiver address.
     */
    function safeExerciseWithETH(IOption optionToken, address receiver, IWETH weth)
        internal
        returns (uint256, uint256)
    {
        require(msg.value > 0, "ERR_ZERO");
        // Require one of the option's assets to be WETH.
        require(optionToken.getStrikeTokenAddress() == address(weth), "ERR_NOT_WETH");
        // Calculate quantity of optionTokens needed to burn.
        // An ether put option with strike price $300 has a "base" value of 300, and a "quote" value of 1.
        // To calculate how many options are needed to be burned, we need to cancel out the "quote" units.
        // The input strike quantity can be multiplied by the strike ratio to cancel out "quote" units.
        // 1 ether (quote units) * 300 (base units) / 1 (quote units) = 300 inputOptions
        uint256 inputOptions =
            PrimitiveRouterLib.getProportionalLongOptions(
                optionToken,
                msg.value
            );

        // Wrap the ethers into WETH, and send the WETH to the option contract to prepare for calling exerciseOptions().
        safeTransferETHFromWETH(
            weth,
            address(optionToken),
            msg.value
        );
        IERC20(address(optionToken)).safeTransferFrom(
            msg.sender,
            address(optionToken),
            inputOptions
        );

        // Burns the transferred option tokens, stores the strike asset (ether), and pushes underlyingTokens
        // to the receiver address.
        emit Exercised(msg.sender, address(optionToken), inputOptions);
        return
            optionToken.exerciseOptions(receiver, inputOptions, new bytes(0));
    }

    /**
     * @dev     Swaps strikeTokens to underlyingTokens using the strike ratio as the exchange rate.
     * @notice  Burns optionTokens, option contract receives strikeTokens, user receives underlyingTokens.
     * @param   optionToken The address of the option contract.
     * @param   exerciseQuantity Quantity of optionTokens to exercise.
     * @param   receiver The underlyingTokens are sent to the receiver address.
     */
    function safeExercise(
        IOption optionToken,
        uint256 exerciseQuantity,
        address receiver
    ) internal returns (uint256, uint256) {
        // Calculate quantity of strikeTokens needed to exercise quantity of optionTokens.
        uint256 inputStrikes =
            PrimitiveRouterLib.getProportionalShortOptions(
                optionToken,
                exerciseQuantity
            );
        IERC20(address(optionToken)).safeTransferFrom(
            msg.sender,
            address(optionToken),
            exerciseQuantity
        );
        IERC20(optionToken.getStrikeTokenAddress()).safeTransferFrom(
            msg.sender,
            address(optionToken),
            inputStrikes
        );
        emit Exercised(msg.sender, address(optionToken), exerciseQuantity);
        return
            optionToken.exerciseOptions(
                receiver,
                exerciseQuantity,
                new bytes(0)
            );
    }

    /**
     * @dev    Calculates the effective premium, denominated in underlyingTokens, to "sell" option tokens.
     * @param  router The UniswapV2Router02 contract.
     * @param  optionToken The optionToken to get the premium cost of purchasing.
     * @param  quantity The quantity of short option tokens that will be closed.
     */
    function getClosePremium(
        IUniswapV2Router02 router,
        IOption optionToken,
        uint256 quantity
    )
        internal
        view
        returns (
            /* override */
            uint256,
            uint256
        )
    {
        // longOptionTokens are closed by doing a swap from underlyingTokens to redeemTokens.
        address[] memory path = new address[](2);
        path[0] = optionToken.getUnderlyingTokenAddress();
        path[1] = optionToken.redeemToken();
        uint256 outputUnderlyings =
            getProportionalLongOptions(optionToken, quantity);
        // The loanRemainder will be the amount of underlyingTokens that are needed from the original
        // transaction caller in order to pay the flash swap.
        uint256 loanRemainder;

        // Economically, underlyingPayout value should always be greater than 0, or this trade shouldn't be made.
        // If an underlyingPayout is greater than 0, it means that the redeemTokens borrowed are worth less than the
        // underlyingTokens received from closing the redeemToken<>optionTokens.
        // If the redeemTokens are worth more than the underlyingTokens they are entitled to,
        // then closing the redeemTokens will cost additional underlyingTokens. In this case,
        // the transaction should be reverted. Or else, the user is paying extra at the expense of
        // rebalancing the pool.
        uint256 underlyingPayout;

        // Need to return tokens from the flash swap by returning underlyingTokens.

        // Since the borrowed amount is redeemTokens, and we are paying back in underlyingTokens,
        // we need to see how much underlyingTokens must be returned for the borrowed amount.
        // We can find that value by doing the normal swap math, getAmountsIn will give us the amount
        // of underlyingTokens are needed for the output amount of the flash loan.
        // IMPORTANT: amountsIn 0 is how many underlyingTokens we need to pay back.
        // This value is most likely greater than the amount of underlyingTokens received from closing.
        uint256[] memory amountsIn = router.getAmountsIn(quantity, path);

        uint256 underlyingsRequired = amountsIn[0]; // the amountIn required of underlyingTokens based on the amountOut of flashloanQuantity
        // If outputUnderlyings (received from closing) is greater than underlyings required,
        // there is a positive payout.
        underlyingPayout = outputUnderlyings > underlyingsRequired
            ? outputUnderlyings.sub(underlyingsRequired)
            : 0;

        // If there is a negative payout, calculate the remaining cost of underlyingTokens.
        uint256 underlyingCostRemaining =
            underlyingsRequired > outputUnderlyings
                ? underlyingsRequired.sub(outputUnderlyings)
                : 0;

        // In the case that there is a negative payout (additional underlyingTokens are required),
        // get the remaining cost into the `loanRemainder` variable and also check to see
        // if a user is willing to pay the negative cost. There is no rational economic incentive for this.
        if (underlyingCostRemaining > 0) {
            loanRemainder = underlyingCostRemaining;
        }

        return (underlyingPayout, loanRemainder);
    }

    /**
     * @dev    Calculates the proportional quantity of long option tokens per short option token.
     * @notice For each long option token, there is quoteValue / baseValue quantity of short option tokens.
     */
    function getProportionalLongOptions(
        IOption optionToken,
        uint256 quantityShort
    ) internal view returns (uint256) {
        uint256 quantityLong =
            quantityShort.mul(optionToken.getBaseValue()).div(
                optionToken.getQuoteValue()
            );

        return quantityLong;
    }

    /**
     * @dev    Calculates the proportional quantity of short option tokens per long option token.
     * @notice For each short option token, there is baseValue / quoteValue quantity of long option tokens.
     */
    function getProportionalShortOptions(
        IOption optionToken,
        uint256 quantityLong
    ) internal view returns (uint256) {
        uint256 quantityShort =
            quantityLong.mul(optionToken.getQuoteValue()).div(
                optionToken.getBaseValue()
            );

        return quantityShort;
    }

    function safeTransferThenMint(
        IOption optionToken,
        uint256 mintQuantity,
        address receiver
    ) internal returns (uint256, uint256) {
      IERC20(optionToken.getUnderlyingTokenAddress()).safeTransferFrom(
          msg.sender,
          address(optionToken),
          mintQuantity
      );
      emit Minted(
          msg.sender,
          address(optionToken),
          mintQuantity,
          PrimitiveRouterLib.getProportionalShortOptions(
              optionToken,
              mintQuantity
          )
      );
      return optionToken.mintOptions(receiver);
    }

    /**
     * @dev Deposits amount of ethers into WETH contract. Then sends WETH to "to".
     * @param to The address to send WETH ERC-20 tokens to.
     */
    function safeTransferETHFromWETH(
        IWETH weth,
        address to,
        uint256 amount
    ) internal {
        // Deposit the ethers received from amount into the WETH contract.
        weth.deposit.value(amount)();

        // Send WETH.
        weth.transfer(to, amount);
    }

    /**
     * @dev Unwraps WETH to withrdaw ethers, which are then sent to the "to" address.
     * @param to The address to send withdrawn ethers to.
     * @param amount The amount of WETH to unwrap.
     */
    function safeTransferWETHToETH(
        IWETH weth,
        address to,
        uint256 amount
    ) internal {
        // Withdraw ethers with weth.
        weth.withdraw(amount);
        // Send ether.
        (bool success, ) = to.call.value(amount)("");
        // Revert is call is unsuccessful.
        require(success, "PrimitiveV1: ERR_SENDING_ETHER");
    }
}
