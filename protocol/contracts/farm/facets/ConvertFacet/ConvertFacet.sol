/**
 * SPDX-License-Identifier: MIT
**/

pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import "./ConvertWithdraw.sol";
import "../../../libraries/Convert/LibConvert.sol";

/**
 * @author Publius
 * @title Silo handles depositing and withdrawing Beans and LP, and updating the Silo.
**/
contract ConvertFacet is ConvertWithdraw {

    using SafeMath for uint256;
    using LibSafeMath32 for uint32;

    function convert(
        bytes calldata userData,
        uint32[] memory crates,
        uint256[] memory amounts
    )
        external nonReentrant
    {
        LibInternal.updateSilo(msg.sender);

        (
            address toToken,
            address fromToken,
            uint256 toTokenAmount,
            uint256 fromTokenAmount,
            uint256 bdv
        ) = LibConvert.convert(userData);

        (uint256 grownStalk) = _withdrawForConvert(fromToken, crates, amounts, fromTokenAmount);

        _depositTokens(toToken, toTokenAmount, bdv, grownStalk);

        LibSilo.updateBalanceOfRainStalk(msg.sender);
    }
    
    function lpToPeg(address pair) external view returns (uint256 lp) {
        if (pair == C.curveMetapoolAddress()) return LibCurveConvert.lpToPeg(pair);
        require(false, "Convert: Pool not supported");
    }

    function beansToPeg(address pair) external view returns (uint256 beans) {
        if (pair == C.curveMetapoolAddress()) return LibCurveConvert.beansToPeg(pair);
        require(false, "Convert: Pool not supported");
    }
}
