module ScoutApm
  module LayerConverters
    class SlowRequestConverter < ConverterBase
      def initialize(*)
        super

        # After call to super, so @request is populated
        @points = if request.web?
                    ScoutApm::Agent.instance.slow_request_policy.score(request)
                  else
                    -1
                  end

        setup_subscopable_callbacks
      end

      def name
        request.unique_name
      end

      def score
        @points
      end

      # Unconditionally attempts to convert this into a SlowTransaction object.
      # Can return nil if the request didn't have any scope_layer.
      def call
        return nil unless request.web?
        return nil unless scope_layer

        ScoutApm::Agent.instance.slow_request_policy.stored!(request)

        # record the change in memory usage
        mem_delta = ScoutApm::Instruments::Process::ProcessMemory.rss_to_mb(@request.capture_mem_delta!)

        uri = request.annotations[:uri] || ""

        timing_metrics, allocation_metrics = create_metrics

        unless ScoutApm::Instruments::Allocations::ENABLED
          allocation_metrics = {}
        end

        SlowTransaction.new(uri,
                            scope_layer.legacy_metric_name,
                            root_layer.total_call_time,
                            timing_metrics,
                            allocation_metrics,
                            request.context,
                            root_layer.stop_time,
                            [], # stackprof, now unused.
                            mem_delta,
                            root_layer.total_allocations,
                            @points,
                            limited?)
      end

      # Full metrics from this request. These get stored permanently in a SlowTransaction.
      # Some merging of metrics will happen here, so if a request calls the same
      # ActiveRecord or View repeatedly, it'll get merged.
      #
      # This returns a 2-element of Metric Hashes (the first element is timing metrics, the second element is allocation metrics)
      def create_metrics
        metric_hash = Hash.new
        allocation_metric_hash = Hash.new

        walker.walk do |layer|
          next if skip_layer?(layer)
          store_specific_metric(layer, metric_hash, allocation_metric_hash)
          store_aggregate_metric(layer, metric_hash, allocation_metric_hash)
        end

        metric_hash = attach_backtraces(metric_hash)
        allocation_metric_hash = attach_backtraces(allocation_metric_hash)

        [metric_hash, allocation_metric_hash]
      end
    end
  end
end
