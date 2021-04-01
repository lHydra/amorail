# Middleware for catch exceptions and try to send request to the mirror host.
module Amorail
  module Middleware
    module Request
      class HostMirror < Faraday::Middleware
        def initialize(app, mirror)
          super(app)
          @mirror = URI(mirror)
          @exceptions = [Faraday::ConnectionFailed, Faraday::TimeoutError]
        end

        def call(env)
          begin
            @app.call(env)
          rescue *@exceptions
            unless env[:url].host == @mirror.host
              env[:url] = @mirror
              retry
            end

            raise
          end
        end

      end
    end
  end
end