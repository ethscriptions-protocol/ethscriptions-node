class EthscriptionTransaction < T::Struct
  include SysConfig
  include AttrAssignable

  prop :chain_id, T.nilable(Integer)
  prop :eth_transaction_hash, T.nilable(Hash32)
  prop :eth_transaction_input, T.nilable(ByteString)
  prop :eth_call_index, T.nilable(Integer)
  prop :block_hash, T.nilable(Hash32)
  prop :block_number, T.nilable(Integer)
  prop :deposit_receipt_version, T.nilable(String)
  prop :from_address, T.nilable(Address20)
  prop :gas_limit, T.nilable(Integer)
  prop :tx_hash, T.nilable(Hash32)
  prop :input, T.nilable(ByteString)
  prop :source_hash, T.nilable(Hash32)
  prop :to_address, T.nilable(Address20)
  prop :transaction_index, T.nilable(Integer)
  prop :tx_type, T.nilable(String)
  prop :mint, T.nilable(Integer)
  prop :value, T.nilable(Integer)

  prop :ethscriptions_block, T.nilable(EthscriptionsBlock)

  # Ethscription-specific properties
  prop :ethscription_operation, T.nilable(String) # 'create', 'transfer', 'transfer_esip2'
  prop :ethscription_data, T.nilable(Hash)

  # Deposit transaction type
  DEPOSIT_TX_TYPE = 0x7D
  ETHSCRIPTIONS_CONTRACT_ADDRESS = '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE'

  # Build deposits from an L1 transaction
  sig { params(eth_transaction: EthTransaction, ethscriptions_block: EthscriptionsBlock).returns(T::Array[EthscriptionTransaction]) }
  def self.build_deposits(eth_transaction, ethscriptions_block)
    EthscriptionTransactionBuilder.build_deposits(eth_transaction, ethscriptions_block)
  end
  
  def self.l1_attributes_tx_from_blocks(ethscriptions_block)
    calldata = L1AttributesTxCalldata.build(ethscriptions_block)

    tx = new
    tx.chain_id = ChainIdManager.current_l2_chain_id
    tx.to_address = L1_INFO_ADDRESS
    tx.value = 0
    tx.mint = 0
    tx.gas_limit = 1_000_000
    tx.input = calldata
    tx.from_address = SYSTEM_ADDRESS

    tx.ethscriptions_block = ethscriptions_block

    payload = [
      ethscriptions_block.eth_block_hash.to_bin,
      Eth::Util.zpad_int(ethscriptions_block.sequence_number, 32)
    ].join

    tx.source_hash = EthscriptionTransaction.compute_source_hash(
      ByteString.from_bin(payload),
      1
    )

    tx
  end

  sig { params(payload: ByteString, source_domain: Integer).returns(Hash32) }
  def self.compute_source_hash(payload, source_domain)
    bin_val = Eth::Util.keccak256(
      Eth::Util.zpad_int(source_domain, 32) +
      Eth::Util.keccak256(payload.to_bin)
    )
    
    Hash32.from_bin(bin_val)
  end
  
  # Method for deposit payload generation (used by GethDriver)
  sig { returns(ByteString) }
  def to_deposit_payload
    tx_data = []
    tx_data.push(source_hash.to_bin)
    tx_data.push(from_address.to_bin)
    tx_data.push(to_address ? to_address.to_bin : '')
    tx_data.push(Eth::Util.serialize_int_to_big_endian(mint))
    tx_data.push(Eth::Util.serialize_int_to_big_endian(value))
    tx_data.push(Eth::Util.serialize_int_to_big_endian(gas_limit))
    tx_data.push('')
    tx_data.push(input.to_bin)
    tx_encoded = Eth::Rlp.encode(tx_data)

    tx_type = Eth::Util.serialize_int_to_big_endian(DEPOSIT_TX_TYPE)
    ByteString.from_bin("#{tx_type}#{tx_encoded}")
  end
end