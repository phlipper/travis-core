module Travis
  class Task

    # Sends build notifications to webhooks as defined in the configuration
    # (`.travis.yml`).
    class Webhook < Task
      include do
        attr_reader :targets, :data, :token

        def initialize(targets, data, token)
          @targets = targets
          @data = data
          @token = token
        end

        def run
          targets.each { |target| send_webhook(target) }
        end

        protected

          def send_webhook(target)
            response = http.post(target) do |req|
              req.body = { :payload => data.to_json }
              req.headers['Authorization'] = authorization
            end
            log_request(response)
          end

          def authorization
            Digest::SHA2.hexdigest(data['repository'].values_at('owner_name', 'name').join('/') + token)
          end

          def log_request(response)
            severity, message = if response.success?
              [:info, "Successfully notified #{response.env[:url].to_s}."]
            else
              [:error, "Could not notify #{response.env[:url].to_s}. Status: #{response.status} (#{response.body.inspect})"]
            end
            send(severity, message)
          end
      end
    end
  end
end