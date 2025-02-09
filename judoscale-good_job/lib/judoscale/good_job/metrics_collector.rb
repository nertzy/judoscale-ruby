# frozen_string_literal: true

require "judoscale/job_metrics_collector"
require "judoscale/job_metrics_collector/active_record_helper"
require "judoscale/metric"

module Judoscale
  module GoodJob
    class MetricsCollector < Judoscale::JobMetricsCollector
      include ActiveRecordHelper

      def self.adapter_config
        Judoscale::Config.instance.good_job
      end

      def initialize
        super

        queue_names = run_silently do
          ::GoodJob::Execution.select("distinct queue_name").map(&:queue_name)
        end
        self.queues |= queue_names
      end

      def collect
        metrics = []
        time = Time.now.utc

        # logically we don't need the finished_at condition, but it lets postgres use the indexes
        oldest_execution_time_by_queue = run_silently do
          ::GoodJob::Execution
            .where(performed_at: nil, finished_at: nil)
            .group(:queue_name)
            .pluck(:queue_name, Arel.sql("min(coalesce(scheduled_at, created_at))"))
            .to_h
        end
        self.queues |= oldest_execution_time_by_queue.keys

        if track_busy_jobs?
          busy_count_by_queue = run_silently do
            ::GoodJob::Execution.running.group(:queue_name).count
          end
          self.queues |= busy_count_by_queue.keys
        end

        queues.each do |queue|
          run_at = oldest_execution_time_by_queue[queue]
          # DateTime.parse assumes a UTC string
          run_at = DateTime.parse(run_at) if run_at.is_a?(String)
          latency_ms = run_at ? ((time - run_at) * 1000).ceil : 0
          latency_ms = 0 if latency_ms < 0

          metrics.push Metric.new(:qt, latency_ms, time, queue)

          if track_busy_jobs?
            busy_count = busy_count_by_queue[queue] || 0
            metrics.push Metric.new(:busy, busy_count, Time.now, queue)
          end
        end

        log_collection(metrics)
        metrics
      end
    end
  end
end
