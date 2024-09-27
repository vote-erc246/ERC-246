// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./IERC246.sol";

/**
 * @title ERC246
 * @dev ERC20 token with governance capabilities. Token holders can create and vote on proposals.
 * Proposals can execute multiple functions via encoded function calls, such as minting tokens, changing the name, airdrops, etc.
 */
abstract contract ERC246 is ERC20, IERC246, ReentrancyGuard {
    using Address for address;
    using Counters for Counters.Counter;

    /// @notice A struct representing a proposal.
    struct Proposal {
        address proposer;
        string title;
        address[] targets; // Target contract addresses to call
        bytes[] data; // Encoded function call data for each target
        uint256[] values;    // ETH values to send with each call
        uint256 deadlineBlock; // Proposal voting deadline in block numbers
        uint256 enqueueBlock; // Proposal voting deadline in block numbers
        bool executed; // Whether the proposal has been executed
        bool accepted; // Whether the proposal has been accepted
        bool enqueued; // Whether the proposal has been enqueued for execution
        bool terminatedWithRejection; // Whether the proposal has been definitively rejected
        address[] voters; // List of voters
        mapping(address => bool) hasVoted; // Track voters to prevent double voting
        mapping(address => bool) voteSupport; // Track whether voter voted for (true) or against (false)
    }

    /// @notice Mapping from proposal ID to Proposal struct.
    mapping(uint256 => Proposal) public proposals;

    /// @notice Counter to keep track of proposal IDs.
    Counters.Counter public proposalIdCounter;

    /// @notice Minimum voting duration in blocks (initially set to 1 day, e.g., 5760 blocks)
    uint256 public minimumVotingDurationBlocks = 5760;

    /// @notice Minimum allowed voting duration in blocks.
    uint256 public constant MINIMUM_ALLOWED_PROPOSAL_DURATION_BLOCKS = 750; // Approximately 2.5 hours on Ethereum

    /// @notice Delay between proposal enqueueing and execution in blocks.
    uint256 public executionDelayInBlocks = 1200; //(~4 hours at 12s per block)

    /// @notice Minimum allowed proposal execution delay in blocks.
    uint256 public constant MINIMUM_ALLOWED_EXECUTION_DELAY_BLOCKS = 750; // Approximately 2.5 hours on Ethereum

    /// @notice The quorum needed for a proposal to be accepted expressed as a percentage of the supply in basis points
    uint256 public quorumSupplyPercentageBps = 400;

    /// @notice Minimum allowed quorum supply percentage basis points
    uint256 public constant MINIMUM_ALLOWED_QUORUM_SUPPLY_PERCENTAGE_BPS = 100;

    /// @notice Transfer fee in basis points (100 bps = 1%)
    uint256 public transferFeeBps = 0;
    
    /// @notice Max cap of 5% transfer fee
    uint256 public constant MAX_TRANSFER_FEE_BPS = 500; // Max 5% fee

    /// @notice Maximum percentage of the supply that can be minted via proposal expressed in basis points.
    uint256 public constant MAXIMUM_MINT_SUPPLY_PERCENTAGE_BPS = 500;

    /// @notice Mapping to track the block in which each user last received tokens.
    mapping(address => uint256) public lastTokenAcquisitionBlock;

    // Mapping to track the last block in which a function was executed
    mapping(bytes4 => uint256) public lastExecutionBlock;

    /// @notice Mapping to store minting airdrop allocations for each recipient.
    mapping(address => uint256) public mintAirdropAllocations;

    /// @notice Mapping to store treasury airdrop allocations for each recipient.
    mapping(address => uint256) public airdropAllocationsFromTreasury;

    /// @notice Total amount of tokens locked in the treasury for airdrop claims.
    uint256 public lockedTreasuryTokens;

    /// @notice The name of the token
    string private _name;

    /// @notice The symbol of the token
    string private _symbol;

    /**
     * @notice Modifier to restrict function access to only the governance contract (i.e., only callable via a proposal).
     */
    modifier onlyGovernanceProposal() {
        require(msg.sender == address(this), "ERC246: Only callable via governance proposal");
        _;
    }

    /**
     * @notice Modifier to ensure the function is only executed once per block (so, also once per proposal).
     * @dev Uses `msg.sig` to identify the function by its signature, regardless of parameters.
     */
    modifier onlyOncePerBlock() {
        require(lastExecutionBlock[msg.sig] != block.number, "ERC246: Function already executed in this block");
        lastExecutionBlock[msg.sig] = block.number;
        _;
    }

    /**
     * @notice Constructor to initialize the governance token.
     * @param name_ The name of the ERC20 token.
     * @param symbol_ The symbol of the ERC20 token.
     */
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        _name = name_;
        _symbol = symbol_;
    }


    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ Core governance functions ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    

    /**
     * @notice Create a new proposal with multiple function calls.
     * @param _targets The target contract addresses for the proposal.
     * @param _data The encoded function calls (signature + parameters) to be executed if the proposal passes.
     * @param _votingDurationInBlocks The duration (in blocks) for which the proposal will be open for voting.
     */
    function createProposal(
        string calldata _title,
        address[] memory _targets,
        bytes[] memory _data,
        uint256[] memory _values,
        uint256 _votingDurationInBlocks
    ) external override {
        require(balanceOf(msg.sender) > 0, "ERC246: Only token holders can create proposals");
        require(_targets.length == _data.length && _data.length == _values.length, "ERC246: Targets, data and values length mismatch");
        require(_votingDurationInBlocks >= minimumVotingDurationBlocks, "ERC246: Voting duration too short");
        require(bytes(_title).length <= 50, "ERC246: Title cannot be longer than 50 characters");

        uint256 proposalId = proposalIdCounter.current();

        Proposal storage newProposal = proposals[proposalId];
        newProposal.proposer = msg.sender;
        newProposal.title = _title;
        newProposal.deadlineBlock = block.number + _votingDurationInBlocks;
        newProposal.targets = _targets;
        newProposal.data = _data;
        newProposal.values = _values;

        proposalIdCounter.increment();

        emit ProposalCreated(proposalId, _targets, _data, _values, newProposal.deadlineBlock);
    }

    /**
     * @notice Vote on an active proposal.
     * @param _proposalId The ID of the proposal to vote on.
     * @param _support A boolean indicating whether the vote is in favor (true) or against (false).
     */
    function vote(uint256 _proposalId, bool _support) override external nonReentrant {
        Proposal storage proposal = _getProposal(_proposalId);
        require(block.number < proposal.deadlineBlock, "ERC246: Voting period has ended");
        require(!proposal.hasVoted[msg.sender], "ERC246: You have already voted on this proposal");

        // Register the voter's address
        proposal.voters.push(msg.sender);
        proposal.hasVoted[msg.sender] = true;
        proposal.voteSupport[msg.sender] = _support;

        emit VoteCast(msg.sender, _proposalId, _support);
    }

    /**
     * @notice Enqueue a proposal for execution after voting ends.
     * @dev After voting ends, anyone can call this to signal that the proposal should be executed after the time-lock.
     */
    function enqueueProposal(uint256 _proposalId) override external {
        Proposal storage proposal = _getProposal(_proposalId);
        require(block.number >= proposal.deadlineBlock, "ERC246: Voting period not yet ended");
        require(!proposal.enqueued, "ERC246: Proposal already enqueued");
        require(!proposal.executed, "ERC246: Proposal already executed");
        require(!proposal.terminatedWithRejection, "ERC246: Proposal has been rejected");

        uint256 quorumThreshold = (totalSupply() * quorumSupplyPercentageBps) / 10000;

        (uint256 votesFor, uint256 votesAgainst) = getProposalCurrentOutcome(_proposalId);

        proposal.accepted = (votesFor + votesAgainst >= quorumThreshold) && (votesFor > votesAgainst);

        if (proposal.accepted) {
            proposal.enqueued = true;
            proposal.enqueueBlock = block.number;
            emit ProposalEnqueued(_proposalId, proposal.accepted);
        }
        else {
            proposal.terminatedWithRejection = true;
            emit ProposalRejected(_proposalId);
        }
    }


    /**
     * @notice Execute a proposal after the time-lock has passed.
     * @dev This uses the outcome snapshot stored during the `enqueueProposal` call.
     */
    function executeProposal(uint256 _proposalId) external override nonReentrant {
        Proposal storage proposal = _getProposal(_proposalId);
        require(proposal.accepted, "ERC246: Cannot execute rejected proposal");
        require(proposal.enqueued, "ERC246: Proposal must be enqueued first");
        require(!proposal.executed, "ERC246: Proposal already executed");
        require(!proposal.terminatedWithRejection, "ERC246: Proposal has been rejected");

        uint256 executionBlock = proposal.enqueueBlock + executionDelayInBlocks;
        require(block.number >= executionBlock, "ERC246: Time-lock has not passed");

        proposal.executed = true;


        for (uint256 i = 0; i < proposal.targets.length;) {
            (bool success, bytes memory returnData) = proposal.targets[i].call{value: proposal.values[i]}(proposal.data[i]);
            
            if (!success) {
                // If the call fails, try to decode the revert reason
                if (returnData.length > 0) {
                    // The call reverted with a message, decode and revert with it
                    assembly {
                        let returndata_size := mload(returnData)
                        revert(add(32, returnData), returndata_size)
                    }
                } else {
                    // No revert reason, fallback to generic error
                    revert("ERC246: Execution failed for one of the targets");
                }
            }
            unchecked { ++i; }
        }

        emit ProposalExecuted(_proposalId, true);
    }

    /**
     * @notice Allows the proposer or governance to delete a proposal.
     * @param _proposalId The ID of the proposal to delete.
     */
    function deleteProposal(uint256 _proposalId) override external {
        Proposal storage proposal = _getProposal(_proposalId);

        // Ensure only proposer or governance can delete the proposal
        require(msg.sender == proposal.proposer || msg.sender == address(this), "ERC246: Only proposer or governance can delete");

        require(!proposal.enqueued, "ERC246: Cannot delete an enqueued proposal");
        require(!proposal.executed, "ERC246: Cannot delete an executed proposal");

        // Delete the proposal from storage
        delete proposals[_proposalId];

        emit ProposalDeleted(_proposalId);
    }


    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ Functions callable only via accepted proposal ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++


    /**
     * @notice Update the token name (only callable via a governance proposal).
     * @param newName The new name of the token.
     */
    function updateName(string calldata newName) external onlyGovernanceProposal {
        _name = newName;
    }

    /**
     * @notice Update the token symbol (only callable via a governance proposal).
     * @param newSymbol The new symbol of the token.
     */
    function updateSymbol(string calldata newSymbol) external onlyGovernanceProposal {
        _symbol = newSymbol;
    }

    /**
     * @notice Update the minimum voting duration in blocks.
     * @dev This function can only be called via a governance proposal (using the `onlyGovernanceProposal` modifier).
     * @param _newMinimumDuration The new minimum voting duration in blocks.
     */
    function updateMinimumVotingDurationBlocks(uint256 _newMinimumDuration) external onlyGovernanceProposal {
        require(_newMinimumDuration >= MINIMUM_ALLOWED_PROPOSAL_DURATION_BLOCKS, "ERC246: Minimum voting duration must be greater than MINIMUM_ALLOWED_PROPOSAL_DURATION_BLOCKS");
        minimumVotingDurationBlocks = _newMinimumDuration;
    }

    /**
     * @notice Update the proposal execution delay in blocks.
     * @dev This function can only be called via a governance proposal (using the `onlyGovernanceProposal` modifier).
     * @param _newDelay The new proposal execution delay in blocks.
     */
    function updateProposalExecutionDelayBlocks(uint256 _newDelay) external onlyGovernanceProposal {
        require(_newDelay >= MINIMUM_ALLOWED_EXECUTION_DELAY_BLOCKS, "ERC246: Proposal execution delay must be greater than MINIMUM_ALLOWED_EXECUTION_DELAY_BLOCKS");
        executionDelayInBlocks = _newDelay;
    }

    /**
     * @notice Update the quorum supply percentage.
     * @dev This function can only be called via a governance proposal (using the `onlyGovernanceProposal` modifier).
     * @param _newQuorumSupplyPercentage The new proposal execution delay in blocks.
     */
    function updateQuorumSupplyPercentage(uint256 _newQuorumSupplyPercentage) external onlyGovernanceProposal {
        require(_newQuorumSupplyPercentage >= MINIMUM_ALLOWED_QUORUM_SUPPLY_PERCENTAGE_BPS, "ERC246: Quorum supply percentage must be greater than MINIMUM_ALLOWED_QUORUM_SUPPLY_PERCENTAGE_BPS");
        quorumSupplyPercentageBps = _newQuorumSupplyPercentage;
    }

    /**
     * @notice Update the transfer fee percentage (in basis points) via governance proposal.
     * @param newTransferFeeBps The new transfer fee (in basis points).
     */
    function updateTransferFeeBps(uint256 newTransferFeeBps) external onlyGovernanceProposal {
        require(newTransferFeeBps <= MAX_TRANSFER_FEE_BPS, "ERC246: Transfer fee exceeds max limit");
        transferFeeBps = newTransferFeeBps;
    }

    /**
     * @notice Transfer tokens from the contract's balance to a given recipient (only callable via a governance proposal).
     * @dev This function transfers tokens from the contract balance to the specified recipient. 
     *      It can only be called via an approved governance proposal.
     * @param _recipient The address to receive the transferred tokens.
     * @param _amount The amount of tokens to transfer from the contract's balance.
     */
    function transferFromTreasury(address _recipient, uint256 _amount) external onlyGovernanceProposal {
        require(_recipient != address(0), "ERC246: Cannot transfer to the zero address");
        require(balanceOf(address(this)) >= _amount, "ERC246: Insufficient contract balance");

        _transfer(address(this), _recipient, _amount);
    }

    /**
     * @notice Mint new tokens (only callable via a governance proposal).
     * @dev This function mints tokens and ensures the total supply does not exceed
     *      a certain percentage increase from the current supply.
     * @param _recipient The address to receive the newly minted tokens.
     * @param _amount The amount of tokens to mint.
     */
    function mint(address _recipient, uint256 _amount) external onlyGovernanceProposal onlyOncePerBlock {
        require(_amount <= totalSupply() * MAXIMUM_MINT_SUPPLY_PERCENTAGE_BPS / 10000, "ERC246: Cannot mint a percentage of the supply greater than MAXIMUM_MINT_SUPPLY_PERCENTAGE");
        _mint(_recipient, _amount);
    }

    /**
     * @notice Allocate tokens to a list of recipients for future airdrop claims (only callable via a governance proposal).
     * @dev This function sets up an airdrop allocation, which can be claimed by recipients later.
     * @param recipients The list of addresses to receive the airdropped tokens.
     * @param amounts The corresponding list of amounts of tokens allocated to each recipient.
     */
    function airdropByMinting(address[] calldata recipients, uint256[] calldata amounts) external onlyGovernanceProposal onlyOncePerBlock{
        require(recipients.length == amounts.length, "ERC246: Recipients and amounts length mismatch");

        // Calculate the total amount of tokens to be minted
        uint256 totalMintAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalMintAmount += amounts[i];
        }

        require(totalMintAmount <= (totalSupply() * MAXIMUM_MINT_SUPPLY_PERCENTAGE_BPS) / 10000, "ERC246: Minting amount exceeds maximum supply percentage");

        for (uint256 i = 0; i < recipients.length; i++) {
            mintAirdropAllocations[recipients[i]] += amounts[i];
        }
    }

    /**
     * @notice Allocate tokens to a list of recipients for future claims using the contract’s treasury (only callable via governance proposal).
     * @dev This function sets up an airdrop allocation using treasury funds.
     * @param recipients The list of addresses to receive the airdropped tokens.
     * @param amounts The corresponding list of amounts of tokens allocated to each recipient.
     */
    function airdropFromTreasury(address[] calldata recipients, uint256[] calldata amounts) external onlyGovernanceProposal {
        require(recipients.length == amounts.length, "ERC246: Recipients and amounts length mismatch");

        uint256 totalAirdropAmount = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            totalAirdropAmount += amounts[i];
            airdropAllocationsFromTreasury[recipients[i]] += amounts[i];
        }

        require(balanceOf(address(this)) >= totalAirdropAmount, "ERC246: Insufficient contract balance for airdrop");

        lockedTreasuryTokens += totalAirdropAmount;
    }

    /**
     * @notice Burn tokens from the contract's treasury (only callable via a governance proposal).
     * @dev This function burns tokens from the contract balance, reducing the total supply.
     * @param _amount The amount of tokens to burn from the contract's treasury.
     */
    function burnFromTreasury(uint256 _amount) external onlyGovernanceProposal {
        _burn(address(this), _amount);
    }



    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ Other utility functions ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++


    /**
     * @notice Claim allocated airdrop tokens that were minted.
     * @dev This function allows recipients to claim their allocated airdrop tokens from minting.
     */
    function claimMintAirdrop() external nonReentrant {
        uint256 amount = mintAirdropAllocations[msg.sender];
        require(amount > 0, "ERC246: No airdrop tokens available to claim from mint");

        mintAirdropAllocations[msg.sender] = 0;

        _mint(msg.sender, amount);
    }

    /**
     * @notice Claim allocated airdrop tokens from the contract's balance (treasury).
     * @dev This function allows recipients to claim their allocated airdrop tokens from treasury.
     */
    function claimAirdropFromTreasury() external nonReentrant {
        uint256 amount = airdropAllocationsFromTreasury[msg.sender];
        require(amount > 0, "ERC246: No airdrop tokens available to claim from treasury");

        airdropAllocationsFromTreasury[msg.sender] = 0;

        lockedTreasuryTokens -= amount;

        _transfer(address(this), msg.sender, amount);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        // If the contract itself is the sender (i.e., tokens are being transferred from the treasury)
        if (from == address(this)) {
            // Ensure that the amount being transferred does not exceed the unlocked balance
            require(balanceOf(address(this)) - lockedTreasuryTokens >= amount, "ERC246: Insufficient unlocked treasury balance");
        }

        if (to != address(0) && from != address(0)) {
            // Track the block number for token acquisition (for governance voting purposes)
            lastTokenAcquisitionBlock[to] = block.number;
        }

        super._beforeTokenTransfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        // Apply transfer fee if applicable
        if (transferFeeBps > 0 && from != address(0) && to != address(0)) {
            uint256 feeAmount = (amount * transferFeeBps) / 10000;
            uint256 transferAmount = amount - feeAmount;

            // Transfer the fee to the treasury
            super._transfer(from, address(this), feeAmount);

            // Transfer the remaining amount to the recipient
            super._transfer(from, to, transferAmount);
        } else {
            // Perform the regular transfer if no fees
            super._transfer(from, to, amount);
        }
    }



    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ View/pure functions ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++


    /**
     * @notice Calculate the available voting power for an account.
     * @param _account The address of the voter.
     * @return The available voting power based on token balance.
     */
    function _getVotingPower(address _account) internal view returns (uint256) {
        if (block.number == lastTokenAcquisitionBlock[_account]) {return 0;}
        return balanceOf(_account);
    }

    /**
     * @notice Get the current voting outcome of a proposal.
     * @dev This function calculates the total votes for and against a proposal based on the current token balances of voters.
     * It loops through all voters of the proposal and calculates their voting power.
     * @param _proposalId The ID of the proposal for which to retrieve the voting outcome.
     * @return votesFor The total votes in favor of the proposal, calculated from the voting power of supporting voters.
     * @return votesAgainst The total votes against the proposal, calculated from the voting power of opposing voters.
     */
    function getProposalCurrentOutcome(uint256 _proposalId) override public view returns (uint256 votesFor, uint256 votesAgainst) {
        Proposal storage proposal = _getProposal(_proposalId);
        
        // Initialize votes for and against
        uint256 totalVotesFor = 0;
        uint256 totalVotesAgainst = 0;
        
        // Calculate voting power based on current token balances
        address[] memory voters = proposal.voters;
        uint256 numVoters = voters.length;
        for (uint256 i = 0; i < numVoters;) {
            address voter = voters[i];
            uint256 currentVotingPower = _getVotingPower(voter); // Snapshot based on current balance
            
            if (proposal.voteSupport[voter]) {
                unchecked { totalVotesFor += currentVotingPower; }
            } else {
                unchecked { totalVotesAgainst += currentVotingPower; }
            }
            unchecked { ++i; }
        }
        
        return (totalVotesFor, totalVotesAgainst);
    }

    /**
     * @dev Internal function to retrieve a proposal and ensure it hasn't been deleted.
     * @param _proposalId The ID of the proposal to retrieve.
     * @return proposal The retrieved proposal.
     */
    function _getProposal(uint256 _proposalId) private view returns (Proposal storage) {
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.proposer != address(0), "ERC246: Proposal does not exist or has been deleted");
        return proposal;
    }

    /**
     * @notice Override the `name` function from ERC20 to allow dynamic updates via governance proposal.
     * @return The name of the token.
     */
    function name() public view override returns (string memory) {
        return _name;
    }

    /**
     * @notice Override the `symbol` function from ERC20 to allow dynamic updates via governance proposal.
     * @return The symbol of the token.
     */
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /**
     * @notice Get target contract addresses of a proposal
     * @return An array of target contract addresses
     */
    function getProposalTargets(uint256 _proposalId) public view returns (address[] memory) {
        return _getProposal(_proposalId).targets;
    }

    /**
     * @notice Get encoded functions call data of a proposal
     * @return An array of encoded functions call data
     */
    function getProposalFunctionsData(uint256 _proposalId) public view returns (bytes[] memory) {
        return _getProposal(_proposalId).data;
    }

    /**
     * @notice Get ETH values of a proposal
     * @return An array of ETH values
     */
    function getProposalETHValues(uint256 _proposalId) public view returns (uint256[] memory) {
        return _getProposal(_proposalId).values;
    }

    /**
     * @notice Get addresses who voted in a proposal
     * @return An array voter addresses
     */
    function getProposalVoters(uint256 _proposalId) public view returns (address[] memory) {
        return _getProposal(_proposalId).voters;
    }

    /**
     * @notice Checks if a address has voted in a proposal
     * @return Boolean indicating if the address has voted
     */
    function hasVoted(address _voter, uint256 _proposalId) public view returns (bool) {
        return _getProposal(_proposalId).hasVoted[_voter];
    }

    /**
     * @notice Checks if a address has voted for or against a proposal
     * @return Boolean indicating voter's support
     */
    function gatVoteSupport(address _voter, uint256 _proposalId) public view returns (bool) {
        return _getProposal(_proposalId).voteSupport[_voter];
    }
}
