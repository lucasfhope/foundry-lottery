// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Raffle} from "src/Raffle.sol";
import {DeployRaffle} from "script/DeployRaffle.s.sol";
import {HelperConfig, CodeConstants} from "script/HelperConfig.s.sol";
import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

contract RaffleTest is Test, CodeConstants {
    Raffle raffle;
    HelperConfig helperConfig;

    uint256 entranceFee;
    uint256 interval;
    address vrfCoordinator;
    bytes32 gasLane;
    uint256 subscriptionId;
    uint32 callbackGasLimit;
    address link;

    address public PLAYER = makeAddr("player");
    uint256 public constant STARTING_USER_BALANCE = 10 ether;

    function setUp() external {
        DeployRaffle deployer = new DeployRaffle();
        (raffle, helperConfig) = deployer.run();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();

        entranceFee = config.entranceFee;
        interval = config.interval;
        vrfCoordinator = config.vrfCoordinator;
        gasLane = config.gasLane;
        subscriptionId = config.subscriptionId;
        callbackGasLimit = config.callbackGasLimit;
        link = config.link;

        vm.deal(PLAYER, STARTING_USER_BALANCE);
    }

    modifier raffleEnteredAndTimePassed() {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           INITIALIZE RAFFLE
    //////////////////////////////////////////////////////////////*/

    function testRaffleInitializesInOpenState() public view {
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
    }

    function testRaffleInitializedWithNoPlayersNoETHAndNoRecentWinner() public view {
        assert(raffle.getNumPlayers() == 0);
        assert(raffle.getRaffleBalance() == 0);
        assert(raffle.getRecentWinner() == address(0));
    }

    function testRaffleInitializesWithCorrectEntranceFee() public view {
        assert(raffle.getEntranceFee() == entranceFee);
    }

    /*//////////////////////////////////////////////////////////////
                              ENTER RAFFLE
    //////////////////////////////////////////////////////////////*/

    function testRaffleRevertsWhenNotEnoughEthSent() public {
        vm.prank(PLAYER);
        vm.expectRevert(Raffle.Raffle__NotEnoughEthToEnter.selector);
        raffle.enterRaffle();
    }

    function testRaffleRecordsPlayersWhenTheyEnter() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        address playerRecorded = raffle.getPlayer(0);
        assert(playerRecorded == PLAYER);
    }

    function testEmitsEventOnRaffleEntrance() public {
        vm.prank(PLAYER);
        vm.expectEmit(true, false, false, false, address(raffle));
        emit Raffle.EnteredRaffle(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    function testCannotEnterWhenRaffleIsCalculating() public raffleEnteredAndTimePassed {
        raffle.performUpkeep("");
        vm.expectRevert(Raffle.Raffle__RaffleNotOpen.selector);
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    /*//////////////////////////////////////////////////////////////
                              CHECK UPKEEP
    //////////////////////////////////////////////////////////////*/

    function testCheckUpkeepReturnsFalseWhenRaffleHasNoBalance() public {
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        assert(!upkeepNeeded);
    }

    function testCheckUpkeepReturnsFalseWhenRaffleIsNotOpen() public raffleEnteredAndTimePassed {
        raffle.performUpkeep("");
        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        assert(!upkeepNeeded);
    }

    function testCheckUpkeepReturnsFalseIfEnoughTimeHasNotPassed() public raffleEnteredAndTimePassed {
        vm.warp(block.timestamp - 2);
        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        assert(!upkeepNeeded);
    }

    function testCheckUpkeepReturnsTrueWhenParametersAreGood() public raffleEnteredAndTimePassed {
        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        assert(upkeepNeeded);
    }

    /*//////////////////////////////////////////////////////////////
                              PERFORM UPKEEP
    //////////////////////////////////////////////////////////////*/

    function testPerformUpkeepCanOnlyRunIfCheckUpkeepIsTrue() public raffleEnteredAndTimePassed {
        raffle.performUpkeep("");
    }

    function testPerformUpkeepRevertsIfCheckUpkeepIsFalse() public {
        uint256 currentBalance = 0;
        uint256 numPlayers = 0;
        Raffle.RaffleState raffleState = Raffle.RaffleState.OPEN;
        vm.expectRevert(
            abi.encodeWithSelector(Raffle.Raffle__UpkeepNotNeeded.selector, currentBalance, numPlayers, raffleState)
        );
        raffle.performUpkeep("");
    }

    // What if I need to test the output of events?
    function testPerformUpkeepUpdatesRaffleStateandEmitsRequestId() public raffleEnteredAndTimePassed {
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1]; // requestId from local emit

        Raffle.RaffleState raffleState = raffle.getRaffleState();

        assert(uint256(requestId) > 0);
        assert(uint256(raffleState) == 1);
    }

    /*//////////////////////////////////////////////////////////////
                          FULFILL RANDOM WORDS
    //////////////////////////////////////////////////////////////*/

    // These tests mock ChainLink VRF Node calls so they only work on the local fork
    modifier skipWhenOnForkedNetwork() {
        if (block.chainid != LOCAL_ANVIL_CHAIN_ID) {
            return;
        }
        _;
    }

    function testFulfillRandomWordsCanOnlyBeCalledAfterPerformUpkeep(uint256 randomRequestId)
        public
        raffleEnteredAndTimePassed
        skipWhenOnForkedNetwork
    {
        vm.expectRevert(VRFCoordinatorV2_5Mock.InvalidRequest.selector);
        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(randomRequestId, address(raffle));
    }

    function testFulfillRandomWordsPicksAWinnerResetsAndSendsETH()
        public
        raffleEnteredAndTimePassed
        skipWhenOnForkedNetwork
    {
        uint256 additionalEntrants = 9;
        uint256 startingIndex = 1;
        for (uint256 i = startingIndex; i <= additionalEntrants; i++) {
            address player = address(uint160(i + 111)); // early contracts may be used already
            hoax(player, STARTING_USER_BALANCE);
            raffle.enterRaffle{value: entranceFee}();
        }

        uint256 totalPrize = entranceFee * (additionalEntrants + 1);

        vm.recordLogs();
        raffle.performUpkeep(""); // emit requestId
        Vm.Log[] memory entries = vm.getRecordedLogs(); // also resets the logs buffer
        bytes32 requestId = entries[1].topics[1];
        uint256 previousTimestamp = raffle.getLastTimestamp();

        // pretend to be chainlink vrf to get a random number and pick a winner
        // should call our override of fulfillRandomWords which emits an event
        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(uint256(requestId), address(raffle));

        assert(raffle.getRecentWinner() != address(0));

        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
        assert(raffle.getNumPlayers() == 0);
        assert(previousTimestamp + interval < raffle.getLastTimestamp());

        assert(raffle.getRecentWinner().balance == STARTING_USER_BALANCE - entranceFee + totalPrize);
        assert(raffle.getRaffleBalance() == 0);
    }
}
