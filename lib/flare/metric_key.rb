# frozen_string_literal: true

module Flare
  # Identifies a unique metric for aggregation.
  # Immutable and hashable for use as Concurrent::Map keys.
  class MetricKey
    attr_reader :bucket, :namespace, :service, :target, :operation

    def initialize(bucket:, namespace:, service:, target:, operation:)
      @bucket = bucket
      @namespace = namespace.to_s.freeze
      @service = service.to_s.freeze
      @target = target&.to_s&.freeze
      @operation = operation.to_s.freeze
      freeze
    end

    def eql?(other)
      self.class.eql?(other.class) &&
        bucket == other.bucket &&
        namespace == other.namespace &&
        service == other.service &&
        target == other.target &&
        operation == other.operation
    end
    alias == eql?

    def hash
      [self.class, bucket, namespace, service, target, operation].hash
    end

    def to_h
      {
        bucket: bucket,
        namespace: namespace,
        service: service,
        target: target,
        operation: operation
      }
    end
  end
end
