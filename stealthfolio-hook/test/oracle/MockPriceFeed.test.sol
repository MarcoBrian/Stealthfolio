// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {MockV3Aggregator} from "@chainlink/local/src/data-feeds/MockV3Aggregator.sol";

contract PriceFeedTest is Test {
    MockV3Aggregator wBTCFeed;
    MockV3Aggregator wETHFeed;
    MockV3Aggregator USDCFeed;



    function setUp() public {
        wBTCFeed = new MockV3Aggregator(8, 100000e8);
        wETHFeed = new MockV3Aggregator(8, 3000e8); 
        USDCFeed = new MockV3Aggregator(8, 1e8); 

    }

    function testUpdatePrice() public {
        wBTCFeed.updateAnswer(90100e8);

        (, int256 wBTCprice,,,) = wBTCFeed.latestRoundData();
        assertEq(wBTCprice, 90100e8);
        (, int256 wETHprice,,,) = wETHFeed.latestRoundData(); 
        assertEq(wETHprice , 3000e8); 
        (, int256 USDCPrice,,,) = USDCFeed.latestRoundData(); 
        assertEq(USDCPrice , 1e8); 

    }
}
