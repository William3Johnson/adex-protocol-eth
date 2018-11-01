pragma solidity ^0.4.25;
pragma experimental ABIEncoderV2;

import "./libs/SafeMath.sol";
import "./libs/SignatureValidator.sol";
import "./libs/SafeERC20.sol";
import "./libs/MerkleProof.sol";
import "./libs/ChannelLibrary.sol";
import "./AdExCoreInterface.sol";

// AUDIT: Things we should look for
// 1) every time we check the state, the function should either revert or change the state
// 2) state transition: channelOpen locks up tokens, then all of the tokens can be withdrawn on channelExpiredWithdraw, except how many were withdrawn using channelWithdraw
// 3) external calls (everything using SafeERC20) should be at the end

contract AdExCore is AdExCoreInterface {
	using SafeMath for uint;
	using ChannelLibrary for ChannelLibrary.Channel;

 	// channelId => channelState
	mapping (bytes32 => ChannelLibrary.State) private states;
	
	// withdrawn per channel (channelId => uint)
	mapping (bytes32 => uint) private withdrawn;
	// withdrawn per channel user (channelId => (account => uint))
	mapping (bytes32 => mapping (address => uint)) private withdrawnPerUser;


	function channelOpen(ChannelLibrary.Channel memory channel)
		public
	{
		bytes32 channelId = channel.hash();
		require(states[channelId] == ChannelLibrary.State.Unknown, "INVALID_STATE");
		require(msg.sender == channel.creator, "INVALID_CREATOR");
		require(channel.isValid(now), "INVALID_CHANNEL");
		
		states[channelId] = ChannelLibrary.State.Active;

		SafeERC20.transferFrom(channel.tokenAddr, msg.sender, address(this), channel.tokenAmount);
		// @TODO events
	}

	function channelWithdrawExpired(ChannelLibrary.Channel memory channel)
		public
	{
		bytes32 channelId = channel.hash();
		require(states[channelId] == ChannelLibrary.State.Active, "INVALID_STATE");
		require(now > channel.validUntil, "NOT_EXPIRED");
		require(msg.sender == channel.creator, "INVALID_CREATOR");
		
		uint amount = channel.tokenAmount.sub(withdrawn[channelId]);

		// should we update withdrawn?
		//withdrawn[channelId] = channel.tokenAmount;
		states[channelId] = ChannelLibrary.State.Expired;
		
		SafeERC20.transfer(channel.tokenAddr, msg.sender, amount);
		// @TODO event
	}

	// @TODO: all args here should be in a struct
	function channelWithdraw(ChannelLibrary.WithdrawalRequest memory request)
		public
	{
		bytes32 channelId = request.channel.hash();
		require(states[channelId] == ChannelLibrary.State.Active, "INVALID_STATE");
		require(now <= request.channel.validUntil, "EXPIRED");

		// @TODO: should we move isSignedBySupermajority to the library, and maybe within the request?
		bytes32 hashToSign = keccak256(abi.encode(channelId, request.state));
		require(isSignedBySupermajority(hashToSign, request.channel.validators, request.signatures), "NOT_SIGNED_BY_VALIDATORS");
		
		bytes32 balanceLeaf = keccak256(abi.encode(msg.sender, request.amountInTree));
		require(MerkleProof.isContained(balanceLeaf, request.proof, request.state), "BALANCELEAF_NOT_FOUND");
		
		uint toWithdraw = request.amountInTree.sub(withdrawnPerUser[channelId][msg.sender]);
		withdrawnPerUser[channelId][msg.sender] = request.channel.tokenAmount;

		withdrawn[channelId] = withdrawn[channelId].add(toWithdraw);
		require(withdrawn[channelId] <= request.channel.tokenAmount, "WITHDRAWING_MORE_THAN_DEPOSIT");

		SafeERC20.transfer(request.channel.tokenAddr, msg.sender, toWithdraw);
		// @TODO event
	}

	// @TODO: can we move this out?
	function isSignedBySupermajority(bytes32 toSign, address[] memory validators, bytes32[3][] memory signatures) 
		internal
		pure
		returns (bool)
	{
		if (signatures.length != validators.length) {
			return false;
		}

		uint votes = 0;
		for (uint i=0; i<signatures.length; i++) {
			// NOTE: if a validator has not signed, you can just use SignatureMode.NO_SIG
			if (SignatureValidator.isValidSignature(toSign, validators[i], signatures[i])) {
				votes++;
			}
		}
		return votes*3 >= validators.length*2;
	}

	// Views
	// @TODO
}
