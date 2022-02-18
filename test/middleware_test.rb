# frozen_string_literal: true

require "test_helper"
require "judoscale/middleware"

module Judoscale
  class MockApp
    attr_reader :env

    def call(env)
      @env = env
      nil
    end
  end

  describe Middleware do
    describe "#call" do
      after {
        Reporter.instance.stop!
        MetricsStore.instance.clear
      }

      let(:app) { MockApp.new }
      let(:env) {
        {
          "PATH_INFO" => "/foo",
          "REQUEST_METHOD" => "POST",
          "rack.input" => StringIO.new("hello")
        }
      }
      let(:middleware) { Middleware.new(app) }

      describe "with the API URL configured" do
        before {
          Judoscale.configure { |config| config.api_base_url = "http://example.com" }
        }

        it "passes the request up the middleware stack" do
          middleware.call(env)
          _(app.env).must_equal(env)
        end

        it "starts the reporter" do
          middleware.call(env)
          _(Reporter.instance).must_be :started?
        end

        describe "when the request includes HTTP_X_REQUEST_START" do
          let(:five_seconds_ago_in_unix_millis) { (Time.now.to_f - 5) * 1000 }

          before { env["HTTP_X_REQUEST_START"] = five_seconds_ago_in_unix_millis.to_i.to_s }
          after { MetricsStore.instance.clear }

          it "collects the request queue time" do
            middleware.call(env)

            report = MetricsStore.instance.pop_report
            _(report.measurements.length).must_equal 1
            _(report.measurements.first).must_be_instance_of Measurement
            _(report.measurements.first.value).must_be_within_delta 5000, 1
            _(report.measurements.first.metric).must_equal :qt
          end

          it "records the queue time in the environment passed on" do
            middleware.call(env)

            _(app.env).must_include("judoscale.queue_time")
            _(app.env["judoscale.queue_time"]).must_be_within_delta 5000, 1
          end

          it "logs debug information about the request and queue time" do
            use_config log_level: :debug do
              env["HTTP_X_REQUEST_ID"] = "req-abc-123"

              middleware.call(env)

              _(log_string).must_match %r{Request queue_time=500\dms network_time=0ms request_id=req-abc-123 size=5}
            end
          end

          describe "when the request body is large enough to skew the queue time" do
            before { env["rack.input"] = StringIO.new("." * 110_000) }

            it "does not collect the request queue time" do
              middleware.call(env)

              report = MetricsStore.instance.pop_report
              _(report.measurements.length).must_equal 0
            end
          end

          describe "when Puma request body wait / network time is available" do
            before { env["puma.request_body_wait"] = 50 }

            it "collects the request network time as a separate measurement" do
              middleware.call(env)

              report = MetricsStore.instance.pop_report
              _(report.measurements.length).must_equal 2
              _(report.measurements.last).must_be_instance_of Measurement
              _(report.measurements.last.value).must_be_within_delta 50, 1
              _(report.measurements.last.metric).must_equal :nt
            end

            it "records the network time in the environment passed on" do
              middleware.call(env)

              _(app.env).must_include("judoscale.network_time")
              _(app.env["judoscale.network_time"]).must_be_within_delta 50, 1
            end
          end
        end
      end

      describe "without the API URL configured" do
        before {
          Judoscale.configure { |config| config.api_base_url = nil }
        }

        it "passes the request up the middleware stack" do
          middleware.call(env)
          _(app.env).must_equal env
        end

        it "does not start the reporter" do
          Reporter.instance.stub(:register!, -> { raise "SHOULD NOT BE CALLED" }) do
            middleware.call(env)
          end
        end
      end
    end
  end
end
