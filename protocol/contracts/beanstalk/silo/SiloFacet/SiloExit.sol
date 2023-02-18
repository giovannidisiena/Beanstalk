/*
/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "~/beanstalk/ReentrancyGuard.sol";
import "~/libraries/Silo/LibSilo.sol";
import "~/libraries/LibSafeMath32.sol";
import "~/libraries/LibSafeMath128.sol";
import "~/libraries/LibPRBMath.sol";
import "~/C.sol";
import "hardhat/console.sol";

/**
 * @title SiloExit, Brean
 * @author Publius
 * @notice Exposes public view functions for Silo total balances, account
 * balances, account update history, and Season of Plenty (SOP) balances.
 *
 * Provieds utility functions like {_season} for upstream usage throughout
 * SiloFacet.
 */
contract SiloExit is ReentrancyGuard {
    using SafeMath for uint256;
    using LibSafeMath32 for uint32;
    using LibSafeMath128 for uint128;
    using LibPRBMath for uint256;

    uint256 constant private EARNED_BEAN_VESTING_BLOCKS = 25; //  5 minutes

    /**
     * @dev Stores account-level Season of Plenty balances.
     * 
     * Returned by {balanceOfSop}.
     */
    struct AccountSeasonOfPlenty {
        // The Season that it started Raining, if it was Raining during the last
        // Season in which `account` updated their Silo. Otherwise, 0.
        uint32 lastRain; 
        // The last Season of Plenty starting Season processed for `account`.
        uint32 lastSop;
        // `account` balance of Roots when it started raining. 
        uint256 roots; 
        // The global Plenty per Root at the last Season in which `account`
        // updated their Silo.
        uint256 plentyPerRoot; 
        // `account` balance of unclaimed Bean:3Crv from Seasons of Plenty.
        uint256 plenty; 
    }

    //////////////////////// UTILTIES ////////////////////////

    /**
     * @notice Get the last Season in which `account` updated their Silo.
     */
    function lastUpdate(address account) public view returns (uint32) {
        return s.a[account].lastUpdate;
    }

    //////////////////////// SILO: TOTALS ////////////////////////

    /**
     * @notice Returns the total supply of Seeds. Does NOT include Earned Seeds.
     */
    function totalSeeds() public view returns (uint256) {
        return s.s.seeds;
    }

    /**
     * @notice Returns the total supply of Stalk. Does NOT include Grown Stalk.
     */
    function totalStalk() public view returns (uint256) {
        return s.s.stalk;
    }

    /**
     * @notice Returns the total supply of Roots.
     */
    function totalRoots() public view returns (uint256) {
        return s.s.roots;
    }

    /**
     * @notice Returns the total supply of Earned Beans.
     * @dev Beanstalk's "supply" of Earned Beans is a subset of the total Bean
     * supply. Earned Beans are simply seignorage Beans held by Beanstalk for 
     * distribution to Stalkholders during {SiloFacet-plant}.   
     */
    function totalEarnedBeans() public view returns (uint256) {
        return s.earnedBeans;
    }

    //////////////////////// SILO: ACCOUNT BALANCES ////////////////////////

    /**
     * @notice Returns the balance of Seeds for `account`.
     * Does NOT include Earned Seeds.
     * @dev Earned Seeds do not earn Grown Stalk due to computational
     * complexity, so they are not included.
     */
    function balanceOfSeeds(address account) public view returns (uint256) {
        return s.a[account].s.seeds;
    }

    /**
     * @notice Returns the balance of Stalk for `account`. 
     * Does NOT include Grown Stalk.
     * DOES include Earned Stalk.
     * @dev Earned Stalk earns Bean Mints, but Grown Stalk does not due to
     * computational complexity.
     */
    function balanceOfStalk(address account) public view returns (uint256) {
        return s.a[account].s.stalk.add(balanceOfEarnedStalk(account));
    }

    /**
     * @notice Returns the balance of Roots for `account`.
     * @dev Roots within Beanstalk are entirely separate from the 
     * [ROOT ERC-20 token](https://roottoken.org/).
     * 
     * Roots represent proportional ownership of Stalk:
     *  `balanceOfStalk / totalStalk = balanceOfRoots / totalRoots`
     * 
     * Roots are used to calculate Earned Bean, Earned Stalk and Plantable Seed
     * balances.
     *
     * FIXME(doc): how do Roots relate to Raining?
     */
    function balanceOfRoots(address account) public view returns (uint256) {
        return s.a[account].roots;
    }

    /**
     * @notice Returns the balance of Grown Stalk for `account`. Grown Stalk is 
     * earned each Season from Seeds and must be Mown via `SiloFacet-mow` to 
     * apply it to a user's balance.
     * @dev The balance of Grown Stalk for an account can be calculated as:
     *
     * ```
     * elapsedSeasons = currentSeason - lastUpdatedSeason
     * grownStalk = balanceOfSeeds * elapsedSeasons
     * ```
     */
    function balanceOfGrownStalk(address account)
        public
        view
        returns (uint256)
    {
        return
            LibSilo.stalkReward(
                s.a[account].s.seeds,
                _season() - lastUpdate(account)
            );
    }
    
    /**
     * @notice Returns the balance of Earned Beans for `account`. Earned Beans
     * are the Beans distributed to Stalkholders during {Sun-rewardToSilo}.
     */
    function balanceOfEarnedBeans(address account)
        public
        view
        returns (uint256 beans)
    {
        // currently this function does not include the vesting period, 
        // as we would have to calculate the amount of to issue:
        if(block.number - s.season.sunriseBlock <= 25){
            (uint256 deltaRoots, uint256 newEarnedRoots) = _calcRoots(account);
            console.log("deltaRoots:", deltaRoots);
            console.log("newEarnedRoots:", newEarnedRoots);
            beans = _balanceOfEarnedBeansVested(account, s.a[account].s.stalk, deltaRoots, newEarnedRoots);
        } else {
            beans = _balanceOfEarnedBeans(account, s.a[account].s.stalk, true);
        }
    }
    
    function _calcRoots(address account) internal view returns (uint256 delta_roots, uint256 newEarnedRoots) {
        uint256 _stalk = balanceOfGrownStalk(account);
        if(_stalk == 0) {
            console.log("stalk is 0");
            delta_roots = s.a[account].deltaRoots;
            newEarnedRoots = s.newEarnedRoots;
        } else {
            console.log("stalk is non 0");
            uint256 rootEarned = s.s.roots.mul(_stalk).div(s.s.stalk);
            uint256 rootUnEarned = s.s.roots.add(s.newEarnedRoots).mulDiv(_stalk, s.s.stalk - s.newEarnedStalk, LibPRBMath.Rounding.Up);
            console.log("rootEarned:", rootEarned);
            delta_roots = rootUnEarned;
            newEarnedRoots = uint256(s.newEarnedRoots).add(delta_roots);
        }
    }
           
        

    /**
     * @dev Internal function to compute `account` balance of Earned Beans.
     *
     * The number of Earned Beans is equal to the difference between: 
     *  - the "expected" Stalk balance, determined from the account balance of 
     *    Roots. 
     *  - the "account" Stalk balance, stored in account storage.
     * divided by the number of Stalk per Bean.
     * The earned beans from the latest season 
     */
    function _balanceOfEarnedBeans(address account, uint256 accountStalk, bool hasVested) 
        internal
        view
        returns (uint256 beans) {
        // There will be no Roots before the first Deposit is made.
        if (s.s.roots == 0) return 0;

        // Calculate the % season remaining in the season, where 100% is 1e18.
        uint256 stalk;
        if(hasVested == false){
            console.log("balanceOfEarnedBeans, < 25 blocks");
            uint128 addedRoots = s.a[account].deltaRoots;
            console.log("accountStalk:", accountStalk);
            console.log("addedRoots: %s", addedRoots);
            console.log("stalk with new stalk stuff:", s.s.stalk.sub(s.newEarnedStalk));
            console.log("newStalkStuff:", s.newStalkStuff);
            console.log("newEarnedStalk:", s.newEarnedStalk);
            console.log("user roots w/added :", s.a[account].roots.add(addedRoots));
            console.log("total roots w/total:", s.s.roots.add(addedRoots));
            console.log("user roots w/out added :", s.a[account].roots);
            console.log("total roots w/out total:", s.s.roots);
            console.log("newEarnedRoots:", s.newEarnedRoots);
            stalk = s.s.stalk.sub(s.newEarnedStalk).mulDiv(
                s.a[account].roots.add(addedRoots),
                s.s.roots.add(s.newEarnedRoots),
                LibPRBMath.Rounding.Up
            );
            console.log("stalk:", stalk);
            console.log("stalk without change:", s.s.stalk.mulDiv(s.a[account].roots, s.s.roots, LibPRBMath.Rounding.Up));
        } else {
            console.log("balanceOfEarnedBeans, greater than 25 blocks");
            stalk = s.s.stalk.mulDiv(
                s.a[account].roots,
                s.s.roots,
                LibPRBMath.Rounding.Up
            );
        }
        
        // Beanstalk rounds down when minting Roots. Thus, it is possible that
        // balanceOfRoots / totalRoots * totalStalk < s.a[account].s.stalk.
        // As `account` Earned Balance balance should never be negative, 
        // Beanstalk returns 0 instead.
        if (stalk <= accountStalk) return 0;

        // Calculate Earned Stalk and convert to Earned Beans.
        beans = (stalk - accountStalk).div(C.getStalkPerBean()); // Note: SafeMath is redundant here.
        if (beans > s.earnedBeans) return s.earnedBeans;

        return beans;
    }

    function _balanceOfEarnedBeansVested(address account, uint256 accountStalk, uint256 deltaRoots, uint256 newEarnedRoots) 
        internal
        view
        returns (uint256 beans) {
         if (s.s.roots == 0) return 0;

        // Calculate the % season remaining in the season, where 100% is 1e18.
        uint256 stalk;
        uint256 grownStalk = balanceOfGrownStalk(account);
        stalk = s.s.stalk.add(grownStalk).sub(s.newEarnedStalk).mulDiv(
            s.a[account].roots.add(uint128(deltaRoots)),
            s.s.roots.add(uint128(newEarnedRoots)),
            LibPRBMath.Rounding.Up
        );        
        // Beanstalk rounds down when minting Roots. Thus, it is possible that
        // balanceOfRoots / totalRoots * totalStalk < s.a[account].s.stalk.
        // As `account` Earned Balance balance should never be negative, 
        // Beanstalk returns 0 instead.
        if (stalk <= accountStalk) return 0;

        // Calculate Earned Stalk and convert to Earned Beans.
        beans = (stalk - accountStalk.add(grownStalk)).div(C.getStalkPerBean()); // Note: SafeMath is redundant here.
        if (beans > s.earnedBeans) return s.earnedBeans;

        return beans;

    }

    /**
     * @notice Return the `account` balance of Earned Stalk, the Stalk
     * associated with Earned Beans.
     * @dev Earned Stalk can be derived from Earned Beans because 
     * 1 Bean => 1 Stalk. See {C-getStalkPerBean}.
     */
    function balanceOfEarnedStalk(address account)
        public
        view
        returns (uint256)
    {
        return balanceOfEarnedBeans(account).mul(C.getStalkPerBean());
    }

    /**
     * @notice Returns the `account` balance of Earned Seeds, the Seeds
     * associated with Earned Beans.
     * @dev Earned Seeds can be derived from Earned Beans, because
     * 1 Bean => 2 Seeds. See {C-getSeedsPerBean}.
     */
    function balanceOfEarnedSeeds(address account)
        public
        view
        returns (uint256)
    {
        return balanceOfEarnedBeans(account).mul(C.getSeedsPerBean());
    }

    //////////////////////// SEASON OF PLENTY ////////////////////////

    /**
     * @notice Returns the last Season that it started Raining resulting in a 
     * Season of Plenty.
     */
    function lastSeasonOfPlenty() public view returns (uint32) {
        return s.season.lastSop;
    }

    /**
     * @notice Returns the `account` balance of unclaimed BEAN:3CRV earned from 
     * Seasons of Plenty.
     */
    function balanceOfPlenty(address account)
        public
        view
        returns (uint256 plenty)
    {
        Account.State storage a = s.a[account];
        plenty = a.sop.plenty;
        uint256 previousPPR;

        // If lastRain > 0, then check if SOP occured during the rain period.
        if (s.a[account].lastRain > 0) {
            // if the last processed SOP = the lastRain processed season,
            // then we use the stored roots to get the delta.
            if (a.lastSop == a.lastRain) previousPPR = a.sop.plentyPerRoot;
            else previousPPR = s.sops[a.lastSop];
            uint256 lastRainPPR = s.sops[s.a[account].lastRain];

            // If there has been a SOP duing the rain sesssion since last update, process SOP.
            if (lastRainPPR > previousPPR) {
                uint256 plentyPerRoot = lastRainPPR - previousPPR;
                previousPPR = lastRainPPR;
                plenty = plenty.add(
                    plentyPerRoot.mul(s.a[account].sop.roots).div(
                        C.getSopPrecision()
                    )
                );
            }
        } else {
            // If it was not raining, just use the PPR at previous SOP.
            previousPPR = s.sops[s.a[account].lastSop];
        }

        // Handle and SOPs that started + ended before after last Silo update.
        if (s.season.lastSop > lastUpdate(account)) {
            uint256 plentyPerRoot = s.sops[s.season.lastSop].sub(previousPPR);
            plenty = plenty.add(
                plentyPerRoot.mul(balanceOfRoots(account)).div(
                    C.getSopPrecision()
                )
            );
        }
    }

    /**
     * @notice Returns the `account` balance of Roots the last time it was 
     * Raining during a Silo update.
     */
    function balanceOfRainRoots(address account) public view returns (uint256) {
        return s.a[account].sop.roots;
    }

    /**
     * @notice Returns the `account` Season of Plenty related state variables.
     * @dev See {AccountSeasonOfPlenty} struct.
     */
    function balanceOfSop(address account)
        external
        view
        returns (AccountSeasonOfPlenty memory sop)
    {
        sop.lastRain = s.a[account].lastRain;
        sop.lastSop = s.a[account].lastSop;
        sop.roots = s.a[account].sop.roots;
        sop.plenty = balanceOfPlenty(account);
        sop.plentyPerRoot = s.a[account].sop.plentyPerRoot;
    }

    //////////////////////// INTERNAL ////////////////////////

    /**
     * @dev Returns the current Season number.
     */
    function _season() internal view returns (uint32) {
        return s.season.current;
    }

    function currentStalk() public view returns (uint256) {
        return s.s.stalk - LibSilo.getVestingEarnedStalk();
    }
    function _getVestingEarnedStalk() external view returns (uint256){
        return LibSilo.getVestingEarnedStalk();
    }
}
