require 'net/http'
require 'json'
require 'uri'

class EthscriptionsApiClient
  BASE_URL = ENV.fetch('ETHSCRIPTIONS_API_BASE_URL', 'http://127.0.0.1:3000')

  class << self
    def fetch_block_data(block_number)
      creations = fetch_creations(block_number)
      transfers = fetch_transfers(block_number)

      {
        creations: normalize_creations(creations),
        transfers: normalize_transfers(transfers)
      }
    rescue => e
      Rails.logger.error "Failed to fetch block data for #{block_number}: #{e.message}"
      raise
    end

    # private

    def fetch_creations(block_number)
      fetch_paginated("/ethscriptions", {
        block_number: block_number,
        max_results: 50 # Respect swagger max and paginate for full coverage
      })
    end

    def fetch_transfers(block_number)
      fetch_paginated("/ethscription_transfers", {
        block_number: block_number,
        max_results: 50 # Respect swagger max and paginate for full coverage
      })
    end

    def fetch_paginated(path, params)
      results = []
      page_key = nil

      loop do
        query_params = params.dup
        query_params[:page_key] = page_key if page_key

        data = fetch_json(path, query_params)

        # API returns { result: [...], pagination: { has_more:, page_key: } }
        page = data['result'] || []
        pagination = data['pagination'] || {}

        results.concat(page)

        has_more = pagination['has_more']
        page_key = pagination['page_key']
        break unless has_more
      end

      results
    end

    def fetch_json(path, params = {})
      uri = URI("#{BASE_URL}#{path}")
      uri.query = URI.encode_www_form(params) if params.any?

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 5
      http.read_timeout = 10

      request = Net::HTTP::Get.new(uri)
      request['Accept'] = 'application/json'

      response = http.request(request)

      unless response.code == '200'
        raise "API request failed: #{response.code} - #{response.body}"
      end

      JSON.parse(response.body)
    end

    def normalize_creations(data)
      data.map do |item|
        tx_hash = (item['transaction_hash'] || '').downcase
        creator = (item['creator'] || '').downcase
        initial_owner = (item['initial_owner'] || item['creator'] || '').downcase

        {
          tx_hash: tx_hash,
          creator: creator,
          initial_owner: initial_owner,
          content_sha: item['content_sha'],
          mimetype: item['mimetype'],
          block_number: item['block_number'],
          esip6: item['esip6'] || false
        }
      end
    end

    def normalize_transfers(data)
      data.map do |item|
        {
          token_id: (item['ethscription_transaction_hash'] || '').downcase,  # The ethscription being transferred
          tx_hash: (item['transaction_hash'] || '').downcase,                # The transfer transaction
          from: (item['from_address'] || '').downcase,
          to: (item['to_address'] || '').downcase,
          block_number: item['block_number']
        }
      end
    end
  end
end
