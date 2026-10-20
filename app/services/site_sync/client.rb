# frozen_string_literal: true

require 'net/http'
require 'zlib'

module SiteSync
  # Site -> central HTTP client. Every request is signed with the site's
  # secret (HMAC-SHA256 over method, path and body). In production the link is
  # also mutual TLS through nginx; the signature keeps the prototype honest
  # without certificates.
  class Client
    Response = Struct.new(:status, :body, :bytes_sent, :bytes_received)
    class Unreachable < StandardError; end

    # Central answers a batch only after it has committed, which can take a
    # while for a large catch-up batch on a slow server.
    def initialize(base_url: Config.central_url, site_code: Config.site_code, secret: Config.secret,
                   timeout: Integer(ENV.fetch('SITE_SYNC_HTTP_TIMEOUT', 120)))
      @base = URI(base_url)
      @site_code = site_code
      @secret = secret
      @timeout = timeout
    end

    def post(path, payload, gzip: true)
      body = payload.is_a?(String) ? payload : payload.to_json
      request(Net::HTTP::Post, path, body, gzip:)
    end

    def get(path, params = {})
      query = params.empty? ? '' : "?#{URI.encode_www_form(params)}"
      request(Net::HTTP::Get, "#{path}#{query}", '')
    end

    # Signs the method, the full path including the query string (so cursor,
    # table and id parameters cannot be altered), a timestamp, a one-time
    # nonce (central refuses a nonce it has seen, so a captured request cannot
    # be replayed) and the body.
    def self.signature(secret, method, full_path, timestamp, nonce, body)
      OpenSSL::HMAC.hexdigest('SHA256', secret, "#{method}\n#{full_path}\n#{timestamp}\n#{nonce}\n#{body}")
    end

    private

    def request(klass, path, body, gzip: false)
      full_path = "#{@base.path.chomp('/')}#{path}"
      req = klass.new(full_path)
      req['Content-Type'] = 'application/json'
      req['Accept-Encoding'] = 'gzip'
      timestamp = Hlc.now_us.to_s
      nonce = SecureRandom.hex(16)
      req['X-Site-Code'] = @site_code
      req['X-Site-Timestamp'] = timestamp
      req['X-Site-Nonce'] = nonce
      req['X-Site-Signature'] = self.class.signature(@secret, req.method, full_path, timestamp, nonce, body)
      wire = body
      if gzip && body.present?
        wire = Zlib.gzip(body)
        req['Content-Encoding'] = 'gzip'
      end
      req.body = wire if body.present?

      http = Net::HTTP.new(@base.host, @base.port)
      http.use_ssl = @base.scheme == 'https'
      if http.use_ssl? && Config.mtls_enabled?
        http.cert = OpenSSL::X509::Certificate.new(File.read(Config.tls_cert_path))
        http.key = OpenSSL::PKey::RSA.new(File.read(Config.tls_key_path))
        if Config.tls_ca_path
          http.ca_file = Config.tls_ca_path
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        end
      end
      http.open_timeout = 10
      http.read_timeout = @timeout
      res = http.request(req)
      raw = res.body.to_s
      text = res['Content-Encoding'] == 'gzip' ? Zlib.gunzip(raw) : raw
      parsed = begin
        JSON.parse(text)
      rescue JSON::ParserError
        { 'raw' => text.slice(0, 500) }
      end
      Response.new(res.code.to_i, parsed, wire.to_s.bytesize, raw.bytesize)
    rescue SystemCallError, IOError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout, SocketError, EOFError,
           OpenSSL::SSL::SSLError => e
      raise Unreachable, "#{e.class}: #{e.message}"
    end
  end
end
