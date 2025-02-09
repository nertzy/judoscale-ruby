# frozen_string_literal: true

require "singleton"
require "judoscale/config"
require "judoscale/logger"
require "judoscale/adapter_api"
require "judoscale/job_metrics_collector"
require "judoscale/web_metrics_collector"

module Judoscale
  class Reporter
    include Singleton
    include Logger

    def self.start(config = Config.instance, adapters = Judoscale.adapters)
      instance.start!(config, adapters) unless instance.started?
    end

    def start!(config, adapters)
      @pid = Process.pid

      if !config.api_base_url
        logger.info "Reporter not started: JUDOSCALE_URL is not set"
        return
      end

      enabled_adapters = adapters.select { |adapter|
        adapter.metrics_collector.nil? || adapter.metrics_collector.collect?(config)
      }
      metrics_collectors_classes = enabled_adapters.map(&:metrics_collector)
      metrics_collectors_classes.compact!

      if metrics_collectors_classes.empty?
        logger.info "Reporter not started: no metrics need to be collected on this dyno"
        return
      end

      adapters_msg = enabled_adapters.map(&:identifier).join(", ")
      logger.info "Reporter starting, will report every #{config.report_interval_seconds} seconds or so. Adapters: [#{adapters_msg}]"

      metrics_collectors = metrics_collectors_classes.map(&:new)

      run_loop(config, metrics_collectors)
    end

    def run_loop(config, metrics_collectors)
      @_thread = Thread.new do
        loop do
          run_metrics_collection(config, metrics_collectors)

          # Stagger reporting to spread out reports from many processes
          multiplier = 1 - (rand / 4) # between 0.75 and 1.0
          sleep config.report_interval_seconds * multiplier
        end
      end
    end

    def run_metrics_collection(config, metrics_collectors)
      metrics = metrics_collectors.flat_map do |metric_collector|
        log_exceptions { metric_collector.collect } || []
      end

      log_exceptions { report(config, metrics) }
    end

    def started?
      @pid == Process.pid
    end

    def stop!
      @_thread&.terminate
      @_thread = nil
      @pid = nil
    end

    private

    def report(config, metrics)
      report = Report.new(Judoscale.adapters, config, metrics)
      logger.info "Reporting #{report.metrics.size} metrics"
      result = AdapterApi.new(config).report_metrics(report.as_json)

      case result
      when AdapterApi::SuccessResponse
        logger.debug "Reported successfully"
      when AdapterApi::FailureResponse
        logger.error "Reporter failed: #{result.failure_message}"
      end
    end

    def log_exceptions
      yield
    rescue => ex
      # Log the exception but swallow it to keep the thread running and processing reports.
      # Note: Exceptions in threads other than the main thread will fail silently and terminate it.
      # https://ruby-doc.org/core-3.1.0/Thread.html#class-Thread-label-Exception+handling
      logger.error "Reporter error: #{ex.inspect}", *ex.backtrace
      nil
    end
  end
end
