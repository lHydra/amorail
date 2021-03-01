# frozen_string_literal: true

require 'faraday'
require 'faraday_middleware'
require 'json'
require 'active_support'

module Amorail
  # Amorail http client
  class Client
    SUCCESS_STATUS_CODES = [200, 204].freeze

    attr_reader :api_endpoint

    def initialize(api_endpoint: Amorail.config.api_endpoint,
                   client_id: Amorail.config.client_id,
                   client_secret: Amorail.config.client_secret,
                   code: Amorail.config.code,
                   redirect_uri: Amorail.config.redirect_uri)
      @api_endpoint = api_endpoint
      @client_id = client_id
      @client_secret = client_secret
      @code = code
      @redirect_uri = redirect_uri

      @connect = Faraday.new(url: api_endpoint) do |faraday|
        faraday.response :json, content_type: /\bjson$/
        faraday.use :instrumentation
        faraday.adapter Faraday.default_adapter
      end
    end

    def properties
      @properties ||= Property.new(self)
    end

    def connect
      @connect || self.class.new
    end

    def authorize
      response = post(Amorail.config.auth_url, auth_params)
      access_token_handler(response)
      response
    end

    def auth_params
      if token_expired?
        {
            client_id: @client_id,
            client_secret: @client_secret,
            grant_type: 'refresh_token',
            refresh_token: refresh_token,
            redirect_uri: @redirect_uri
        }
      else
        {
            client_id: @client_id,
            client_secret: @client_secret,
            grant_type: 'authorization_code',
            code: @code,
            redirect_uri: @redirect_uri
        }
      end
    end

    def safe_request(method, url, params = {})
      authorize if access_token.blank? || token_expired?
      public_send(method, url, params)
    end

    def get(url, params = {})
      response = connect.get(url, params) do |request|
        request.headers['Authorization'] = "Bearer #{access_token}" if access_token.present?
      end
      handle_response(response)
    end

    def post(url, params = {})
      response = connect.post(url) do |request|
        request.headers['Authorization'] = "Bearer #{access_token}" if access_token.present?
        request.headers['Content-Type'] = 'application/json'
        request.body = params.to_json
      end
      handle_response(response)
    end

    private

    attr_reader :access_token, :refresh_token

    def access_token_handler(response)
      credentials = {
          @client_secret => {
              access_token: response.body['access_token'],
              refresh_token: response.body['refresh_token'],
              created_at: Time.now,
              expires_in: response.body['expires_in']
          }
      }

      if response.body['access_token'].present? && response.body['refresh_token'].present?
        Dir.mkdir('tmp') unless Dir.exist?('tmp') unless defined?(Rails)
        data = credentials_file.merge(credentials)
        File.open(file_path, 'w') { |file| file.write(data.to_yaml) }
      end
    end

    def access_token
      access_credentials.try(:[], :access_token)
    end

    def refresh_token
      access_credentials.try(:[], :refresh_token)
    end

    def token_expired?
      return if access_credentials.blank?

      created_at = access_credentials[:created_at]
      expires_in = access_credentials[:expires_in].to_i

      created_at + expires_in - Time.now < 3600
    end

    def access_credentials
      if File.exist?(file_path) && credentials_file[@client_secret]
        credentials_file[@client_secret]
      else
        {}
      end
    end

    def credentials_file
      YAML.load(File.read(file_path))
    end

    def handle_response(response) # rubocop:disable all
      return response if SUCCESS_STATUS_CODES.include?(response.status)

      case response.status
      when 301
        fail ::Amorail::AmoMovedPermanentlyError
      when 400
        fail ::Amorail::AmoBadRequestError
      when 401
        fail ::Amorail::AmoUnauthorizedError
      when 403
        fail ::Amorail::AmoForbiddenError
      when 404
        fail ::Amorail::AmoNotFoundError
      when 500
        fail ::Amorail::AmoInternalError
      when 502
        fail ::Amorail::AmoBadGatewayError
      when 503
        fail ::Amorail::AmoServiceUnaviableError
      else
        fail ::Amorail::AmoUnknownError, response.body
      end
    end

    def file_path
      if defined?(Rails)
        Rails.root.join('config', Amorail.config.config_filename)
      else
        'tmp/' + Amorail.config.config_filename
      end
    end
  end
end
