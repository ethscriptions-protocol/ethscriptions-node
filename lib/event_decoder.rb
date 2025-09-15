require 'eth'

class EventDecoder
  # Pre-computed event signatures
  ETHSCRIPTION_CREATED = '0x' + Eth::Util.keccak256(
    'EthscriptionCreated(bytes32,address,address,bytes32,uint256,uint256)'
  ).unpack1('H*')

  # New Ethscriptions protocol transfer event (matches protocol semantics)
  ETHSCRIPTION_TRANSFERRED = '0x' + Eth::Util.keccak256(
    'EthscriptionTransferred(bytes32,address,address,uint256)'
  ).unpack1('H*')

  # Standard ERC721 Transfer event
  ERC721_TRANSFER = '0x' + Eth::Util.keccak256(
    'Transfer(address,address,uint256)'
  ).unpack1('H*')

  ETHSCRIPTIONS_ADDRESS = '0x3300000000000000000000000000000000000001'

  class << self
    def decode_receipt_logs(receipt)
      creations = []
      transfers = []
      protocol_transfers = []  # Ethscriptions protocol semantics

      return {creations: [], transfers: [], protocol_transfers: []} unless receipt && receipt['logs']

      receipt['logs'].each do |log|
        case log['topics']&.first
        when ETHSCRIPTION_CREATED
          creation = decode_creation(log)
          creations << creation if creation
        when ETHSCRIPTION_TRANSFERRED
          # This is the Ethscriptions protocol transfer with correct semantics
          next unless log['address']&.downcase == ETHSCRIPTIONS_ADDRESS.downcase
          transfer = decode_protocol_transfer(log)
          protocol_transfers << transfer if transfer
        when ERC721_TRANSFER
          # Only process transfers from the Ethscriptions contract
          next unless log['address']&.downcase == ETHSCRIPTIONS_ADDRESS.downcase
          transfer = decode_transfer(log)
          transfers << transfer if transfer
        end
      end

      {
        creations: creations.compact,
        transfers: transfers.compact,  # ERC-721 transfers (from address(0) for mints)
        protocol_transfers: protocol_transfers.compact  # Ethscriptions protocol transfers
      }
    end

    def decode_block_receipts(receipts)
      all_creations = []
      all_transfers = []
      all_protocol_transfers = []

      receipts.each do |receipt|
        data = decode_receipt_logs(receipt)
        all_creations.concat(data[:creations])
        all_transfers.concat(data[:transfers])
        all_protocol_transfers.concat(data[:protocol_transfers])
      end

      {
        creations: all_creations,
        transfers: all_transfers,  # ERC-721 transfers
        protocol_transfers: all_protocol_transfers  # Ethscriptions protocol transfers
      }
    end

    private

    def decode_creation(log)
      return nil unless log['topics']&.size >= 4

      # Event EthscriptionCreated:
      # topics[0] = event signature
      # topics[1] = indexed bytes32 transactionHash
      # topics[2] = indexed address creator
      # topics[3] = indexed address initialOwner
      # data = abi.encode(contentSha, ethscriptionNumber, pointerCount)

      tx_hash = log['topics'][1]
      creator = decode_address_from_topic(log['topics'][2])
      initial_owner = decode_address_from_topic(log['topics'][3])

      # Decode non-indexed data
      data = log['data'] || '0x'
      data_bytes = [data.delete_prefix('0x')].pack('H*')

      return nil if data_bytes.length < 96  # Need at least 3 * 32 bytes

      content_sha = '0x' + data_bytes[0, 32].unpack1('H*')
      ethscription_number = data_bytes[32, 32].unpack1('H*').to_i(16)
      pointer_count = data_bytes[64, 32].unpack1('H*').to_i(16)

      {
        tx_hash: tx_hash,
        creator: creator,
        initial_owner: initial_owner,
        content_sha: content_sha,
        ethscription_number: ethscription_number,
        pointer_count: pointer_count
      }
    rescue => e
      Rails.logger.error "Failed to decode creation event: #{e.message}"
      nil
    end

    def decode_transfer(log)
      return nil unless log['topics']&.size >= 4

      # Event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)
      # All parameters are indexed
      from = decode_address_from_topic(log['topics'][1])
      to = decode_address_from_topic(log['topics'][2])
      token_id = log['topics'][3]  # This is the ethscription tx hash

      {
        token_id: token_id,
        from: from,
        to: to
      }
    rescue => e
      Rails.logger.error "Failed to decode transfer event: #{e.message}"
      nil
    end

    def decode_protocol_transfer(log)
      return nil unless log['topics']&.size >= 4

      # Event EthscriptionTransferred(bytes32 indexed transactionHash, address indexed from, address indexed to, uint256 ethscriptionNumber)
      # First 3 parameters are indexed, last one is in data
      tx_hash = log['topics'][1]  # bytes32 transactionHash
      from = decode_address_from_topic(log['topics'][2])
      to = decode_address_from_topic(log['topics'][3])

      # Decode the non-indexed data (ethscriptionNumber)
      ethscription_number = nil
      if log['data'] && log['data'] != '0x'
        decoded = Eth::Abi.decode(['uint256'], log['data'])
        ethscription_number = decoded[0]
      end

      {
        token_id: tx_hash,  # Use same field name for consistency
        from: from,
        to: to,
        ethscription_number: ethscription_number
      }
    rescue => e
      Rails.logger.error "Failed to decode protocol transfer event: #{e.message}"
      nil
    end

    def decode_address_from_topic(topic)
      return nil unless topic

      # Topics are 32 bytes, addresses are 20 bytes (last 40 hex chars)
      '0x' + topic[-40..]
    end
  end
end