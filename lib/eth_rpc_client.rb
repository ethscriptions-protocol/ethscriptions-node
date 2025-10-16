class EthRpcClient
  include Memery

  class HttpError < StandardError
    attr_reader :code, :http_message

    def initialize(code, http_message)
      @code = code
      @http_message = http_message
      super("HTTP error: #{code} #{http_message}")
    end
  end
  class ApiError < StandardError; end
  class ExecutionRevertedError < StandardError; end
  class MethodRequiredError < StandardError; end
  attr_accessor :base_url, :http

  def initialize(base_url = ENV['L1_RPC_URL'], jwt_secret: nil, retry_config: {})
    self.base_url = base_url
    @request_id = 0
    @mutex = Mutex.new

    # JWT support (optional, only for HTTP)
    @jwt_secret = jwt_secret
    @jwt_enabled = !jwt_secret.nil?
    
    if @jwt_enabled
      @jwt_secret_decoded = ByteString.from_hex(jwt_secret).to_bin
    end

    # Customizable retry configuration
    @retry_config = {
      tries: 7,
      base_interval: 1,
      max_interval: 32,
      multiplier: 2,
      rand_factor: 0.4
    }.merge(retry_config)

    # Detect transport mode
    @mode = detect_mode(base_url)

    if @mode == :ipc
      @ipc_path = base_url.start_with?("ipc://") ? base_url.delete_prefix("ipc://") : base_url
      @ipc_socket = nil
      @ipc_mutex = Mutex.new
      Rails.logger.info "EthRpcClient using IPC at: #{@ipc_path}"
    else
      @uri = URI(base_url)
      @http = Net::HTTP::Persistent.new(
        name: "eth_rpc_#{@uri.host}:#{@uri.port}",
        pool_size: 100  # Increase pool size from default 64
      )
      @http.open_timeout = 10   # 10 seconds to establish connection
      @http.read_timeout = 30   # 30 seconds for slow eth_call operations
      @http.idle_timeout = 30   # Keep connections alive for 30 seconds
    end
  end

  def self.l1
    @_l1_client ||= new(ENV.fetch('L1_RPC_URL'))
  end

  def self.l2
    @_l2_client ||= new(ENV.fetch('NON_AUTH_GETH_RPC_URL'))
  end

  def self.l2_engine
    @_l2_engine_client ||= new(
      ENV.fetch('GETH_RPC_URL'),
      jwt_secret: ENV.fetch('JWT_SECRET'),
      retry_config: { tries: 5, base_interval: 0.5, max_interval: 4 }
    )
  end

  def get_block(block_number, include_txs = false)
    if block_number.is_a?(String)
      return query_api(
        method: 'eth_getBlockByNumber',
        params: [block_number, include_txs]
      )
    end
    
    query_api(
      method: 'eth_getBlockByNumber',
      params: ['0x' + block_number.to_s(16), include_txs]
    )
  end
  
  def get_nonce(address, block_number = "latest")
    query_api(
      method: 'eth_getTransactionCount',
      params: [address, block_number]
    ).to_i(16)
  end
  
  def get_chain_id
    query_api(method: 'eth_chainId').to_i(16)
  end
  
  def trace_block(block_number)
    query_api(
      method: 'debug_traceBlockByNumber',
      params: ['0x' + block_number.to_s(16), { tracer: "callTracer", timeout: "10s" }]
    )
  end

  def trace_transaction(transaction_hash)
    query_api(
      method: 'debug_traceTransaction',
      params: [transaction_hash, { tracer: "callTracer", timeout: "10s" }]
    )
  end

  def trace(tx_hash)
    trace_transaction(tx_hash)
  end
  
  def get_transaction(transaction_hash)
    query_api(
      method: 'eth_getTransactionByHash',
      params: [transaction_hash]
    )
  end
  
  def get_transaction_receipts(block_number)
    if block_number.is_a?(String)
      return query_api(
        method: 'eth_getBlockReceipts',
        params: [block_number]
      )
    end
    
    query_api(
      method: 'eth_getBlockReceipts',
      params: ["0x" + block_number.to_s(16)]
    )
  end
  
  def get_block_receipts(block_number)
    get_transaction_receipts(block_number)
  end
  
  def get_transaction_receipt(transaction_hash)
    query_api(
      method: 'eth_getTransactionReceipt',
      params: [transaction_hash]
    )
  end
  
  def get_block_number
    query_api(method: 'eth_blockNumber').to_i(16)
  end

  def query_api(method = nil, params = [], **kwargs)
    if kwargs.present?
      method = kwargs[:method]
      params = kwargs[:params]
    end

    unless method
      raise MethodRequiredError, "Method is required"
    end

    data = {
      id: next_request_id,
      jsonrpc: "2.0",
      method: method,
      params: params
    }

    # Unified retry logic for both HTTP and IPC
    Retriable.retriable(
      tries: @retry_config[:tries],
      base_interval: @retry_config[:base_interval],
      max_interval: @retry_config[:max_interval],
      multiplier: @retry_config[:multiplier],
      rand_factor: @retry_config[:rand_factor],
      on: [Net::ReadTimeout, Net::OpenTimeout, HttpError, ApiError, Errno::EPIPE, EOFError, Errno::ECONNREFUSED],
      on_retry: ->(exception, try, elapsed_time, next_interval) {
        Rails.logger.info "Retrying #{method} (attempt #{try}, next delay: #{next_interval.round(2)}s) - #{exception.message}"
        # Reset IPC connection on retry if it's broken
        if @mode == :ipc && [Errno::EPIPE, EOFError, ApiError].include?(exception.class)
          @ipc_mutex.synchronize do
            ensure_ipc_connected!(force: true)
          end
        end
      }
    ) do
      if @mode == :ipc
        send_ipc_request_simple(data)
      else
        send_http_request_simple(data)
      end
    end
  rescue Errno::EACCES, Errno::EPERM => e
    # Permission errors should not be retried - fail immediately with clear message
    raise "IPC socket permission denied at #{@ipc_path}: #{e.message}. Check socket permissions (chmod 666) or use HTTP instead."
  rescue ApiError => e
    # Engine API methods not available on IPC - fail with clear message
    if e.message.include?("Method not found") && method.start_with?("engine_")
      raise "Engine API method '#{method}' not available on IPC. Use authenticated HTTP endpoint instead."
    else
      raise
    end
  end

  def send_ipc_request_simple(data)
    @ipc_mutex.synchronize do
      ensure_ipc_connected!

      request_body = data.to_json

      ImportProfiler.start("send_ipc_request")
      @ipc_socket.write(request_body)
      @ipc_socket.write("\n")
      @ipc_socket.flush
      # Wait for response with timeout to prevent hanging if geth dies
      timeout = 10 # seconds
      readable = IO.select([@ipc_socket], nil, nil, timeout)

      if readable.nil?
        # Timeout occurred - force reconnection on retry
        ensure_ipc_connected!(force: true)
        raise ApiError, "IPC response timeout after #{timeout} seconds"
      end

      response_raw = @ipc_socket.gets # single JSON object per line
      ImportProfiler.stop("send_ipc_request")
      raise ApiError, "empty IPC response" unless response_raw

      parse_response_and_handle_errors(response_raw)
    end
  end

  def ensure_ipc_connected!(force: false)
    if force && @ipc_socket
      @ipc_socket.close unless @ipc_socket.closed?
      @ipc_socket = nil
    end

    return if @ipc_socket && !@ipc_socket.closed?
    @ipc_socket = UNIXSocket.new(@ipc_path)
  end

  def send_http_request_simple(data)
    url = base_url
    uri = URI(url)
    request = Net::HTTP::Post.new(uri)
    request.body = data.to_json
    headers.each { |key, value| request[key] = value }

    response = @http.request(uri, request)

    if response.code.to_i != 200
      raise HttpError.new(response.code.to_i, response.message)
    end

    parse_response_and_handle_errors(response.body)
  end

  def call(method, params = [])
    query_api(method: method, params: params)
  end
  
  def eth_call(to:, data:, block_number: "latest")
    query_api(
      method: 'eth_call',
      params: [{ to: to, data: data }, block_number]
    )
  end
  
  def headers
    h = {
      'Accept' => 'application/json',
      'Content-Type' => 'application/json'
    }
    # Add JWT authorization if enabled
    h['Authorization'] = "Bearer #{jwt}" if @jwt_enabled && @mode == :http
    h
  end

  def jwt
    return nil unless @jwt_enabled
    JWT.encode({ iat: Time.now.to_i }, @jwt_secret_decoded, 'HS256')
  end
  memoize :jwt, ttl: 55 # 55 seconds to refresh before 60 second expiry
  
  def get_code(address, block_number = "latest")
    query_api(
      method: 'eth_getCode',
      params: [address, block_number]
    )
  end

  def get_storage_at(address, slot, block_number = "latest")
    query_api(
      method: 'eth_getStorageAt',
      params: [address, slot, block_number]
    )
  end

  private

  def parse_response_and_handle_errors(response_text)
    parsed_response = JSON.parse(response_text, max_nesting: false)

    if parsed_response['error']
      error_message = parsed_response.dig('error', 'message') || 'Unknown API error'

      # Don't retry execution reverted errors as they're deterministic failures
      if error_message.include?('execution reverted')
        raise ExecutionRevertedError, "API error: #{error_message}"
      end

      raise ApiError, "API error: #{error_message}"
    end

    parsed_response['result']
  end

  def detect_mode(url)
    begin
      uri = URI.parse(url)
      return :http if %w[http https].include?(uri.scheme)
    rescue URI::InvalidURIError
      # Not a valid URI, might be IPC path
    end

    # Check if it's an IPC path
    if url.start_with?("ipc://") || url.include?(".ipc") || File.socket?(url.delete_prefix("ipc://"))
      :ipc
    else
      :http
    end
  end

  def next_request_id
    @mutex.synchronize { @request_id += 1 }
  end
end
