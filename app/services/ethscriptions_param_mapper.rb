# Maps Ruby transaction objects to contract method parameters
class EthscriptionsParamMapper
  class << self
    # Build parameters for createEthscription contract method
    # @param eth_transaction [EthTransaction] The transaction containing the ethscription
    # @param creator [String] The creator address (from_address or event address)
    # @param initial_owner [String] The initial owner address
    # @param content_uri [String] The content URI (already UTF-8 decoded)
    # @return [Hash] Parameters for contract call
    def build_create_params(eth_transaction, creator:, initial_owner:, content_uri:)
      # Parse data URI to extract metadata
      parsed_uri = parse_data_uri(content_uri)
      
      {
        transactionHash: eth_transaction.transaction_hash,
        initialOwner: initial_owner.downcase,
        contentUri: content_uri.force_encoding('BINARY'), # Send as bytes
        mimetype: parsed_uri[:mimetype],
        mediaType: parsed_uri[:media_type],
        mimeSubtype: parsed_uri[:mime_subtype],
        esip6: parsed_uri[:esip6]
      }
    end
    
    # Build parameters for createEthscription from transaction input
    def build_create_params_from_input(eth_transaction)
      build_create_params(
        eth_transaction,
        creator: eth_transaction.from_address,
        initial_owner: eth_transaction.to_address,
        content_uri: eth_transaction.utf8_input
      )
    end
    
    # Build parameters for createEthscription from event log
    def build_create_params_from_event(eth_transaction, event_log)
      # Decode event parameters
      initial_owner = decode_address_from_topic(event_log['topics'][1])
      content_uri = decode_string_from_data(event_log['data'])
      
      build_create_params(
        eth_transaction,
        creator: event_log['address'],
        initial_owner: initial_owner,
        content_uri: content_uri
      )
    end
    
    # Build parameters for transferEthscription contract method
    # @param ethscription_tx_hash [String] The ethscription transaction hash to transfer
    # @param to_address [String] The recipient address
    # @return [Hash] Parameters for contract call
    def build_transfer_params(ethscription_tx_hash:, to_address:)
      {
        transactionHash: ethscription_tx_hash,
        to: to_address.downcase
      }
    end
    
    # Build parameters for transferEthscriptionForPreviousOwner contract method (ESIP-2)
    # @param ethscription_tx_hash [String] The ethscription transaction hash to transfer
    # @param to_address [String] The recipient address
    # @param previous_owner [String] The required previous owner for validation
    # @return [Hash] Parameters for contract call
    def build_transfer_for_previous_owner_params(ethscription_tx_hash:, to_address:, previous_owner:)
      {
        transactionHash: ethscription_tx_hash,
        to: to_address.downcase,
        previousOwner: previous_owner.downcase
      }
    end
    
    # Build transaction metadata for logging/context
    # @param eth_transaction [EthTransaction] The source transaction
    # @param from_address [String] Override from address (for events)
    # @return [Hash] Transaction metadata
    def build_tx_meta(eth_transaction, from_address: nil)
      {
        from_address: (from_address || eth_transaction.from_address).downcase,
        block_number: eth_transaction.block_number,
        transaction_index: eth_transaction.transaction_index,
        transaction_hash: eth_transaction.transaction_hash,
        block_timestamp: eth_transaction.block_timestamp
      }
    end
    
    # Check if parameters are well-formed (not validation, just structure)
    # We only check if we have the required fields to make the call
    # ALL validation happens in the EVM
    # @param params [Hash] The parameters to check
    # @param method [Symbol] The contract method being called
    # @return [Boolean] true if params are well-formed
    def params_well_formed?(params, method)
      case method
      when :createEthscription
        params[:transactionHash].present? &&
        params[:initialOwner].present? &&
        params[:contentUri].present?
      when :transferEthscription
        params[:transactionHash].present? &&
        params[:to].present?
      when :transferEthscriptionForPreviousOwner
        params[:transactionHash].present? &&
        params[:to].present? &&
        params[:previousOwner].present?
      else
        false
      end
    end
    
    private
    
    def parse_data_uri(content_uri)
      return empty_metadata unless DataUri.valid?(content_uri)
      
      parsed = DataUri.new(content_uri)
      mimetype = parsed.mimetype || "application/octet-stream"
      parts = mimetype.split('/')
      
      {
        mimetype: mimetype.first(1000), # Match contract's MAX_MIMETYPE_LENGTH
        media_type: parts[0] || "",
        mime_subtype: parts[1] || "",
        esip6: DataUri.esip6?(content_uri)
      }
    rescue => e
      Rails.logger.warn("Failed to parse data URI: #{e.message}")
      empty_metadata
    end
    
    def empty_metadata
      {
        mimetype: "",
        media_type: "",
        mime_subtype: "",
        esip6: false
      }
    end
    
    def decode_address_from_topic(topic)
      return nil if topic.nil?
      
      # Topic is 32 bytes hex, address is last 20 bytes
      address_bytes = [topic.sub(/^0x/, '')].pack("H*")[-20..]
      "0x" + address_bytes.unpack1("H*")
    rescue => e
      Rails.logger.error("Failed to decode address from topic: #{e.message}")
      nil
    end
    
    def decode_string_from_data(data)
      return "" if data.nil?
      
      # Remove 0x prefix and decode ABI-encoded string
      hex_data = data.sub(/^0x/, '')
      bytes = [hex_data].pack("H*")
      
      # ABI string encoding: offset (32 bytes) + length (32 bytes) + data
      return "" if bytes.length < 64
      
      # Skip offset, read length
      length = bytes[32..63].unpack1("Q>") # Big-endian 64-bit
      
      # Read string data
      string_data = bytes[64...(64 + length)]
      HexDataProcessor.clean_utf8(string_data)
    rescue => e
      Rails.logger.error("Failed to decode string from data: #{e.message}")
      ""
    end
    
    # Note: We don't validate addresses or data URIs anymore
    # The EVM handles all validation
  end
end
