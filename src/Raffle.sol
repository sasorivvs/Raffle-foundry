// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @title A sample Raffle contract
 * @author Sasorivvs
 * @notice This contract is for creating a sample raffle
 * @dev Implements Chainlink VRFv2.5
 */
contract Raffle is VRFConsumerBaseV2Plus {
    /**
     * Type Declaration
     */
    enum RaffleState {
        OPEN,
        CALCULATING
    }

    struct TicketRange {
        uint256 start;
        uint256 end;
        address payable owner;
    }

    /**
     * State Variables
     */
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint256 private immutable i_entranceFee;
    uint256 private immutable i_interval;
    bytes32 private immutable i_keyHash;
    uint256 private immutable i_subscriptionId;
    uint32 private immutable i_callbackGasLimit;
    uint256 private immutable i_ticketPrice;
    uint256 private s_lastTimestamp;
    uint256 private s_totalTickets;
    uint256 private s_totalPlayers;
    uint256 private s_accumulatedFees;
    address payable private s_lastWinner;
    RaffleState private s_raffleState;
    TicketRange[] private s_ticketRanges;

    /**
     * Errors
     */
    error Raffle_NotEnoughEthToEnterRaffle();
    error Raffle_RaffleNotOppened();
    error Raffle_RefundFailed();
    error Raffle_UpkeepNotNeeded(uint256 raffleBalance, uint256 playersNumber, uint256 raffleState);
    error Raffle_PrizeTransferFailed();
    error Raffle_FeesTransferFailed();
    //error Raffle_NotAnOwner(address owner, address sender);

    /**
     * Events
     */
    event Raffle_Enter(address indexed player, uint256 ticketsNumber);
    event WinnerPicked(address indexed lastWinner);
    event RequestedRaffleWinner(uint256 indexed requestId);

    constructor(
        uint256 entranceFee,
        uint256 interval,
        uint256 ticketPrice,
        address _vrfCoordinator,
        bytes32 keyHash,
        uint256 subscriptionId,
        uint32 callbackGasLimit
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        i_entranceFee = entranceFee;
        // @dev The duration of the lottery in seconds
        i_interval = interval;
        i_keyHash = keyHash;
        i_subscriptionId = subscriptionId;
        i_callbackGasLimit = callbackGasLimit;
        i_ticketPrice = ticketPrice;
        s_lastTimestamp = block.timestamp;
        s_raffleState = RaffleState.OPEN;
    }

    function enterRaffle() external payable {
        if (msg.value < i_ticketPrice + i_entranceFee) {
            revert Raffle_NotEnoughEthToEnterRaffle();
        }
        if (s_raffleState != RaffleState.OPEN) {
            revert Raffle_RaffleNotOppened();
        }
        uint256 amountWithoutFee = msg.value - i_entranceFee;
        uint256 numberOfTickets = amountWithoutFee / i_ticketPrice;
        uint256 refundAmount = amountWithoutFee % i_ticketPrice;
        s_ticketRanges.push(
            TicketRange({start: s_totalTickets, end: s_totalTickets + numberOfTickets - 1, owner: payable(msg.sender)})
        );
        s_totalTickets += numberOfTickets;
        s_totalPlayers += 1;
        emit Raffle_Enter(msg.sender, numberOfTickets);
        (bool s,) = payable(msg.sender).call{value: refundAmount}("");
        if (!s) {
            revert Raffle_RefundFailed();
        }
    }

    /**
     * @dev This is the function that the Chainlink nodes will call to see
     * If the Lottery is ready to have a winner picked.
     * The following should be true in order for upkeepNeeded to be true:
     * 1. The time interval has passed between raffle runs
     * 2. The lottery is open
     * 3. The contract has ETH
     * 4. Implicitly, your subscription has LINK
     * @param - ignored
     * @return upkeepNeeded - true if it's time to restart the lottery
     */
    function checkUpkeep(bytes memory /* checkData */ )
        public
        view
        returns (bool upkeepNeeded, bytes memory /* performData */ )
    {
        bool timeHasPassed = block.timestamp - s_lastTimestamp >= i_interval;
        bool isOpen = s_raffleState == RaffleState.OPEN;
        bool hasBalance = address(this).balance >= s_totalTickets * i_ticketPrice + s_totalPlayers * i_entranceFee;
        bool hasPlayers = s_totalPlayers > 0;
        upkeepNeeded = timeHasPassed && isOpen && hasBalance && hasPlayers;
        return (upkeepNeeded, "");
    }

    function performUpkeep(bytes calldata /* performData */ ) external {
        (bool upkeepNeeded,) = checkUpkeep("");
        if (!upkeepNeeded) {
            revert Raffle_UpkeepNotNeeded(address(this).balance, s_totalPlayers, uint256(s_raffleState));
        }
        if (block.timestamp - s_lastTimestamp < i_interval) {
            revert();
        }
        s_raffleState = RaffleState.CALCULATING;
        VRFV2PlusClient.RandomWordsRequest memory randomWordsRequest = VRFV2PlusClient.RandomWordsRequest({
            keyHash: i_keyHash,
            subId: i_subscriptionId,
            requestConfirmations: REQUEST_CONFIRMATIONS,
            callbackGasLimit: i_callbackGasLimit,
            numWords: 1,
            extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
        });
        uint256 requestId = s_vrfCoordinator.requestRandomWords(randomWordsRequest);
        emit RequestedRaffleWinner(requestId);
    }

    function fulfillRandomWords(uint256, /*requestId*/ uint256[] calldata randomWords) internal virtual override {
        uint256 winnerTicket = randomWords[0] % s_totalTickets;
        address payable winnerAddress;
        uint256 ticketRanges = s_ticketRanges.length;
        for (uint256 i = 0; i < ticketRanges; i++) {
            if (winnerTicket >= s_ticketRanges[i].start && winnerTicket <= s_ticketRanges[i].end) {
                winnerAddress = s_ticketRanges[i].owner;
            }
        }
        uint256 prizePool = s_totalTickets * i_ticketPrice;
        s_raffleState = RaffleState.OPEN;
        s_accumulatedFees += s_totalPlayers * i_entranceFee;

        //s_ticketRanges = new TicketRange[](0);
        delete s_ticketRanges;
        s_totalTickets = 0;
        s_totalPlayers = 0;
        s_lastTimestamp = block.timestamp;
        s_lastWinner = winnerAddress;
        emit WinnerPicked(winnerAddress);

        (bool s,) = winnerAddress.call{value: prizePool}("");
        if (!s) {
            revert Raffle_PrizeTransferFailed();
        }
    }

    function withdrawAccumulatedFees() external onlyOwner {
        uint256 accumulatedFees = s_accumulatedFees;
        s_accumulatedFees = 0;

        (bool s,) = payable(msg.sender).call{value: accumulatedFees}("");
        if (!s) {
            revert Raffle_FeesTransferFailed();
        }
    }

    /**
     * Getter Functions
     */
    function getEntranceFee() external view returns (uint256) {
        return i_entranceFee;
    }

    function getLastWinner() external view returns (address) {
        return s_lastWinner;
    }

    function getInterval() external view returns (uint256) {
        return i_interval;
    }

    function getTicketPrice() external view returns (uint256) {
        return i_ticketPrice;
    }

    function getRaffleState() external view returns (RaffleState) {
        return s_raffleState;
    }

    function getTicketRanges(uint256 indexOfPlayer) external view returns (TicketRange memory) {
        return s_ticketRanges[indexOfPlayer];
    }

    function getLastTimestamp() external view returns (uint256) {
        return s_lastTimestamp;
    }

    function getTotalTickets() external view returns (uint256) {
        return s_totalTickets;
    }

    function getTotalPlayers() external view returns (uint256) {
        return s_totalPlayers;
    }

    function getAccumulatedFees() external view returns (uint256) {
        return s_accumulatedFees;
    }

    function getOwner() external view returns (address) {
        return owner();
    }
}
