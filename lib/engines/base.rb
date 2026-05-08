module Engines
  class Base
    def initialize(timeout_sec:, base_dir:)
      @timeout_sec = timeout_sec
      @base_dir = base_dir
    end

    def name
      raise NotImplementedError
    end

    def supports_warm?
      false
    end

    def boot
    end

    def shutdown
    end

    def render(html_path:, output_path:)
      raise NotImplementedError
    end

    private

    attr_reader :timeout_sec, :base_dir
  end
end
