# frozen_string_literal: true

module Datadog
  module AppSec
    module Contrib
      module Rack
        module Reactive
          # Dispatch data from a Rack request to the WAF context
          module Request
            ADDRESSES = [
              'request.headers',
              'request.uri.raw',
              'request.query',
              'request.cookies',
              'request.client_ip',
              'server.request.method'
            ].freeze
            private_constant :ADDRESSES

            def self.publish(op, gateway_request)
              catch(:block) do
                op.publish('request.query', gateway_request.query)
                op.publish('request.headers', gateway_request.headers)
                op.publish('request.uri.raw', gateway_request.fullpath)
                op.publish('request.cookies', gateway_request.cookies)
                op.publish('request.client_ip', gateway_request.client_ip)
                op.publish('server.request.method', gateway_request.method)

                nil
              end
            end

            def self.subscribe(op, waf_context)
              op.subscribe(*ADDRESSES) do |*values|
                Datadog.logger.debug { "reacted to #{ADDRESSES.inspect}: #{values.inspect}" }

                headers = values[0]
                headers_no_cookies = headers.dup.tap { |h| h.delete('cookie') }
                uri_raw = values[1]
                query = values[2]
                cookies = values[3]
                client_ip = values[4]
                request_method = values[5]

                persistent_data = {
                  'server.request.cookies' => cookies,
                  'server.request.query' => query,
                  'server.request.uri.raw' => uri_raw,
                  'server.request.headers' => headers,
                  'server.request.headers.no_cookies' => headers_no_cookies,
                  'http.client_ip' => client_ip,
                  'server.request.method' => request_method,
                }

                waf_timeout = Datadog.configuration.appsec.waf_timeout
                result = waf_context.run(persistent_data, {}, waf_timeout)

                next if result.status != :match

                yield result
                throw(:block, true) unless result.actions.empty?
              end
            end
          end
        end
      end
    end
  end
end
