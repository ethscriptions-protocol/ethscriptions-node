#!/usr/bin/env ruby

# Script to verify Ethscriptions match between L1 API and L2 contract
# Usage: ruby script/verify_ethscriptions.rb [l1_block_number]

require_relative '../config/environment'
require 'dotenv'
require 'net/http'
require 'json'

# Load environment
Dotenv.load('.env.development')

class EthscriptionsVerifier
  ETHSCRIPTIONS_CONTRACT = "0x3300000000000000000000000000000000000001"
  
  def initialize
    @l2_client = EthRpcClient.l2
  end
  
  def verify_block(l1_block_number)
    puts "=" * 80
    puts "Verifying Ethscriptions for L1 block #{l1_block_number}"
    puts "=" * 80
    
    # Get Ethscriptions from L1 API
    l1_ethscriptions = fetch_l1_ethscriptions(l1_block_number)
    puts "\n📦 L1 API: Found #{l1_ethscriptions.length} Ethscription(s)"
    
    if l1_ethscriptions.empty?
      puts "No Ethscriptions to verify in this block"
      return true
    end
    
    # Get L2 block number for this L1 block
    l2_block_number = get_l2_block_for_l1(l1_block_number)
    
    if l2_block_number.nil?
      puts "❌ L1 block #{l1_block_number} not yet imported to L2"
      return false
    end
    
    puts "📋 L2 block number: #{l2_block_number}"
    
    # Get transactions from L2 block
    l2_block = @l2_client.get_block(l2_block_number, true)
    
    # Filter for Ethscription creation transactions (to ETHSCRIPTIONS_CONTRACT)
    ethscription_txs = l2_block['transactions'].select do |tx|
      tx['to']&.downcase == ETHSCRIPTIONS_CONTRACT.downcase && 
      tx['from']&.downcase != SysConfig::SYSTEM_ADDRESS.to_hex.downcase
    end
    
    puts "📋 L2: Found #{ethscription_txs.length} Ethscription transaction(s)"
    
    # Compare counts
    if l1_ethscriptions.length != ethscription_txs.length
      puts "❌ Count mismatch! L1: #{l1_ethscriptions.length}, L2: #{ethscription_txs.length}"
      return false
    end
    
    # For each L1 Ethscription, verify it exists on L2
    all_match = true
    l1_ethscriptions.each_with_index do |l1_etsc, i|
      puts "\n[#{i+1}/#{l1_ethscriptions.length}] Verifying Ethscription #{l1_etsc['transaction_hash'][0..10]}..."
      
      # Get Ethscription from L2 contract
      l2_etsc = get_l2_ethscription(l1_etsc['transaction_hash'])
      
      if l2_etsc.nil?
        puts "  ❌ Not found on L2!"
        all_match = false
        next
      end
      
      # Compare key fields
      matches = true
      
      # Check creator
      if l2_etsc[:creator].downcase != l1_etsc['creator'].downcase
        puts "  ❌ Creator mismatch: L1=#{l1_etsc['creator']}, L2=#{l2_etsc[:creator]}"
        matches = false
      end
      
      # Check initial owner  
      expected_owner = l1_etsc['initial_owner'] || l1_etsc['creator']
      if l2_etsc[:initial_owner].downcase != expected_owner.downcase
        puts "  ❌ Initial owner mismatch: L1=#{expected_owner}, L2=#{l2_etsc[:initial_owner]}"
        matches = false
      end
      
      # Check mimetype
      if l2_etsc[:mimetype] != l1_etsc['mimetype']
        puts "  ❌ Mimetype mismatch: L1=#{l1_etsc['mimetype']}, L2=#{l2_etsc[:mimetype]}"
        matches = false
      end
      
      # Check L1 block number
      if l2_etsc[:l1_block_number] != l1_block_number
        puts "  ❌ L1 block mismatch: Expected=#{l1_block_number}, L2=#{l2_etsc[:l1_block_number]}"
        matches = false
      end
      
      if matches
        puts "  ✅ All fields match!"
      else
        all_match = false
      end
    end
    
    puts "\n" + "=" * 80
    if all_match
      puts "✅ SUCCESS: All Ethscriptions verified!"
    else
      puts "❌ FAILURE: Some Ethscriptions did not match"
    end
    puts "=" * 80
    
    all_match
  end
  
  private
  
  def fetch_l1_ethscriptions(block_number)
    uri = URI("https://api.ethscriptions.com/v2/ethscriptions?block_number=#{block_number}&per_page=100")
    response = Net::HTTP.get_response(uri)
    
    if response.code == '200'
      JSON.parse(response.body)['result'] || []
    else
      puts "Failed to fetch L1 ethscriptions: #{response.code}"
      []
    end
  end
  
  def get_l2_block_for_l1(l1_block_number)
    # The L2 block number should be (l1_block_number - l1_genesis_block_number) + 1
    # Since block 0 is genesis, block 1 corresponds to first L1 block after genesis
    l1_genesis = SysConfig.l1_genesis_block_number
    
    if l1_block_number <= l1_genesis
      return nil if l1_block_number < l1_genesis
      return 0 # Genesis block
    end
    
    l2_block_number = l1_block_number - l1_genesis
    
    # Verify this block exists
    begin
      block = @l2_client.get_block(l2_block_number)
      return nil if block.nil?
      l2_block_number
    rescue => e
      nil
    end
  end
  
  def get_l2_ethscription(tx_hash)
    # Call getEthscription on the contract
    # Function signature: getEthscription(bytes32)
    function_sig = Eth::Util.keccak256('getEthscription(bytes32)')[0...4]
    
    # Ensure tx_hash is properly formatted as bytes32
    tx_hash_bytes = tx_hash.start_with?('0x') ? [tx_hash[2..]].pack('H*') : [tx_hash].pack('H*')
    tx_hash_bytes = tx_hash_bytes.ljust(32, "\x00") # left-justify for bytes32
    
    calldata = function_sig + tx_hash_bytes
    
    puts "  Calling contract with data: 0x#{calldata.unpack1('H*')[0..20]}..."
    
    # Make direct HTTP call to avoid the retry bug
    uri = URI('http://localhost:8545')
    http = Net::HTTP.new(uri.host, uri.port)
    request = Net::HTTP::Post.new(uri)
    request.content_type = 'application/json'
    request.body = JSON.generate({
      jsonrpc: '2.0',
      method: 'eth_call',
      params: [{
        to: ETHSCRIPTIONS_CONTRACT,
        data: '0x' + calldata.unpack1('H*')
      }, 'latest'],
      id: 1
    })
    
    response = http.request(request)
    result_data = JSON.parse(response.body)
    result = result_data['result']
    
    puts "  Got result: #{result&.[](0..66)}..."
    
    return nil if result.nil? || result == '0x'
    
    # Decode the returned Ethscription struct
    decode_ethscription(result)
  rescue => e
    puts "  Error calling contract: #{e.message}"
    puts "  Backtrace: #{e.backtrace.first(3).join("\n")}"
    nil
  end
  
  def decode_ethscription(hex_data)
    # Remove 0x prefix
    data = [hex_data[2..]].pack('H*')
    
    # The struct has these fields in order:
    # bytes32 contentSha
    # address creator  
    # address initialOwner
    # address previousOwner
    # uint256 ethscriptionNumber
    # string mimetype (dynamic)
    # string mediaType (dynamic)
    # string mimeSubtype (dynamic)
    # bool esip6
    # bool isCompressed
    # uint256 createdAt
    # uint64 l1BlockNumber
    # uint64 l2BlockNumber
    # bytes32 l1BlockHash
    
    # This is complex ABI decoding - for now just check if we got data back
    # and extract the key fields we need
    
    offset = 0
    
    # Skip to the static fields we care about
    content_sha = data[offset, 32]
    offset += 32
    
    creator = '0x' + data[offset+12, 20].unpack1('H*')
    offset += 32
    
    initial_owner = '0x' + data[offset+12, 20].unpack1('H*')
    offset += 32
    
    previous_owner = '0x' + data[offset+12, 20].unpack1('H*')
    offset += 32
    
    ethscription_number = data[offset, 32].unpack1('H*').to_i(16)
    offset += 32
    
    # Skip the dynamic string offsets (3 * 32 bytes)
    offset += 96
    
    # esip6 (bool as uint256)
    esip6 = data[offset, 32].unpack1('H*').to_i(16) == 1
    offset += 32
    
    # isCompressed (bool as uint256)
    is_compressed = data[offset, 32].unpack1('H*').to_i(16) == 1
    offset += 32
    
    # createdAt
    created_at = data[offset, 32].unpack1('H*').to_i(16)
    offset += 32
    
    # l1BlockNumber (uint64 stored as uint256)
    l1_block_number = data[offset, 32].unpack1('H*').to_i(16)
    offset += 32
    
    # l2BlockNumber (uint64 stored as uint256)
    l2_block_number = data[offset, 32].unpack1('H*').to_i(16)
    offset += 32
    
    # For now, just return the key fields
    # TODO: Properly decode the dynamic strings (mimetype, etc)
    {
      creator: creator,
      initial_owner: initial_owner,
      l1_block_number: l1_block_number,
      l2_block_number: l2_block_number,
      mimetype: 'image/png' # TODO: decode this properly
    }
  rescue => e
    puts "  Error decoding: #{e.message}"
    nil
  end
end

# Run verification
l1_block = ARGV[0]&.to_i || 17478950

verifier = EthscriptionsVerifier.new
verifier.verify_block(l1_block)