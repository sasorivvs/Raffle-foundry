// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/Script.sol";
import {DeployRaffle} from "../../script/DeployRaffle.s.sol";
import {Raffle} from "../../src/Raffle.sol";
import {HelperConfig, CodeConstants} from "../../script/HelperConfig.s.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {Vm} from "forge-std/Vm.sol";

contract RaffleTest is Test, CodeConstants {
    event Raffle_Enter(address indexed player, uint256 ticketsNumber);

    modifier enterRaffle() {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee + ticketPrice}();

        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        _;
    }

    Raffle public raffle;
    HelperConfig public helperConfig;

    address public PLAYER = makeAddr("player");
    uint256 public constant STARTING_PLAYER_BALANCE = 10 ether;

    uint256 entranceFee;
    uint256 interval;
    uint256 ticketPrice;
    address vrfCoordinator;
    bytes32 gasLane;
    uint32 callbackGasLimit;
    uint256 subscriptionId;
    address owner;

    function setUp() external {
        DeployRaffle deployer = new DeployRaffle();
        (raffle, helperConfig) = deployer.deployContract();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        entranceFee = config.entranceFee;
        interval = config.interval;
        ticketPrice = config.ticketPrice;
        vrfCoordinator = config.vrfCoordinator;
        gasLane = config.gasLane;
        callbackGasLimit = config.callbackGasLimit;
        subscriptionId = config.subscriptionId;
        owner = config.account;
        vm.deal(PLAYER, STARTING_PLAYER_BALANCE);
    }

    function testRaffleInitializedInOpenState() public view {
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
    }

    function testRaffleRevertWhenSendNotEnoughEth() public {
        vm.prank(PLAYER);

        vm.expectRevert(Raffle.Raffle_NotEnoughEthToEnterRaffle.selector);

        /**
         * @dev entranceFee < 0.05 ether < ticketPrice < ticketPrice+entranceFee
         */
        raffle.enterRaffle{value: 0.05 ether}();
    }

    function testRaffleRecordsPlayersAndAmountsOfTickets() public {
        uint256 NUM_OF_TICKETS_TO_BUY = 7;
        vm.prank(PLAYER);
        raffle.enterRaffle{value: NUM_OF_TICKETS_TO_BUY * ticketPrice + entranceFee}();

        assertEq(raffle.getTicketRanges(0).owner, PLAYER);
        assertEq(raffle.getTicketRanges(0).start, 0);
        assertEq(raffle.getTicketRanges(0).end, NUM_OF_TICKETS_TO_BUY - 1);
    }

    function testRaffleReturnsTheExcessAmountETH() public {
        uint256 NUM_OF_TICKETS_TO_BUY = 7;
        uint256 AMOUNT_TO_RETURN = 0.09 ether;
        uint256 SENDING_AMOUNT = NUM_OF_TICKETS_TO_BUY * ticketPrice + entranceFee + AMOUNT_TO_RETURN;
        vm.prank(PLAYER);
        raffle.enterRaffle{value: SENDING_AMOUNT}();
        uint256 endingPlayerBalance = PLAYER.balance;
        assert(STARTING_PLAYER_BALANCE - endingPlayerBalance == SENDING_AMOUNT - AMOUNT_TO_RETURN);
    }

    function testRaffleEmitsEnterEvent() public {
        uint256 NUM_OF_TICKETS_TO_BUY = 7;
        uint256 SENDING_AMOUNT = NUM_OF_TICKETS_TO_BUY * ticketPrice + entranceFee;
        vm.prank(PLAYER);
        vm.expectEmit(true, false, false, true, address(raffle));
        emit Raffle_Enter(PLAYER, NUM_OF_TICKETS_TO_BUY);
        raffle.enterRaffle{value: SENDING_AMOUNT}();
    }

    function testDontAllowPlayersToEnterWhileRaffleIsCalculating() public enterRaffle {
        raffle.performUpkeep("");

        vm.expectRevert(Raffle.Raffle_RaffleNotOppened.selector);
        raffle.enterRaffle{value: entranceFee + ticketPrice}();
        vm.stopPrank();
    }

    function testCheckUpkeepReturnsFalseIfItHasNoBalance() public {
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        assert(!upkeepNeeded);
    }

    function testCheckUpkeepReturnsFalseIfRaffleIsntOpen() public enterRaffle {
        raffle.performUpkeep("");

        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        assert(!upkeepNeeded);
    }

    function testPerformUpkeepRevertsIfCheckUpkeepIsFalse() public {
        vm.startPrank(PLAYER);
        raffle.enterRaffle{value: entranceFee + ticketPrice}();

        uint256 currentBalance = entranceFee + ticketPrice;
        uint256 totalPlayers = 1;
        Raffle.RaffleState rState = raffle.getRaffleState();

        vm.expectRevert(
            abi.encodeWithSelector(Raffle.Raffle_UpkeepNotNeeded.selector, currentBalance, totalPlayers, rState)
        );
        raffle.performUpkeep("");
        vm.stopPrank();
    }

    function testPerformUpkeepUpdatesRaffleStateAndEmitsRequestId() public enterRaffle {
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        Raffle.RaffleState rState = raffle.getRaffleState();
        assert(uint256(requestId) > 0);
        assert(uint256(rState) == 1);
    }

    modifier skipFork() {
        if (block.chainid != LOCAL_CHAIN_ID) {
            return;
        }
        _;
    }

    function testFulfillRandomWordsCanOnlyBeCalledAfterPerformUpkeep(uint256 randomRequestId)
        public
        enterRaffle
        skipFork
    {
        vm.expectRevert(VRFCoordinatorV2_5Mock.InvalidRequest.selector);
        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(randomRequestId, address(raffle));
    }

    function testFulfillRandomWordsPicksAWinnerAndSendsMoney() public enterRaffle skipFork {
        uint256 additionalEntrants = 3; // 4 total
        uint256 startingIndex = 1;
        uint256 numOfAdditionalTikets = 5; // 16 total
        address expectedWinner = address(uint160(3)); // requestedWord % totalTickets = 13, ticket N13 belongs expectedWinner [0,..,15]

        for (uint256 i = startingIndex; i < startingIndex + additionalEntrants; i++) {
            address newPlayer = address(uint160(i));
            hoax(newPlayer, 10 ether);
            raffle.enterRaffle{value: numOfAdditionalTikets * ticketPrice + entranceFee}();
        }
        uint256 startingTimestamp = raffle.getLastTimestamp();
        uint256 startingBalance = expectedWinner.balance;
        uint256 totalTickets = raffle.getTotalTickets();

        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(uint256(requestId), address(raffle));

        address recentWinner = raffle.getLastWinner();
        Raffle.RaffleState raffleState = raffle.getRaffleState();
        uint256 winnerBalance = recentWinner.balance;
        uint256 endingTimestamp = raffle.getLastTimestamp();
        uint256 prize = totalTickets * raffle.getTicketPrice();
        uint256 finalTotalTickets = raffle.getTotalTickets();

        assert(expectedWinner == recentWinner);
        assert(winnerBalance == startingBalance + prize);
        assert(endingTimestamp > startingTimestamp);
        assert(uint256(raffleState) == 0);
        assert(finalTotalTickets == 0);
    }

    function testFeesAccumulatesOnlyAfterRaffleIsCompleted() public skipFork {
        uint256 startingFees = raffle.getAccumulatedFees();

        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee + ticketPrice}();

        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        uint256 intermediateFees = raffle.getAccumulatedFees();

        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];
        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(uint256(requestId), address(raffle));

        uint256 endingFees = raffle.getAccumulatedFees();

        assert(startingFees == 0);
        assert(intermediateFees == 0);
        assert(endingFees == entranceFee);
    }

    function testFeesAccumulatesOnlyAfterSeveralRafflesAreCompleted() public enterRaffle skipFork {
        uint256 firstRoundPlayersCount = raffle.getTotalPlayers();
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];
        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(uint256(requestId), address(raffle));

        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee + ticketPrice}();

        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        uint256 secondRoundPlayersCount = raffle.getTotalPlayers();
        vm.recordLogs();
        raffle.performUpkeep("");
        entries = vm.getRecordedLogs();
        requestId = entries[1].topics[1];
        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(uint256(requestId), address(raffle));

        uint256 endingFees = raffle.getAccumulatedFees();
        assert(endingFees == (firstRoundPlayersCount + secondRoundPlayersCount) * entranceFee);
    }

    function testWithdrawAccumulatedFeesRevertsIfNotAnOwnerTriesToWithdraw() public enterRaffle skipFork {
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];
        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(uint256(requestId), address(raffle));

        address notAnOwner = address(uint160(2));
        vm.expectRevert();
        vm.prank(notAnOwner);
        raffle.withdrawAccumulatedFees();
    }

    function testWithdrawAccumulatedFeesSuccessfulWithdrawsWhenOwnerTriesToWithdraw() public enterRaffle skipFork {
        uint256 startingOwnerBalance = owner.balance;
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];
        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(uint256(requestId), address(raffle));

        vm.prank(owner);
        raffle.withdrawAccumulatedFees();

        uint256 endingOwnerBalance = owner.balance;
        uint256 endingFees = raffle.getAccumulatedFees();
        assert(endingOwnerBalance == entranceFee + startingOwnerBalance);
        assert(endingFees == 0);
    }
}
