# frozen_string_literal: true

module WaterDrop
  # Main WaterDrop messages producer
  class Producer
    extend Forwardable
    include Sync
    include Async
    include Buffer

    # Which of the inline flow errors do we want to intercept and re-bind
    SUPPORTED_FLOW_ERRORS = [
      Rdkafka::RdkafkaError,
      Rdkafka::Producer::DeliveryHandle::WaitTimeoutError
    ].freeze

    private_constant :SUPPORTED_FLOW_ERRORS

    def_delegators :config, :middleware

    # @return [String] uuid of the current producer
    attr_reader :id
    # @return [Status] producer status object
    attr_reader :status
    # @return [Concurrent::Array] internal messages buffer
    attr_reader :messages
    # @return [Object] monitor we want to use
    attr_reader :monitor
    # @return [Object] dry-configurable config object
    attr_reader :config

    # Creates a not-yet-configured instance of the producer
    # @param block [Proc] configuration block
    # @return [Producer] producer instance
    def initialize(&block)
      @buffer_mutex = Mutex.new
      @connecting_mutex = Mutex.new
      @closing_mutex = Mutex.new

      @status = Status.new
      @messages = Concurrent::Array.new

      return unless block

      setup(&block)
    end

    # Sets up the whole configuration and initializes all that is needed
    # @param block [Block] configuration block
    def setup(&block)
      raise Errors::ProducerAlreadyConfiguredError, id unless @status.initial?

      @config = Config
                .new
                .setup(&block)
                .config

      @id = @config.id
      @monitor = @config.monitor
      @contract = Contracts::Message.new(max_payload_size: @config.max_payload_size)
      @status.configured!
    end

    # @return [Rdkafka::Producer] raw rdkafka producer
    # @note Client is lazy initialized, keeping in mind also the fact of a potential fork that
    #   can happen any time.
    # @note It is not recommended to fork a producer that is already in use so in case of
    #   bootstrapping a cluster, it's much better to fork configured but not used producers
    def client
      return @client if @client && @pid == Process.pid

      # Don't allow to obtain a client reference for a producer that was not configured
      raise Errors::ProducerNotConfiguredError, id if @status.initial?

      @connecting_mutex.synchronize do
        return @client if @client && @pid == Process.pid

        # We should raise an error when trying to use a producer from a fork, that is already
        # connected to Kafka. We allow forking producers only before they are used
        raise Errors::ProducerUsedInParentProcess, Process.pid if @status.connected?

        # We undefine all the finalizers, in case it was a fork, so the finalizers from the parent
        # process don't leak
        ObjectSpace.undefine_finalizer(id)
        # Finalizer tracking is needed for handling shutdowns gracefully.
        # I don't expect everyone to remember about closing all the producers all the time, thus
        # this approach is better. Although it is still worth keeping in mind, that this will
        # block GC from removing a no longer used producer unless closed properly but at least
        # won't crash the VM upon closing the process
        ObjectSpace.define_finalizer(id, proc { close })

        @pid = Process.pid
        @client = Builder.new.call(self, @config)

        # Register statistics runner for this particular type of callbacks
        ::Karafka::Core::Instrumentation.statistics_callbacks.add(
          @id,
          Instrumentation::Callbacks::Statistics.new(@id, @client.name, @config.monitor)
        )

        # Register error tracking callback
        ::Karafka::Core::Instrumentation.error_callbacks.add(
          @id,
          Instrumentation::Callbacks::Error.new(@id, @client.name, @config.monitor)
        )

        @status.connected!
      end

      @client
    end

    # Flushes the buffers in a sync way and closes the producer
    def close
      @closing_mutex.synchronize do
        return unless @status.active?

        @monitor.instrument(
          'producer.closed',
          producer_id: id
        ) do
          @status.closing!

          # No need for auto-gc if everything got closed by us
          # This should be used only in case a producer was not closed properly and forgotten
          ObjectSpace.undefine_finalizer(id)

          # We save this thread id because we need to bypass the activity verification on the
          # producer for final flush of buffers.
          @closing_thread_id = Thread.current.object_id

          # Flush has its own buffer mutex but even if it is blocked, flushing can still happen
          # as we close the client after the flushing (even if blocked by the mutex)
          flush(true)

          # We should not close the client in several threads the same time
          # It is safe to run it several times but not exactly the same moment
          # We also mark it as closed only if it was connected, if not, it would trigger a new
          # connection that anyhow would be immediately closed
          client.close(@config.max_wait_timeout) if @client

          # Remove callbacks runners that were registered
          ::Karafka::Core::Instrumentation.statistics_callbacks.delete(@id)
          ::Karafka::Core::Instrumentation.error_callbacks.delete(@id)

          @status.closed!
        end
      end
    end

    # Ensures that we don't run any operations when the producer is not configured or when it
    # was already closed
    def ensure_active!
      return if @status.active?

      raise Errors::ProducerNotConfiguredError, id if @status.initial?
      raise Errors::ProducerClosedError, id if @status.closing? || @status.closed?

      # This should never happen
      raise Errors::StatusInvalidError, [id, @status.to_s]
    end

    # Ensures that the message we want to send out to Kafka is actually valid and that it can be
    # sent there
    # @param message [Hash] message we want to send
    # @raise [Karafka::Errors::MessageInvalidError]
    def validate_message!(message)
      @contract.validate!(message, Errors::MessageInvalidError)
    end

    # Runs the client produce method with a given message
    #
    # @param message [Hash] message we want to send
    def produce(message)
      client.produce(**message)
    rescue SUPPORTED_FLOW_ERRORS.first => e
      # Unless we want to wait and retry and it's a full queue, we raise normally
      raise unless @config.wait_on_queue_full
      raise unless e.code == :queue_full

      # We use this syntax here because we want to preserve the original `#cause` when we
      # instrument the error and there is no way to manually assign `#cause` value. We want to keep
      # the original cause to maintain the same API across all the errors dispatched to the
      # notifications pipeline.
      begin
        raise Errors::ProduceError
      rescue Errors::ProduceError => e
        # We want to instrument on this event even when we restart it.
        # The reason is simple: instrumentation and visibility.
        # We can recover from this, but despite that we should be able to instrument this.
        # If this type of event happens too often, it may indicate that the buffer settings are not
        # well configured.
        @monitor.instrument(
          'error.occurred',
          producer_id: id,
          message: message,
          error: e,
          type: 'message.produce'
        )

        # We do not poll the producer because polling happens in a background thread
        # It also should not be a frequent case (queue full), hence it's ok to just throttle.
        sleep @config.wait_on_queue_full_timeout
      end

      retry
    end

    # Waits on a given handler
    #
    # @param handler [Rdkafka::Producer::DeliveryHandle]
    def wait(handler)
      handler.wait(
        max_wait_timeout: @config.max_wait_timeout,
        wait_timeout: @config.wait_timeout
      )
    end
  end
end
