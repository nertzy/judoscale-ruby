require 'rails_autoscale_agent/logger'
require 'rails_autoscale_agent/store'
require 'rails_autoscale_agent/reporter'
require 'rails_autoscale_agent/config'
require 'rails_autoscale_agent/request'

module RailsAutoscaleAgent
  class Middleware
    include Logger

    def initialize(app)
      @app = app
    end

    def call(env)
      logger.tagged 'RailsAutoscale' do
        config = Config.instance
        request = Request.new(env, config)

        logger.debug "Middleware entered - request_id=#{request.id} path=#{request.path} method=#{request.method} request_size=#{request.size}"

        store = Store.instance
        Reporter.start(config, store)

        if !request.ignore? && queue_time = request.queue_time
          # NOTE: Expose queue time to the app
          env['queue_time'] = queue_time
          store.push queue_time
        end
      end

      @app.call(env)
    end

  end
end
